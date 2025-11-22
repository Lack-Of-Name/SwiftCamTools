#if canImport(AVFoundation) && canImport(Combine)
import Foundation
import AVFoundation
import CoreMedia
import Combine
import OSLog
import SwiftCamCore
import SwiftCamImaging

public final class CameraController: NSObject, ObservableObject {
    public enum PreviewQuality {
        case fullResolution
        case responsive
    }
    public enum PipelineState {
        case idle
        case running
        case capturing
        case error(CameraError)
    }

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "SwiftCamTools.CameraController")
    private var photoOutput = AVCapturePhotoOutput()
    private var videoOutput = AVCaptureVideoDataOutput()
    private var captureDevice: AVCaptureDevice?
    private let fusionEngine: ImageFusionEngine
    private let configuration: AppConfiguration
    private let logger = Logger(subsystem: "SwiftCamTools", category: "CameraController")
    private var currentPreviewQuality: PreviewQuality = .fullResolution
    private var currentOrientation: CameraOrientation = .portrait
    private var pendingLowPowerPreviewConfiguration = false
    private var cachedMaxExposureDuration: Double = 0
    private var longExposureSession: LongExposureCaptureSession?
    private var longExposureCompletion: ((Result<Data, CameraError>) -> Void)?
    private let referenceAperture: Double = 1.8
    private let focusLockLensPosition: Float = 1.0

    @Published public private(set) var state: PipelineState = .idle
    @Published public private(set) var lastExposure: ExposureSettings = ExposureSettings()

    public init(configuration: AppConfiguration = AppConfiguration(), fusionEngine: ImageFusionEngine? = nil) {
        if let fusionEngine {
            self.fusionEngine = fusionEngine
        } else if let adaptiveReducer = AdaptiveNoiseReducer() {
            self.fusionEngine = ImageFusionEngine(reducer: adaptiveReducer)
        } else {
            // Passthrough fallback keeps the controller usable even when Metal is unavailable (e.g. simulator on older Macs).
            self.fusionEngine = ImageFusionEngine(reducer: PassthroughNoiseReducer())
        }
        self.configuration = configuration
        super.init()
        session.sessionPreset = .photo
    }

    public var sampleBufferHandler: ((CMSampleBuffer) -> Void)?

    public var captureSession: AVCaptureSession {
        session
    }

    public var maxSupportedExposureSeconds: Double {
        cachedMaxExposureDuration
    }

    public var minISO: Float {
        captureDevice?.activeFormat.minISO ?? 50
    }

    public var maxISO: Float {
        captureDevice?.activeFormat.maxISO ?? 1600
    }

    public var minExposureDuration: Double {
        guard let device = captureDevice else { return 1.0/10000.0 }
        return CMTimeGetSeconds(device.activeFormat.minExposureDuration)
    }

    public func configure() {
        sessionQueue.async {
            self.session.beginConfiguration()
            var configurationDidSucceed = false
            do {
                self.session.inputs.forEach { self.session.removeInput($0) }
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                    self.state = .error(.configurationFailed("No back camera"))
                    return
                }
                self.captureDevice = device
                self.cachedMaxExposureDuration = CMTimeGetSeconds(device.activeFormat.maxExposureDuration)
                let input = try AVCaptureDeviceInput(device: device)
                if self.session.canAddInput(input) {
                    self.session.addInput(input)
                }
                if self.session.canAddOutput(self.photoOutput) {
                    self.session.addOutput(self.photoOutput)
                    if let connection = self.photoOutput.connection(with: .video) {
                        self.apply(self.currentOrientation, to: connection)
                    }
                }
                if self.session.canAddOutput(self.videoOutput) {
                    self.videoOutput.alwaysDiscardsLateVideoFrames = true
                    self.videoOutput.setSampleBufferDelegate(self, queue: self.sessionQueue)
                    self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
                    self.session.addOutput(self.videoOutput)
                    if let connection = self.videoOutput.connection(with: .video) {
                        self.apply(self.currentOrientation, to: connection)
                    }
                }
                if #available(iOS 16.0, *) {
                    // Default configuration already prefers the largest supported photo dimensions on iOS 16+.
                } else {
                    self.photoOutput.isHighResolutionCaptureEnabled = true
                }
                self.applyLowPowerPreviewConfigurationIfNeeded()
                configurationDidSucceed = true
            } catch {
                self.state = .error(.configurationFailed(error.localizedDescription))
            }
            self.session.commitConfiguration()

            guard configurationDidSucceed else { return }

            if !self.session.isRunning {
                self.session.startRunning()
            }
            self.state = .running
        }
    }

    private var captureCompletion: ((Result<AVCapturePhoto, CameraError>) -> Void)?

    public func capture(settings: ExposureSettings, completion: @escaping (Result<AVCapturePhoto, CameraError>) -> Void) {
        captureCompletion = completion
        sessionQueue.async {
            guard let device = self.captureDevice else {
                DispatchQueue.main.async { completion(.failure(.configurationFailed("Camera unavailable"))) }
                return
            }
            let resolvedSettings = self.resolvedSettingsForCapture(settings, device: device)
            if let error = self.applyExposureSettings(resolvedSettings) {
                DispatchQueue.main.async { self.state = .error(error) }
                self.captureCompletion?(.failure(error))
                return
            }
            self.lastExposure = resolvedSettings

            let photoSettings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            if let connection = self.photoOutput.connection(with: .video) {
                self.apply(self.currentOrientation, to: connection)
            }
            self.photoOutput.capturePhoto(with: photoSettings, delegate: self)
            self.state = .capturing
        }
    }

    public func captureLongExposure(durationSeconds: Double, settings: ExposureSettings, completion: @escaping (Result<Data, CameraError>) -> Void) {
        sessionQueue.async {
            guard self.longExposureCompletion == nil else {
                DispatchQueue.main.async { completion(.failure(.captureFailed("Long exposure already in progress."))) }
                return
            }

            guard let device = self.captureDevice else {
                DispatchQueue.main.async { completion(.failure(.configurationFailed("Camera unavailable"))) }
                return
            }

            // Capture current state for restoration
            let previousExposureMode = device.exposureMode
            let previousDuration = device.exposureDuration
            let previousISO = device.iso
            
            // Night Mode / Long Exposure Strategy:
            // 1. Analyze current scene brightness (using current AE values).
            // 2. If Bright: Use current AE settings to prevent overexposure. Stack frames for motion blur.
            // 3. If Dark: Extend shutter to handheld limit (1/12s), then boost ISO. Stack frames for noise reduction.
            
            let currentISO = device.iso
            let currentDuration = CMTimeGetSeconds(device.exposureDuration)
            // "Smart" Handheld Limit: 1/3s allows significantly more light than 1/12s.
            // We rely on the stacking algorithm's sharpness weighting to reject motion blur.
            let safeShutterSpeed = 1.0 / 3.0
            let maxISO = device.activeFormat.maxISO
            
            var targetISO: Float
            var targetDuration: Double
            
            // Check if the user manually requested a specific exposure that is NOT a long exposure
            // (e.g. they set 1/8000s but the pipeline routed here for some reason, or they set 1s and want exactly 1s).
            // However, this method is specifically for "Long Exposure" (simulated or real).
            // If the user requested 2s, they want the effect of 2s.
            
            // If the scene is bright (current shutter is fast), we MUST use the fast shutter to avoid overexposure.
            // We can't force 1/12s if the correct exposure is 1/1000s.
            if currentDuration < safeShutterSpeed {
                // Bright Scene:
                // Use the camera's auto-exposure values (or current manual values) to ensure correct exposure.
                targetISO = currentISO
                targetDuration = currentDuration
            } else {
                // Dark Scene:
                // We need more light.
                // 1. Extend shutter to the safe handheld limit.
                targetDuration = safeShutterSpeed
                
                // 2. Calculate required ISO to match preview brightness
                // TargetISO = CurrentISO * (CurrentDuration / TargetDuration)
                // Note: If CurrentDuration > SafeShutter (e.g. 1/3s), we are shortening the shutter to 1/12s to reduce blur.
                // So we must INCREASE ISO.
                // If CurrentDuration < SafeShutter (e.g. 1/30s), we are lengthening shutter to 1/12s.
                // So we can DECREASE ISO (for less noise).
                
                let requiredISO = currentISO * Float(currentDuration / targetDuration)
                targetISO = max(device.activeFormat.minISO, min(requiredISO, maxISO))
            }
            
            // Safety Check: If the calculated target results in massive overexposure compared to what the user might expect?
            // No, we are matching the preview brightness (CurrentISO * CurrentDuration).
            // So the result should match the preview.
            
            // Apply Settings
            do {
                try device.lockForConfiguration()
                let durationTime = CMTimeMakeWithSeconds(targetDuration, preferredTimescale: 1_000_000_000)
                device.setExposureModeCustom(duration: durationTime, iso: targetISO, completionHandler: nil)
                self.configureFocus(for: device, autoFocusEnabled: settings.autoFocus)
                device.unlockForConfiguration()
            } catch {
                DispatchQueue.main.async { completion(.failure(.configurationFailed(error.localizedDescription))) }
                return
            }

            self.longExposureCompletion = completion
            
            // Frame budget: We capture for 'durationSeconds'.
            // Expected frames = durationSeconds / targetDuration
            let expectedFrames = Int(durationSeconds / targetDuration) + 2
            
            self.longExposureSession = LongExposureCaptureSession(duration: durationSeconds, maxFrameCount: expectedFrames, settings: settings) { [weak self] result in
                guard let self else { return }
                self.sessionQueue.async {
                    self.longExposureSession = nil
                    let handler = self.longExposureCompletion
                    self.longExposureCompletion = nil
                    
                    // Restore preview settings
                    if let device = self.captureDevice {
                        try? device.lockForConfiguration()
                        if previousExposureMode == .custom {
                            device.setExposureModeCustom(duration: previousDuration, iso: previousISO, completionHandler: nil)
                        } else if device.isExposureModeSupported(previousExposureMode) {
                            device.exposureMode = previousExposureMode
                        } else if device.isExposureModeSupported(.continuousAutoExposure) {
                            device.exposureMode = .continuousAutoExposure
                        }
                        device.unlockForConfiguration()
                    }
                    
                    DispatchQueue.main.async {
                        self.state = .running
                        handler?(result)
                    }
                }
            }

            self.scheduleLongExposureTimeout(after: durationSeconds + 0.5) // Little extra buffer
            DispatchQueue.main.async { self.state = .capturing }
        }
    }

    public func applyPreviewExposure(settings: ExposureSettings) {
        sessionQueue.async { _ = self.applyExposureSettings(settings, enableSubjectMonitoring: false) }
    }

    public func setPreviewQuality(_ quality: PreviewQuality) {
        guard quality != currentPreviewQuality else { return }
        currentPreviewQuality = quality
        sessionQueue.async {
            self.session.beginConfiguration()
            switch quality {
            case .fullResolution:
                if self.session.canSetSessionPreset(.photo) {
                    self.session.sessionPreset = .photo
                }
            case .responsive:
                if self.session.canSetSessionPreset(.high) {
                    self.session.sessionPreset = .high
                }
            }
            self.session.commitConfiguration()
        }
    }

    public func configureLowPowerPreview() {
        pendingLowPowerPreviewConfiguration = true
        currentPreviewQuality = .responsive
        sessionQueue.async {
            self.applyLowPowerPreviewConfigurationIfNeeded()
        }
    }

    public func updateVideoOrientation(_ orientation: CameraOrientation) {
        currentOrientation = orientation
        sessionQueue.async {
            if let connection = self.videoOutput.connection(with: .video) {
                self.apply(orientation, to: connection)
            }
            if let connection = self.photoOutput.connection(with: .video) {
                self.apply(orientation, to: connection)
            }
        }
    }

    public func applyNightPresets(style: NightCaptureStyle) {
        sessionQueue.async {
            guard let device = self.captureDevice else { return }
            do {
                try device.applyNightPresets(style: style)
            } catch {
                self.logger.error("Failed to apply night presets: \(error.localizedDescription)")
            }
        }
    }

    public func performWhiteoutRecovery(reason: String, revertToAutoExposure: Bool) {
        sessionQueue.async {
            guard let device = self.captureDevice else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }

                if revertToAutoExposure, device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                } else {
                    let safeISO = max(device.activeFormat.minISO, min(400, device.activeFormat.maxISO))
                    let minExposureSeconds = CMTimeGetSeconds(device.activeFormat.minExposureDuration)
                    let safeDurationSeconds = max(minExposureSeconds * 2.0, 1.0 / 120.0)
                    let duration = CMTimeMakeWithSeconds(safeDurationSeconds, preferredTimescale: 1_000_000_000)
                    device.setExposureModeCustom(duration: duration, iso: safeISO, completionHandler: nil)
                }

                self.logger.error("Whiteout recovery invoked (\(reason, privacy: .public)); revertToAuto=\(revertToAutoExposure, privacy: .public)")
            } catch {
                self.logger.error("Whiteout recovery failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            DispatchQueue.main.async { self.state = .error(.captureFailed(error.localizedDescription)) }
            captureCompletion?(.failure(.captureFailed(error.localizedDescription)))
            return
        }
        DispatchQueue.main.async { self.state = .running }
        captureCompletion?(.success(photo))
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        longExposureSession?.ingest(sampleBuffer)
        sampleBufferHandler?(sampleBuffer)
    }
}

extension CameraController {
    private func applyExposureSettings(_ settings: ExposureSettings, enableSubjectMonitoring: Bool = true) -> CameraError? {
        guard let device = captureDevice else { return nil }
        guard device.isExposureModeSupported(.custom) else { return .configurationFailed("Custom exposure not supported on this device.") }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            let minDurationSeconds = CMTimeGetSeconds(device.activeFormat.minExposureDuration)
            let maxDurationSeconds = CMTimeGetSeconds(device.activeFormat.maxExposureDuration)
            let requestedSeconds = Double(settings.duration) / 1_000_000_000.0
            let clampedSeconds = max(minDurationSeconds, min(maxDurationSeconds, requestedSeconds))
            let resolvedAperture = resolveApertureValue(for: device, settings: settings)
            let compensationScale = exposureCompensationScale(aperture: resolvedAperture, bias: Double(settings.exposureBias))
            let distributed = distributeExposure(compensationScale: compensationScale, durationSeconds: clampedSeconds, device: device)
            let duration = CMTimeMakeWithSeconds(distributed.duration, preferredTimescale: 1_000_000_000)

            let baseISO: Float
            if settings.autoISO {
                baseISO = resolveAutoISO(for: device, targetDuration: distributed.duration)
            } else {
                baseISO = clampISO(Float(settings.iso), for: device)
            }
            let adjustedISO = clampISO(baseISO * Float(distributed.isoScale), for: device)

            device.setExposureModeCustom(duration: duration, iso: adjustedISO, completionHandler: nil)
            configureFocus(for: device, autoFocusEnabled: settings.autoFocus)
            // applyOverexposureFallbackIfNeeded(device: device, iso: adjustedISO, durationSeconds: distributed.duration)
            device.isSubjectAreaChangeMonitoringEnabled = enableSubjectMonitoring
            return nil
        } catch {
            return .configurationFailed(error.localizedDescription)
        }
    }

    private func clampISO(_ value: Float, for device: AVCaptureDevice) -> Float {
        let minISO = device.activeFormat.minISO
        let maxISO = device.activeFormat.maxISO
        return max(minISO, min(value, maxISO))
    }

    private func resolveAutoISO(for device: AVCaptureDevice, targetDuration: Double) -> Float {
        let minISO = device.activeFormat.minISO
        let maxISO = device.activeFormat.maxISO
        let currentISO = device.iso
        let currentDuration = max(0.0001, CMTimeGetSeconds(device.exposureDuration))
        let durationRatio = currentDuration / max(0.0001, targetDuration)
        let exposureTargetOffset = device.exposureTargetOffset
        let exposureCompensation = pow(2.0, -Double(exposureTargetOffset))
        let computedISO = Float(Double(currentISO) * Double(durationRatio) * exposureCompensation)
        return max(minISO, min(computedISO, maxISO))
    }

    private func applyOverexposureFallbackIfNeeded(device: AVCaptureDevice, iso: Float, durationSeconds: Double) {
        let offset = device.exposureTargetOffset
        guard offset > 1.2 else { return }
        let reductionStops = min(3.0, Double(offset))
        let isoScale = pow(2.0, -reductionStops / 2.0)
        let durationScale = pow(2.0, -reductionStops / 2.0)
        let adjustedISO = clampISO(iso * Float(isoScale), for: device)
        let minDurationSeconds = CMTimeGetSeconds(device.activeFormat.minExposureDuration)
        let maxDurationSeconds = CMTimeGetSeconds(device.activeFormat.maxExposureDuration)
        let adjustedDurationSeconds = max(minDurationSeconds, min(maxDurationSeconds, durationSeconds * durationScale))
        let duration = CMTimeMakeWithSeconds(adjustedDurationSeconds, preferredTimescale: 1_000_000_000)
        device.setExposureModeCustom(duration: duration, iso: adjustedISO, completionHandler: nil)
        logger.warning("Overexposure detected (offset: \(offset, privacy: .public)). Applying fallback ISO \(adjustedISO, privacy: .public) and duration \(adjustedDurationSeconds, privacy: .public)s")
    }

    private func apply(_ orientation: CameraOrientation, to connection: AVCaptureConnection) {
        if #available(iOS 17.0, *) {
            let angle = orientation.rotationAngle
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        } else if connection.isVideoOrientationSupported {
            connection.videoOrientation = orientation.legacyAVOrientation
        }
    }

    private func scheduleLongExposureTimeout(after delay: Double) {
        guard delay > 0 else { return }
        sessionQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.longExposureSession?.forceFinish()
        }
    }

    private func applyLowPowerPreviewConfigurationIfNeeded() {
        guard pendingLowPowerPreviewConfiguration else { return }
        guard self.session.outputs.contains(where: { $0 === self.videoOutput }) else { return }
        pendingLowPowerPreviewConfiguration = false
        if self.session.canSetSessionPreset(.high) {
            self.session.sessionPreset = .high
        }
        self.videoOutput.alwaysDiscardsLateVideoFrames = true
        self.videoOutput.videoSettings = makeLowPowerVideoSettings()
        if let connection = self.videoOutput.connection(with: .video) {
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .off
            }
        }
        self.applyLowPowerFrameRateCap()
    }

    private func applyLowPowerFrameRateCap() {
        guard let device = captureDevice else { return }
        let targetFPS: Double = 24.0
        let supportsTargetFPS = device.activeFormat.videoSupportedFrameRateRanges.contains { range in
            let minFPS = Double(range.minFrameRate)
            let maxFPS = Double(range.maxFrameRate)
            return targetFPS >= minFPS && targetFPS <= maxFPS
        }
        guard supportsTargetFPS else { return }
        let duration = CMTimeMake(value: 1, timescale: Int32(targetFPS))
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        } catch {
            logger.error("Unable to cap preview FPS: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func makeLowPowerVideoSettings() -> [String: Any] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
    }
}

private extension CameraController {
    struct ExposureDistribution {
        let duration: Double
        let isoScale: Double
    }

    func exposureCompensationScale(aperture: Double, bias: Double) -> Double {
        let safeAperture = max(1.0, aperture)
        let apertureScale = pow(referenceAperture / safeAperture, 2.0)
        let biasScale = pow(2.0, bias)
        let combined = apertureScale * biasScale
        return max(0.0625, min(combined, 8.0))
    }

    func distributeExposure(compensationScale: Double, durationSeconds: Double, device: AVCaptureDevice) -> ExposureDistribution {
        let minDurationSeconds = CMTimeGetSeconds(device.activeFormat.minExposureDuration)
        let maxDurationSeconds = CMTimeGetSeconds(device.activeFormat.maxExposureDuration)
        var remainingScale = compensationScale
        var adjustedDuration = durationSeconds

        if remainingScale >= 1.0 {
            let maxDurationScale = max(1.0, maxDurationSeconds / max(durationSeconds, 0.0001))
            let appliedScale = min(remainingScale, maxDurationScale)
            adjustedDuration = min(maxDurationSeconds, adjustedDuration * appliedScale)
            remainingScale = max(1.0, remainingScale / max(appliedScale, 0.0001))
        } else {
            let minDurationScale = min(1.0, minDurationSeconds / max(durationSeconds, 0.0001))
            let appliedScale = max(remainingScale, minDurationScale)
            adjustedDuration = max(minDurationSeconds, adjustedDuration * appliedScale)
            remainingScale = max(0.25, remainingScale / max(appliedScale, 0.0001))
        }

        let isoScale = max(0.25, min(4.0, remainingScale))
        return ExposureDistribution(duration: adjustedDuration, isoScale: isoScale)
    }

    func resolvedSettingsForCapture(_ settings: ExposureSettings, device: AVCaptureDevice) -> ExposureSettings {
        var copy = settings
        if settings.autoAperture {
            let resolved = resolveApertureValue(for: device, settings: settings)
            copy.aperture = Float(resolved)
            copy.autoAperture = false
        }
        return copy
    }

    func resolveApertureValue(for device: AVCaptureDevice, settings: ExposureSettings) -> Double {
        guard settings.autoAperture else { return clampAperture(Double(settings.aperture)) }
        let offset = Double(device.exposureTargetOffset)
        guard offset.isFinite else { return referenceAperture }
        let stops = max(-1.5, min(1.5, -offset * 0.45))
        let computed = referenceAperture * pow(2.0, stops)
        return clampAperture(computed)
    }

    func clampAperture(_ value: Double) -> Double {
        max(1.2, min(8.0, value))
    }

    func configureFocus(for device: AVCaptureDevice, autoFocusEnabled: Bool) {
        if autoFocusEnabled {
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            } else if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            }
            return
        }

        guard device.isFocusModeSupported(.locked) else { return }
        device.setFocusModeLocked(lensPosition: focusLockLensPosition, completionHandler: nil)
    }
}
#endif

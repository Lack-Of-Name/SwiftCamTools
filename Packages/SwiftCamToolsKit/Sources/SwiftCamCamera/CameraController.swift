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

            // Night Mode / Long Exposure Strategy:
            // 1. Analyze current scene brightness (using current AE values).
            // 2. If Bright: Use current AE settings to prevent overexposure. Stack frames for motion blur.
            // 3. If Dark: Extend shutter to handheld limit (1/12s), then boost ISO. Stack frames for noise reduction.
            
            let currentISO = device.iso
            let currentDuration = CMTimeGetSeconds(device.exposureDuration)
            let safeShutterSpeed = 1.0 / 12.0
            let maxISO = device.activeFormat.maxISO
            
            var targetISO: Float
            var targetDuration: Double
            
            if currentDuration < safeShutterSpeed {
                // Bright Scene:
                // Use the camera's auto-exposure values to ensure correct exposure.
                // We will capture multiple frames to simulate the long exposure duration.
                targetISO = currentISO
                targetDuration = currentDuration
            } else {
                // Dark Scene:
                // We need more light.
                // 1. Extend shutter to the safe handheld limit.
                targetDuration = safeShutterSpeed
                
                // 2. Calculate how much we boosted exposure by extending time
                // Ratio = NewDuration / OldDuration
                // But wait, if we extend time, we gather MORE light.
                // If the scene was properly exposed at (currentISO, currentDuration),
                // changing to (currentISO, safeShutterSpeed) would OVEREXPOSE by (safe/current).
                // So we should LOWER ISO? No, usually in dark scenes, currentISO is already high.
                
                // Actually, if we are in a dark scene, the camera is likely already at Max ISO or close to it,
                // and using a slow shutter (e.g. 1/30s).
                // We want to go even slower (1/12s) to gather more light and reduce noise (by lowering ISO if possible).
                
                // Let's aim for the same EV (Exposure Value) as the camera thinks is right, 
                // but shifted towards longer shutter and lower ISO for better quality?
                // OR, does the user want to see *more* than the preview shows (Night Sight)?
                // Usually Night Sight means "Brighter than reality".
                
                // Let's stick to the "Capture Light" philosophy:
                // We want to capture as much light as possible without blur.
                targetDuration = safeShutterSpeed
                
                // We want to match the brightness of the preview, or slightly brighter.
                // EV = ISO * Duration
                // TargetEV = CurrentEV
                // TargetISO * TargetDuration = CurrentISO * CurrentDuration
                // TargetISO = (CurrentISO * CurrentDuration) / TargetDuration
                
                let requiredISO = currentISO * Float(currentDuration / targetDuration)
                
                // However, if the preview was too dark (underexposed), we might want to boost it.
                // But we don't know if it was underexposed.
                // Let's assume the AE is doing its best.
                
                targetISO = requiredISO
                
                // If the calculated ISO is very low, great! Less noise.
                // If it's high, we clamp it.
                
                // But wait, if the scene is PITCH BLACK, currentDuration might be maxed (e.g. 1/3s) and ISO maxed.
                // If currentDuration (1/3s) > safeShutterSpeed (1/12s), we are actually REDUCING light by forcing 1/12s.
                // We should never reduce the shutter speed if the camera thinks it can handle slower (maybe it's on a tripod?).
                // But we assume handheld.
                
                if currentDuration > safeShutterSpeed {
                    // Camera is using a very slow shutter (risky for handheld).
                    // We enforce safe shutter.
                    targetDuration = safeShutterSpeed
                    // And we must boost ISO to compensate for the lost light.
                    // TargetISO = CurrentISO * (CurrentDuration / SafeShutter)
                    targetISO = currentISO * Float(currentDuration / safeShutterSpeed)
                } else {
                    // Current duration is faster than safe limit (e.g. 1/30s).
                    // We extend to 1/12s to gather more light.
                    targetDuration = safeShutterSpeed
                    // And we can LOWER ISO to keep same brightness?
                    // No, for Night Mode we usually want to KEEP the ISO high to get a brighter image, 
                    // OR lower it to get a cleaner image.
                    // Let's prioritize a cleaner image (lower ISO) matching the preview brightness.
                    targetISO = currentISO * Float(currentDuration / safeShutterSpeed)
                }
                
                // Clamp ISO
                targetISO = max(device.activeFormat.minISO, min(targetISO, maxISO))
                
                // If we hit Max ISO and we are still underexposed compared to target,
                // we might want to extend duration further?
                // Let's stick to safe shutter for now to avoid blur.
            }
            
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
                    
                    // Restore preview settings (Auto Exposure)
                    if let device = self.captureDevice {
                        try? device.lockForConfiguration()
                        if device.isExposureModeSupported(.continuousAutoExposure) {
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
            applyOverexposureFallbackIfNeeded(device: device, iso: adjustedISO, durationSeconds: distributed.duration)
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

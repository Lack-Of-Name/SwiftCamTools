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
        lastExposure = settings
        captureCompletion = completion
        sessionQueue.async {
            if let error = self.applyExposureSettings(settings) {
                DispatchQueue.main.async { self.state = .error(error) }
                self.captureCompletion?(.failure(error))
                return
            }

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

            self.lastExposure = settings
            if let error = self.applyExposureSettings(settings, enableSubjectMonitoring: false) {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            self.longExposureCompletion = completion
            let frameBudget = max(12, Int(durationSeconds * 24.0))
            self.longExposureSession = LongExposureCaptureSession(duration: durationSeconds, maxFrameCount: frameBudget, settings: settings) { [weak self] result in
                guard let self else { return }
                self.sessionQueue.async {
                    self.longExposureSession = nil
                    let handler = self.longExposureCompletion
                    self.longExposureCompletion = nil
                    DispatchQueue.main.async {
                        self.state = .running
                        handler?(result)
                    }
                }
            }

            self.scheduleLongExposureTimeout(after: durationSeconds + 0.35)
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
            let duration = CMTimeMakeWithSeconds(clampedSeconds, preferredTimescale: 1_000_000_000)

            let resolvedISO: Float
            if settings.autoISO {
                resolvedISO = resolveAutoISO(for: device, targetDuration: clampedSeconds)
            } else {
                resolvedISO = clampISO(Float(settings.iso), for: device)
            }

            device.setExposureModeCustom(duration: duration, iso: resolvedISO, completionHandler: nil)
            applyOverexposureFallbackIfNeeded(device: device, iso: resolvedISO, durationSeconds: clampedSeconds)
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
#endif

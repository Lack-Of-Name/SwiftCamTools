#if !(canImport(AVFoundation) && canImport(Combine))
import Foundation
import SwiftCamCore
import SwiftCamImaging

public final class CameraController {
    public enum PipelineState {
        case idle
        case running
        case capturing
        case error(CameraError)
    }

    public private(set) var state: PipelineState = .error(.configurationFailed("Camera capture is unavailable on this platform"))
    public private(set) var lastExposure: ExposureSettings = ExposureSettings()
    private let placeholderSession = AVCaptureSession()

    public init(configuration: AppConfiguration = AppConfiguration(), fusionEngine: ImageFusionEngine? = nil) {}

    public var captureSession: AVCaptureSession { placeholderSession }
    public var maxSupportedExposureSeconds: Double { 0 }

    public func configure() {}

    public func configureLowPowerPreview() {}

    public func capture(settings: ExposureSettings, completion: @escaping (Result<AVCapturePhoto, CameraError>) -> Void) {
        completion(.failure(.configurationFailed("Camera capture is unavailable on this platform")))
    }

    public func captureLongExposure(durationSeconds: Double, settings: ExposureSettings, completion: @escaping (Result<Data, CameraError>) -> Void) {
        completion(.failure(.configurationFailed("Camera capture is unavailable on this platform")))
    }

    public func applyNightPresets(style: NightCaptureStyle) {}
}
#endif

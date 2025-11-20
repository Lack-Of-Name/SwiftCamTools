#if canImport(AVFoundation)
import Foundation
import AVFoundation
import SwiftCamCore
import SwiftCamCamera

@MainActor
final class CameraServiceBridge: ObservableObject {
    private let pipeline: CapturePipeline

    var session: AVCaptureSession? {
        pipeline.controller.captureSession
    }

    init() {
        pipeline = CapturePipeline()
    }

    func prepare() async {
        pipeline.start()
    }

    func capture(mode: CaptureMode, settings: ExposureSettings, completion: @escaping (Result<AVCapturePhoto, CameraError>) -> Void) {
        pipeline.controller.capture(mode: mode, settings: settings, completion: completion)
    }

    func applyPreview(settings: ExposureSettings) {
        pipeline.controller.applyPreviewExposure(settings: settings)
    }
}
#endif

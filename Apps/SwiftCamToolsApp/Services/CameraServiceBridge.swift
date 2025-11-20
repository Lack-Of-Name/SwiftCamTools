#if canImport(AVFoundation)
import Foundation
import AVFoundation
import Combine
import SwiftCamCore
import SwiftCamCamera

protocol CameraServiceBridgeDelegate: AnyObject {
    func cameraServiceBridge(_ bridge: CameraServiceBridge, didUpdateHistogram histogram: HistogramModel)
    func cameraServiceBridge(_ bridge: CameraServiceBridge, didUpdatePerformance state: CameraPerformanceState)
}

extension CameraServiceBridgeDelegate {
    func cameraServiceBridge(_ bridge: CameraServiceBridge, didUpdatePerformance state: CameraPerformanceState) {}
}

struct CameraPerformanceState {
    let frameRate: Double
    var isConstrained: Bool { frameRate > 0 && frameRate < 22 }
}

@MainActor
final class CameraServiceBridge: ObservableObject {
    private let pipeline: CapturePipeline
    private var cancellables = Set<AnyCancellable>()
    weak var delegate: CameraServiceBridgeDelegate?

    var session: AVCaptureSession? {
        pipeline.controller.captureSession
    }

    init() {
        pipeline = CapturePipeline()
        pipeline.$histogram
            .receive(on: DispatchQueue.main)
            .sink { [weak self] histogram in
                guard let self else { return }
                self.delegate?.cameraServiceBridge(self, didUpdateHistogram: histogram)
            }
            .store(in: &cancellables)

        pipeline.$frameRate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] fps in
                guard let self else { return }
                let state = CameraPerformanceState(frameRate: fps)
                self.delegate?.cameraServiceBridge(self, didUpdatePerformance: state)
            }
            .store(in: &cancellables)
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

    func updateHistogramThrottle(milliseconds: Double) {
        pipeline.updateHistogramThrottle(interval: milliseconds)
    }

    func setPreviewQuality(_ quality: CameraController.PreviewQuality) {
        pipeline.controller.setPreviewQuality(quality)
    }

    func recoverFromWhiteout(reason: String, revertToAutoExposure: Bool) {
        pipeline.controller.performWhiteoutRecovery(reason: reason, revertToAutoExposure: revertToAutoExposure)
    }

    func updateVideoOrientation(_ orientation: CameraOrientation) {
        pipeline.updateVideoOrientation(orientation)
    }

    func setHistogramEnabled(_ enabled: Bool) {
        pipeline.setHistogramEnabled(enabled)
    }
}
#endif

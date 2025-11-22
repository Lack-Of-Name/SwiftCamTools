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

    var minISO: Float { pipeline.minISO }
    var maxISO: Float { pipeline.maxISO }
    var minExposureDuration: Double { pipeline.minExposureDuration }
    var maxExposureDuration: Double { pipeline.maxExposureDuration }

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

    func capture(settings: ExposureSettings, completion: @escaping (Result<Data, CameraError>) -> Void) {
        pipeline.capture(settings: settings, completion: completion)
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

    func configureLowPowerPreview() {
        pipeline.controller.configureLowPowerPreview()
        pipeline.setHistogramEnabled(false)
        pipeline.updateHistogramThrottle(interval: 260)
    }
}
#endif

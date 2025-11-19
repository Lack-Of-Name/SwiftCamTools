#if !(canImport(AVFoundation) && canImport(Combine) && canImport(CoreVideo))
import Foundation
import SwiftCamCore

public final class CapturePipeline {
    public let controller: CameraController
    public let exposureQueue: ExposureQueue = ExposureQueue()
    public var histogram: HistogramModel = HistogramModel(samples: [])

    public init?(configuration: AppConfiguration = AppConfiguration()) {
        guard let controller = CameraController(configuration: configuration) else {
            return nil
        }
        self.controller = controller
    }

    public func start() {}

    public func queue(_ settings: ExposureSettings) {
        exposureQueue.enqueue(settings)
    }

    public func updateHistogram(with buffer: CVPixelBuffer) {}
}
#endif

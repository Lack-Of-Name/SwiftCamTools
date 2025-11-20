#if !(canImport(AVFoundation) && canImport(Combine) && canImport(CoreVideo))
import Foundation
import SwiftCamCore

public final class CapturePipeline {
    public let controller: CameraController
    public let exposureQueue: ExposureQueue = ExposureQueue()
    public var histogram: HistogramModel = HistogramModel(samples: [])

    public init(configuration: AppConfiguration = AppConfiguration()) {
        self.controller = CameraController(configuration: configuration)
    }

    public func start() {}

    public func queue(_ settings: ExposureSettings) {
        exposureQueue.enqueue(settings)
    }

    public func updateHistogram(with buffer: CVPixelBuffer) {}
}
#endif

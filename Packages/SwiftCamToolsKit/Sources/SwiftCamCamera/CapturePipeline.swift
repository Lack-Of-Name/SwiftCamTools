#if canImport(AVFoundation) && canImport(Combine) && canImport(CoreVideo)
import Foundation
import AVFoundation
import Combine
import CoreVideo
import SwiftCamCore

public final class CapturePipeline: ObservableObject {
    public let controller: CameraController
    public let exposureQueue: ExposureQueue = ExposureQueue()

    @Published public private(set) var histogram: HistogramModel = HistogramModel(samples: [])

    private var cancellables = Set<AnyCancellable>()

    public init?(configuration: AppConfiguration = AppConfiguration()) {
        guard let controller = CameraController(configuration: configuration) else { return nil }
        self.controller = controller
    }

    public func start() {
        controller.configure()
    }

    public func queue(_ settings: ExposureSettings) {
        exposureQueue.enqueue(settings)
    }

    public func updateHistogram(with buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return }
        var samples: [Double] = []
        samples.reserveCapacity(width * height)
        for index in 0..<(width * height) {
            samples.append(Double(baseAddress[index]) / 255.0)
        }
        histogram = HistogramModel(samples: samples, bucketCount: 32)
    }
}
#endif

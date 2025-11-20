#if canImport(AVFoundation) && canImport(Combine) && canImport(CoreVideo)
import Foundation
import AVFoundation
import Combine
import CoreVideo
import CoreMedia
import SwiftCamCore

public final class CapturePipeline: ObservableObject {
    public let controller: CameraController
    public let exposureQueue: ExposureQueue = ExposureQueue()

    @Published public private(set) var histogram: HistogramModel = HistogramModel(samples: [])
    @Published public private(set) var frameRate: Double = 0

    private var cancellables = Set<AnyCancellable>()
    private let histogramQueue = DispatchQueue(label: "SwiftCamTools.CapturePipeline.Histogram", qos: .userInitiated)
    private var lastHistogramUpdate = DispatchTime.now()
    private var histogramThrottleNanoseconds: UInt64 = 80_000_000
    private var lastFrameTimestamp: Double = 0
    private var fpsSamples: [Double] = []
    private var isHistogramEnabled = true

    public init(configuration: AppConfiguration = AppConfiguration()) {
        self.controller = CameraController(configuration: configuration)
        self.controller.sampleBufferHandler = { [weak self] sampleBuffer in
            self?.handleSampleBuffer(sampleBuffer)
        }
    }

    public func start() {
        controller.configure()
    }

    public func queue(_ settings: ExposureSettings) {
        exposureQueue.enqueue(settings)
    }

    public func updateHistogramThrottle(interval milliseconds: Double) {
        histogramThrottleNanoseconds = UInt64(max(20, milliseconds) * 1_000_000)
    }

    public func setHistogramEnabled(_ enabled: Bool) {
        isHistogramEnabled = enabled
    }

    public func updateVideoOrientation(_ orientation: CameraOrientation) {
        controller.updateVideoOrientation(orientation)
    }

    private func handleSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        updateFrameRate(with: sampleBuffer)
        guard isHistogramEnabled else { return }
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        throttledHistogramUpdate(with: buffer)
    }

    private func updateFrameRate(with sampleBuffer: CMSampleBuffer) {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let seconds = CMTimeGetSeconds(timestamp)
        guard seconds.isFinite else { return }
        guard lastFrameTimestamp > 0 else {
            lastFrameTimestamp = seconds
            return
        }
        let delta = seconds - lastFrameTimestamp
        guard delta > 0 else { return }
        lastFrameTimestamp = seconds

        let fps = 1.0 / delta
        fpsSamples.append(fps)
        if fpsSamples.count > 20 {
            fpsSamples.removeFirst()
        }
        let average = fpsSamples.reduce(0, +) / Double(fpsSamples.count)
        DispatchQueue.main.async {
            self.frameRate = average
        }
    }

    private func throttledHistogramUpdate(with buffer: CVPixelBuffer) {
        let now = DispatchTime.now()
        let delta = now.uptimeNanoseconds - lastHistogramUpdate.uptimeNanoseconds
        guard delta >= histogramThrottleNanoseconds else { return }
        lastHistogramUpdate = now

        histogramQueue.async {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
            let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
            guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self) else { return }
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)

            var samples: [Double] = []
            let strideStep = max(1, Int(sqrt(Double(width * height) / 4096.0)))
            for row in stride(from: 0, to: height, by: strideStep) {
                let rowPointer = baseAddress.advanced(by: row * bytesPerRow)
                for column in stride(from: 0, to: width, by: strideStep) {
                    samples.append(Double(rowPointer[column]) / 255.0)
                }
            }
            let histogramModel = HistogramModel(samples: samples, bucketCount: 32)

            DispatchQueue.main.async {
                self.histogram = histogramModel
            }
        }
    }
}
#endif

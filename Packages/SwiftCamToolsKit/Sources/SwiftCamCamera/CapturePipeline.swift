#if canImport(AVFoundation) && canImport(Combine) && canImport(CoreVideo) && canImport(CoreImage)
import Foundation
import AVFoundation
import Combine
import CoreVideo
import CoreMedia
import SwiftCamCore
import CoreImage

public final class CapturePipeline: ObservableObject {
    public let controller: CameraController
    public let exposureQueue: ExposureQueue = ExposureQueue()
    private let configuration: AppConfiguration

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
        self.configuration = configuration
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

    public func capture(settings: ExposureSettings, completion: @escaping (Result<Data, CameraError>) -> Void) {
        let requestedSeconds = max(0.0, Double(settings.duration) / 1_000_000_000.0)
        let clampedSeconds = min(configuration.maxLongExposureSeconds, requestedSeconds)
        var captureSettings = settings
        if clampedSeconds != requestedSeconds {
            captureSettings.duration = CMTimeValue(clampedSeconds * 1_000_000_000.0)
        }

        let hardwareLimit = controller.maxSupportedExposureSeconds
        if clampedSeconds > hardwareLimit + 0.01 {
            controller.captureLongExposure(durationSeconds: clampedSeconds, settings: captureSettings, completion: completion)
        } else {
            controller.capture(settings: captureSettings) { result in
                switch result {
                case .success(let photo):
                    guard let data = photo.fileDataRepresentation() else {
                        completion(.failure(.captureFailed("Unable to read captured photo data.")))
                        return
                    }
                    
                    // Apply post-processing if needed (Saturation, Noise Reduction)
                    if let processedData = self.processCapturedPhoto(data, settings: captureSettings) {
                        completion(.success(processedData))
                    } else {
                        completion(.success(data))
                    }
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    private func processCapturedPhoto(_ data: Data, settings: ExposureSettings) -> Data? {
        // Check if processing is needed
        // Default saturation is 1.0. Default noise reduction is 0.6 (but let's assume user wants control).
        // If saturation is 1.0 and noise reduction is "default" (whatever that means for the user), maybe skip?
        // But since the user complained, let's apply it if it deviates or if we want to enforce the slider.
        // The slider for noise reduction goes from 0.0 to 1.0.
        // If the user sets it to 0, they probably want NO noise reduction (or minimal).
        // If they set it to 1, they want MAX.
        
        // Since we can't easily know what the "default" embedded in the JPEG is, 
        // applying more noise reduction on top might be okay if the user requested it.
        // But applying saturation is definitely needed if != 1.0.
        
        let needsSaturation = abs(settings.colorSaturation - 1.0) > 0.01
        // We only apply extra noise reduction if requested explicitly high, or maybe always if we want to support the slider?
        // The user said "sliders change nothing". So we should probably apply it.
        // However, applying CINoiseReduction is expensive and might blur details.
        // Let's only apply if > 0.
        let needsNoiseReduction = settings.noiseReductionLevel > 0.01
        
        guard needsSaturation || needsNoiseReduction else { return nil }
        
        guard let ciImage = CIImage(data: data) else { return nil }
        var processed = ciImage
        
        if needsNoiseReduction {
            // Map 0.0-1.0 to reasonable inputNoiseLevel. Default is 0.02. Max is usually around 0.1 for usable results.
            let level = Double(settings.noiseReductionLevel) * 0.05
            let sharpness = 0.4 // Default
            processed = processed.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": level,
                "inputSharpness": sharpness
            ])
        }
        
        if needsSaturation {
            processed = processed.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: settings.colorSaturation
            ])
        }
        
        let context = CIContext()
        // Attempt to preserve metadata? CIContext.jpegRepresentation doesn't preserve all metadata automatically unless passed.
        // But we don't have easy access to the metadata dict from here without parsing.
        // CIImage(data:) reads properties.
        let colorSpace = processed.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return context.jpegRepresentation(of: processed, colorSpace: colorSpace, options: [:])
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

    public var minISO: Float { controller.minISO }
    public var maxISO: Float { controller.maxISO }
    public var minExposureDuration: Double { controller.minExposureDuration }
    public var maxExposureDuration: Double { controller.maxSupportedExposureSeconds }
}
#endif

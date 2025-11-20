#if canImport(AVFoundation) && canImport(CoreImage)
import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import ImageIO
import QuartzCore
import SwiftCamCore

final class LongExposureCaptureSession {
    private let duration: Double
    private let maxFrameCount: Int
    private let settings: ExposureSettings
    private let completion: (Result<Data, CameraError>) -> Void
    private let context = CIContext(options: [CIContextOption.priorityRequestLow: true])
    private var accumulator: CIImage?
    private var frameCount = 0
    private var startTime: CFTimeInterval?
    private var isFinishing = false
    private let targetShortSide: CGFloat = 1080

    init(duration: Double, maxFrameCount: Int, settings: ExposureSettings, completion: @escaping (Result<Data, CameraError>) -> Void) {
        self.duration = duration
        self.maxFrameCount = max(1, maxFrameCount)
        self.settings = settings
        self.completion = completion
    }

    func ingest(_ buffer: CMSampleBuffer) {
        guard !isFinishing else { return }
        if startTime == nil {
            startTime = CACurrentMediaTime()
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return }
        append(pixelBuffer: pixelBuffer)
        if shouldFinish() {
            forceFinish()
        }
    }

    func forceFinish() {
        guard !isFinishing else { return }
        isFinishing = true
        guard var image = accumulator, frameCount > 0 else {
            completion(.failure(.captureFailed("No frames were recorded for the long exposure.")))
            return
        }

        if frameCount > 1 {
            let scale = CGFloat(1.0 / Float(frameCount))
            let rVector = CIVector(x: scale, y: 0, z: 0, w: 0)
            let gVector = CIVector(x: 0, y: scale, z: 0, w: 0)
            let bVector = CIVector(x: 0, y: 0, z: scale, w: 0)
            let aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": rVector,
                "inputGVector": gVector,
                "inputBVector": bVector,
                "inputAVector": aVector,
                "inputBiasVector": CIVector.zero
            ])
        }

        guard let data = render(image: image) else {
            completion(.failure(.captureFailed("Failed to render long exposure output.")))
            return
        }
        completion(.success(data))
    }

    private func append(pixelBuffer: CVPixelBuffer) {
        let baseImage = CIImage(cvPixelBuffer: pixelBuffer)
        let downscaled = downscale(baseImage)
        let image = denoiseIfNeeded(downscaled)
        if let existing = accumulator {
            accumulator = image.applyingFilter("CIAdditionCompositing", parameters: ["inputBackgroundImage": existing])
        } else {
            accumulator = image
        }
        frameCount += 1
    }

    private func downscale(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let shortSide = min(extent.width, extent.height)
        guard shortSide > targetShortSide else { return image }
        let scale = targetShortSide / shortSide
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    private func denoiseIfNeeded(_ image: CIImage) -> CIImage {
        guard settings.noiseReductionLevel > 0 else { return image }
        let noiseLevel = Double(settings.noiseReductionLevel) * 0.02
        return image.applyingFilter("CINoiseReduction", parameters: [
            kCIInputNoiseLevelKey: noiseLevel,
            kCIInputSharpnessKey: 0.35
        ])
    }

    private func shouldFinish() -> Bool {
        if frameCount >= maxFrameCount {
            return true
        }
        guard let startTime else { return false }
        return CACurrentMediaTime() - startTime >= duration
    }

    private func render(image: CIImage) -> Data? {
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return nil }
        let data = NSMutableData()
        let uti: CFString
        if #available(iOS 11.0, macOS 10.13, *) {
            uti = AVFileType.heic as CFString
        } else {
            uti = AVFileType.jpeg as CFString
        }
        guard let destination = CGImageDestinationCreateWithData(data, uti, 1, nil) ?? CGImageDestinationCreateWithData(data, AVFileType.jpeg as CFString, 1, nil) else {
            return nil
        }
        let options = [kCGImageDestinationLossyCompressionQuality as String: 0.92] as CFDictionary
        CGImageDestinationAddImage(destination, cgImage, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
#endif

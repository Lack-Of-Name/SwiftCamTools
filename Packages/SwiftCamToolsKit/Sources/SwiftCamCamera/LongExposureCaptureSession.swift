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
    private var luminanceSamples: [Double] = []
    private var totalWeight: Double = 0
    private let apertureBoost: Double
    private let stackingBiasScale: Double
    private let toneBiasEV: Double

    init(duration: Double, maxFrameCount: Int, settings: ExposureSettings, completion: @escaping (Result<Data, CameraError>) -> Void) {
        self.duration = duration
        self.maxFrameCount = max(1, maxFrameCount)
        self.settings = settings
        self.completion = completion
        let apertureValue = max(1.0, Double(settings.aperture))
        self.apertureBoost = max(0.35, min(2.6, pow(1.8 / apertureValue, 2.0)))
        self.stackingBiasScale = max(0.4, min(1.8, pow(2.0, Double(settings.exposureBias) * 0.5)))
        self.toneBiasEV = Double(settings.exposureBias)
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

        let normalization = CGFloat(totalWeight > 0 ? (1.0 / totalWeight) : (1.0 / max(1, frameCount)))
        image = image.applyingFilter("CIColorMatrix", parameters: makeScaleParameters(gain: normalization))

        let toneMapped = applyToneMapping(to: image)
        let biased = applyExposureBias(to: toneMapped)
        guard let data = render(image: biased) else {
            completion(.failure(.captureFailed("Failed to render long exposure output.")))
            return
        }
        completion(.success(data))
    }

    private func append(pixelBuffer: CVPixelBuffer) {
        let baseImage = CIImage(cvPixelBuffer: pixelBuffer)
        let downscaled = downscale(baseImage)
        let image = denoiseIfNeeded(downscaled)
        if let luminance = sampleLuminance(from: image) {
            luminanceSamples.append(luminance)
            accumulate(image: image, weight: weight(for: luminance))
        } else {
            accumulate(image: image, weight: 1.0)
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
        let noiseBase = Double(settings.noiseReductionLevel) * 0.02
        let noiseLevel = noiseBase * (1.0 / max(0.6, min(apertureBoost, 2.2)))
        let sharpness = max(0.2, min(0.6, 0.35 + (apertureBoost - 1.0) * 0.18))
        return image.applyingFilter("CINoiseReduction", parameters: [
            "inputNoiseLevel": noiseLevel,
            "inputSharpness": sharpness
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
        let heicUTI: CFString? = {
            if #available(iOS 11.0, macOS 10.13, *) {
                return AVFileType.heic as CFString
            }
            return nil
        }()
        let jpegUTI: CFString = "public.jpeg" as CFString
        guard let destination = CGImageDestinationCreateWithData(data, heicUTI ?? jpegUTI, 1, nil) ?? CGImageDestinationCreateWithData(data, jpegUTI, 1, nil) else {
            return nil
        }
        let options = [kCGImageDestinationLossyCompressionQuality as String: 0.92] as CFDictionary
        CGImageDestinationAddImage(destination, cgImage, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func sampleLuminance(from image: CIImage) -> Double? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let averageImage = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: extent)])
        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(
            averageImage,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )
        let r = Double(bitmap[0]) / 255.0
        let g = Double(bitmap[1]) / 255.0
        let b = Double(bitmap[2]) / 255.0
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private func applyToneMapping(to image: CIImage) -> CIImage {
        guard !luminanceSamples.isEmpty else { return image }
        let averageLuminance = luminanceSamples.reduce(0, +) / Double(luminanceSamples.count)
        let detailBoost = max(-0.15, min(0.2, (apertureBoost - 1.0) * 0.12))

        if averageLuminance < 0.22 {
            let exposureBoost = min(1.2, 0.5 + (0.22 - averageLuminance) * 2.5)
            return image
                .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: exposureBoost])
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputBrightnessKey: 0.05,
                    kCIInputSaturationKey: 0.95,
                    kCIInputContrastKey: 1.15
                ])
                .applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.35 + detailBoost])
        }

        if averageLuminance > 0.65 {
            let highlightAmount = max(0.25, 1.0 - (averageLuminance - 0.65) * 1.6)
            return image
                .applyingFilter("CIHighlightShadowAdjust", parameters: [
                    "inputHighlightAmount": highlightAmount,
                    "inputShadowAmount": 0.0
                ])
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputBrightnessKey: -0.05,
                    kCIInputSaturationKey: 0.9,
                    kCIInputContrastKey: 0.95
                ])
        }

        return image.applyingFilter("CIColorControls", parameters: [
            kCIInputBrightnessKey: 0.0,
            kCIInputSaturationKey: 1.05,
            kCIInputContrastKey: 1.05
        ])
    }

    private func accumulate(image: CIImage, weight: Double) {
        let clampedWeight = max(0.2, min(weight, 3.0))
        let weightedImage = image.applyingFilter("CIColorMatrix", parameters: makeScaleParameters(gain: CGFloat(clampedWeight)))
        if let existing = accumulator {
            accumulator = weightedImage.applyingFilter("CIAdditionCompositing", parameters: ["inputBackgroundImage": existing])
        } else {
            accumulator = weightedImage
        }
        totalWeight += clampedWeight
    }

    private func weight(for luminance: Double) -> Double {
        switch luminance {
        case ..<0.15:
            return 2.4 * apertureBoost * stackingBiasScale
        case ..<0.35:
            return 1.7 * apertureBoost * stackingBiasScale
        case ..<0.65:
            return 1.0 * apertureBoost * stackingBiasScale
        default:
            return 0.55 * apertureBoost * stackingBiasScale
        }
    }

    private func applyExposureBias(to image: CIImage) -> CIImage {
        guard abs(toneBiasEV) > 0.01 else { return image }
        return image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: toneBiasEV])
    }

    private func makeScaleParameters(gain: CGFloat) -> [String: Any] {
        let safeGain = max(0, gain)
        return [
            "inputRVector": CIVector(x: safeGain, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: safeGain, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: safeGain, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ]
    }
}
#endif

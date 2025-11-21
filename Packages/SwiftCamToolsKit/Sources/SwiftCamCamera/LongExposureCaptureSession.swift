#if canImport(AVFoundation) && canImport(CoreImage)
import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import ImageIO
import QuartzCore
import SwiftCamCore
import simd

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
    private var highlightSamples: [Double] = []
    private var colorSamples: [SIMD3<Double>] = []
    private let saturationTarget: Double

    init(duration: Double, maxFrameCount: Int, settings: ExposureSettings, completion: @escaping (Result<Data, CameraError>) -> Void) {
        self.duration = duration
        self.maxFrameCount = max(1, maxFrameCount)
        self.settings = settings
        self.completion = completion
        let apertureValue = max(1.0, Double(settings.aperture))
        self.apertureBoost = max(0.35, min(2.6, pow(1.8 / apertureValue, 2.0)))
        self.stackingBiasScale = max(0.4, min(1.8, pow(2.0, Double(settings.exposureBias) * 0.5)))
        self.toneBiasEV = Double(settings.exposureBias)
        self.saturationTarget = Double(settings.colorSaturation)
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

        let normalization: CGFloat
        if totalWeight > 0 {
            normalization = CGFloat(1.0 / totalWeight)
        } else {
            normalization = CGFloat(1.0 / Double(max(1, frameCount)))
        }
        image = image.applyingFilter("CIColorMatrix", parameters: makeScaleParameters(gain: normalization))

        let toneMapped = applyToneMapping(to: image)
        let colorPreserved = applyColorPreservation(to: toneMapped)
        let saturated = applySaturation(to: colorPreserved)
        let biased = applyExposureBias(to: saturated)
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
        if let metrics = sampleSceneMetrics(from: image) {
            luminanceSamples.append(metrics.luminance)
            highlightSamples.append(metrics.highlight)
            colorSamples.append(metrics.averageColor)
            let guarded = applyChromaGuard(to: image, metrics: metrics)
            let frameWeight = weight(for: metrics.luminance, highlight: metrics.highlight, chroma: metrics.chroma)
            accumulate(image: guarded, weight: frameWeight)
        } else {
            accumulate(image: image, weight: weight(for: 0.5, highlight: 0.5, chroma: 0.2))
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

    private func sampleSceneMetrics(from image: CIImage) -> SceneMetrics? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let averageImage = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: extent)])
        var averagePixel = [UInt8](repeating: 0, count: 4)
        context.render(
            averageImage,
            toBitmap: &averagePixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )

        let maximumImage = image.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: extent)])
        var maximumPixel = [UInt8](repeating: 0, count: 4)
        context.render(
            maximumImage,
            toBitmap: &maximumPixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )

        let r = Double(averagePixel[0]) / 255.0
        let g = Double(averagePixel[1]) / 255.0
        let b = Double(averagePixel[2]) / 255.0
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let highlight = Double(max(maximumPixel[0], max(maximumPixel[1], maximumPixel[2]))) / 255.0
        let color = SIMD3<Double>(r, g, b)
        let maxChannel = max(r, max(g, b))
        let minChannel = min(r, min(g, b))
        let chroma = max(0.0, maxChannel - minChannel)
        return SceneMetrics(luminance: luminance, averageColor: color, highlight: highlight, chroma: chroma)
    }

    private func applyToneMapping(to image: CIImage) -> CIImage {
        guard let summary = sceneSummary else { return image }
        let averageLuminance = summary.luminance
        let highlightClipping = summary.highlightRatio
        let detailBoost = max(-0.15, min(0.2, (apertureBoost - 1.0) * 0.12))
        let dayBlend = dayModeBlend(for: summary)

        var working = image

        if summary.shadowRatio > 0.18 && summary.brightRatio > 0.06 {
            working = applyDualToneCurve(to: working, summary: summary)
        }

        if highlightClipping > 0.03 || dayBlend > 0.3 {
            let compression = max(0.05, min(0.85, 0.25 + highlightClipping * 0.9 + dayBlend * 0.4))
            let highlightAmount = max(0.12, 1.0 - compression)
            let shadowLift = min(0.45, compression * 0.35)
            working = working
                .applyingFilter("CIHighlightShadowAdjust", parameters: [
                    "inputHighlightAmount": highlightAmount,
                    "inputShadowAmount": shadowLift
                ])
                .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -compression * 0.75])
        }

        if dayBlend > 0.4 {
            working = working.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: -0.02 * dayBlend,
                kCIInputSaturationKey: 1.0 - 0.08 * dayBlend,
                kCIInputContrastKey: 1.02 + 0.06 * dayBlend
            ])
        }

        if averageLuminance < 0.22 {
            let exposureBoost = min(1.2, 0.5 + (0.22 - averageLuminance) * 2.5)
            return working
                .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: exposureBoost])
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputBrightnessKey: 0.05,
                    kCIInputSaturationKey: 0.95,
                    kCIInputContrastKey: 1.15
                ])
                .applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.35 + detailBoost])
        }

        if averageLuminance > 0.65 {
            let highlightAmount = max(0.2, 1.0 - (averageLuminance - 0.65) * 1.8)
            return working
                .applyingFilter("CIHighlightShadowAdjust", parameters: [
                    "inputHighlightAmount": highlightAmount,
                    "inputShadowAmount": 0.05
                ])
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputBrightnessKey: -0.08,
                    kCIInputSaturationKey: 0.9,
                    kCIInputContrastKey: 0.95
                ])
        }

        return working.applyingFilter("CIColorControls", parameters: [
            kCIInputBrightnessKey: -0.01,
            kCIInputSaturationKey: 1.03,
            kCIInputContrastKey: 1.04
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

    private func weight(for luminance: Double, highlight: Double, chroma: Double) -> Double {
        let base: Double
        switch luminance {
        case ..<0.15:
            base = 2.4
        case ..<0.35:
            base = 1.7
        case ..<0.65:
            base = 1.0
        default:
            base = 0.55
        }
        let highlightPenalty = max(0.35, 1.0 - max(0.0, highlight - 0.7) * 1.1)
        let chromaPenalty = max(0.4, 1.0 - chroma * 0.9)
        return max(0.2, base * apertureBoost * stackingBiasScale * highlightPenalty * chromaPenalty)
    }

    private func applyExposureBias(to image: CIImage) -> CIImage {
        guard abs(toneBiasEV) > 0.01 else { return image }
        return image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: toneBiasEV])
    }

    private func applySaturation(to image: CIImage) -> CIImage {
        let target = effectiveSaturationTarget(for: sceneSummary)
        guard abs(target - 1.0) > 0.01 else { return image }
        return image.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: target,
            kCIInputBrightnessKey: 0,
            kCIInputContrastKey: 1
        ])
    }

    private func applyColorPreservation(to image: CIImage) -> CIImage {
        guard let averageColor = averageSceneColor else { return image }
        let neutral = max(0.08, min(0.92, (averageColor.x + averageColor.y + averageColor.z) / 3.0))
        guard neutral > 0 else { return image }

        let rScale = smoothNeutralScale(channel: averageColor.x, target: neutral)
        let gScale = smoothNeutralScale(channel: averageColor.y, target: neutral)
        let bScale = smoothNeutralScale(channel: averageColor.z, target: neutral)

        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(rScale), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(gScale), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(bScale), w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
    }

    private func applyChromaGuard(to image: CIImage, metrics: SceneMetrics) -> CIImage {
        let target = perFrameSaturationTarget(for: metrics)
        guard abs(target - 1.0) > 0.02 else { return image }
        return image.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: target,
            kCIInputBrightnessKey: 0,
            kCIInputContrastKey: 1
        ])
    }

    private struct SceneMetrics {
        let luminance: Double
        let averageColor: SIMD3<Double>
        let highlight: Double
        let chroma: Double
    }

    private struct SceneSummary {
        let luminance: Double
        let highlightRatio: Double
        let blueRatio: Double
        let shadowRatio: Double
        let brightRatio: Double
    }

    private var averageSceneColor: SIMD3<Double>? {
        guard !colorSamples.isEmpty else { return nil }
        let sum = colorSamples.reduce(SIMD3<Double>(repeating: 0)) { $0 + $1 }
        return sum / Double(colorSamples.count)
    }

    private var sceneSummary: SceneSummary? {
        guard !luminanceSamples.isEmpty else { return nil }
        let averageLuminance = luminanceSamples.reduce(0, +) / Double(luminanceSamples.count)
        let highlightRatio: Double
        if highlightSamples.isEmpty {
            highlightRatio = 0
        } else {
            let clipped = highlightSamples.filter { $0 >= 0.92 }.count
            highlightRatio = Double(clipped) / Double(highlightSamples.count)
        }
        let blueRatio: Double
        if let color = averageSceneColor {
            let total = max(0.001, color.x + color.y + color.z)
            blueRatio = max(0.0, min(1.0, color.z / total))
        } else {
            blueRatio = 1.0 / 3.0
        }
        let shadowRatio = Double(luminanceSamples.filter { $0 < 0.22 }.count) / Double(luminanceSamples.count)
        let brightRatio = Double(luminanceSamples.filter { $0 > 0.72 }.count) / Double(luminanceSamples.count)
        return SceneSummary(
            luminance: averageLuminance,
            highlightRatio: highlightRatio,
            blueRatio: blueRatio,
            shadowRatio: shadowRatio,
            brightRatio: brightRatio
        )
    }

    private func smoothNeutralScale(channel: Double, target: Double) -> Double {
        guard channel > 0.0001 else { return 1.0 }
        let raw = target / channel
        let clamped = max(0.6, min(raw, 1.6))
        return lerp(1.0, clamped, t: 0.35)
    }

    private func lerp(_ a: Double, _ b: Double, t: Double) -> Double {
        a + (b - a) * max(0.0, min(1.0, t))
    }

    private func perFrameSaturationTarget(for metrics: SceneMetrics) -> Double {
        let highlightPenalty = max(0.0, metrics.highlight - 0.75) * 1.2
        let chromaPenalty = max(0.0, metrics.chroma - 0.35) * 0.9
        let luminanceBoost = metrics.luminance < 0.18 ? (0.18 - metrics.luminance) * 0.6 : 0.0
        let reduction = min(0.5, highlightPenalty + chromaPenalty)
        let target = 1.0 - reduction + luminanceBoost
        return max(0.7, min(1.15, target))
    }

    private func dayModeBlend(for summary: SceneSummary) -> Double {
        let luminanceScore = max(0.0, min(1.0, (summary.luminance - 0.34) / 0.32))
        let highlightScore = max(0.0, min(1.0, (summary.highlightRatio - 0.05) * 6.0))
        let blueScore = max(0.0, min(1.0, (summary.blueRatio - 0.42) * 1.8))
        let blueGate = summary.luminance > 0.55 ? blueScore : blueScore * max(0.0, (summary.luminance - 0.35) / 0.2)
        return max(0.0, min(1.0, luminanceScore * 0.55 + highlightScore * 0.35 + blueGate * 0.1))
    }

    private func effectiveSaturationTarget(for summary: SceneSummary?) -> Double {
        guard let summary else { return saturationTarget }
        let dayBlend = dayModeBlend(for: summary)
        let highlightPenalty = min(1.0, summary.highlightRatio * 1.6)
        let shadowBonus = max(0.0, (0.28 - summary.luminance) * 1.4)
        let pull = min(1.0, dayBlend * 0.45 + highlightPenalty * 0.5)
        let lift = min(0.25, shadowBonus)
        let neutralBlend = lerp(saturationTarget, 1.0, t: pull)
        return neutralBlend + lift
    }

    private func applyDualToneCurve(to image: CIImage, summary: SceneSummary) -> CIImage {
        let shadowLift = min(0.35, summary.shadowRatio * 0.55)
        let midLift = min(0.2, shadowLift * 0.8)
        let highlightRollOff = min(0.45, summary.highlightRatio * 0.8 + summary.brightRatio * 0.6)
        let p0 = CIVector(x: 0.0, y: CGFloat(max(0.0, shadowLift * 0.75)))
        let p1 = CIVector(x: 0.25, y: CGFloat(min(0.45, 0.25 + shadowLift * 0.85)))
        let p2 = CIVector(x: 0.5, y: CGFloat(min(0.75, 0.5 + midLift - highlightRollOff * 0.15)))
        let p3 = CIVector(x: 0.75, y: CGFloat(max(0.5, 0.75 - highlightRollOff * 0.65)))
        let p4 = CIVector(x: 1.0, y: CGFloat(max(0.65, 1.0 - highlightRollOff)))

        return image
            .applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": p0,
                "inputPoint1": p1,
                "inputPoint2": p2,
                "inputPoint3": p3,
                "inputPoint4": p4
            ])
            .applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: shadowLift * 0.1,
                kCIInputContrastKey: 1.0 - highlightRollOff * 0.1,
                kCIInputSaturationKey: 1.0
            ])
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

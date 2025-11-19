import Foundation
import MetalPetal
import Accelerate
import SwiftCamCore

public protocol NoiseReducer {
    func reduceNoise(pixelBuffer: CVPixelBuffer, level: Float) -> MTIImage?
}

public final class AdaptiveNoiseReducer: NoiseReducer {
    private let context: MTIContext

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device else { return nil }
        guard let ctx = try? MTIContext(device: device) else { return nil }
        self.context = ctx
    }

    public func reduceNoise(pixelBuffer: CVPixelBuffer, level: Float) -> MTIImage? {
        let clampedLevel = max(0.1, min(level, 1.0))
        let radius = Float(2.0 * clampedLevel)
        let inputImage = MTIImage(cvPixelBuffer: pixelBuffer, alphaType: .alphaIsOne)
        let filter = MTINoiseReductionFilter()
        filter.inputImage = inputImage
        filter.noiseLevel = radius
        return filter.outputImage
    }
}

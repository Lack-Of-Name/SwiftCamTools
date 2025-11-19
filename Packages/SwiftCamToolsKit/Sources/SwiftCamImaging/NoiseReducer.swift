import Foundation
import SwiftCamCore

#if canImport(MetalPetal) && canImport(CoreVideo)
import MetalPetal
import CoreVideo

public protocol NoiseReducer {
    func reduceNoise(pixelBuffer: CVPixelBuffer, level: Float) -> MTIImage?
}

public final class AdaptiveNoiseReducer: NoiseReducer {
    private let device: MTLDevice

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device else { return nil }
        self.device = device
    }

    public func reduceNoise(pixelBuffer: CVPixelBuffer, level: Float) -> MTIImage? {
        // Placeholder adaptive curve ensures API compatibility even if no additional filtering is applied.
        _ = max(0.1, min(level, 1.0))
        return MTIImage(cvPixelBuffer: pixelBuffer, alphaType: .alphaIsOne)
    }
}
#endif

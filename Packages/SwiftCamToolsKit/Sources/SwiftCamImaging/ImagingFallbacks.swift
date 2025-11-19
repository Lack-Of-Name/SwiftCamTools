import Foundation
import SwiftCamCore

#if !(canImport(MetalPetal) && canImport(CoreVideo))

public struct MTIImage {}

public protocol NoiseReducer {
    func reduceNoise(pixelBuffer: CVPixelBuffer, level: Float) -> MTIImage?
}

public final class AdaptiveNoiseReducer: NoiseReducer {
    public init?(device: Any? = nil) {
        return nil
    }

    public func reduceNoise(pixelBuffer: CVPixelBuffer, level: Float) -> MTIImage? {
        nil
    }
}

public final class ImageFusionEngine {
    public init(reducer: NoiseReducer) {}

    public func fuse(buffers: [CVPixelBuffer], settings: ExposureSettings) -> MTIImage? {
        nil
    }
}

public final class MetalNoiseReducer {
    public init?(device: Any? = nil) {
        return nil
    }

    public func denoise(pixelBuffer: CVPixelBuffer, sigma: Float) -> CVPixelBuffer? {
        nil
    }
}
#endif

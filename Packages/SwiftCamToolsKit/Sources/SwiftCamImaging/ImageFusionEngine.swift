import Foundation
import MetalPetal
import SwiftCamCore

public final class ImageFusionEngine {
    private let reducer: NoiseReducer

    public init(reducer: NoiseReducer) {
        self.reducer = reducer
    }

    public func fuse(buffers: [CVPixelBuffer], settings: ExposureSettings) -> MTIImage? {
        guard !buffers.isEmpty else { return nil }
        let outputs = buffers.compactMap { reducer.reduceNoise(pixelBuffer: $0, level: settings.noiseReductionLevel) }
        guard var composite = outputs.first else { return nil }
        for image in outputs.dropFirst() {
            let filter = MTIMultilayerCompositingFilter()
            filter.inputBackgroundImage = composite
            var layer = MTILayer()
            layer.content = image
            filter.layers = [layer]
            if let fused = filter.outputImage {
                composite = fused
            }
        }
        return composite
    }
}

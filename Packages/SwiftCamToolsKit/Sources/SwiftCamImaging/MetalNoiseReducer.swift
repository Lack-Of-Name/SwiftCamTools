import Foundation
import Metal
import MetalPerformanceShaders
import SwiftCamCore
import CoreVideo

public final class MetalNoiseReducer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue
    }

    public func denoise(pixelBuffer: CVPixelBuffer, sigma: Float) -> CVPixelBuffer? {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }
        guard let texture = makeTexture(from: pixelBuffer) else { return nil }

        let filter = MPSImageGaussianBlur(device: device, sigma: sigma)
        filter.encode(commandBuffer: commandBuffer, inPlaceTexture: &texture, fallbackCopyAllocator: nil)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return pixelBuffer
    }

    private func makeTexture(from buffer: CVPixelBuffer) -> MTLTexture? {
        var textureRef: CVMetalTexture?
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let format = MTLPixelFormat.bgra8Unorm
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        guard let cache = textureCache else { return nil }
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, format, width, height, 0, &textureRef)
        return textureRef.flatMap { CVMetalTextureGetTexture($0) }
    }

    private var textureCache: CVMetalTextureCache?
}

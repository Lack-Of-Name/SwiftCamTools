import Foundation

#if canImport(AVFoundation) && canImport(CoreMedia) && canImport(CoreVideo) && canImport(Metal) && canImport(Vision)
import CoreMedia
import CoreVideo
import Metal
import MetalPerformanceShaders
import Vision
import Accelerate
import SwiftCamCore

public class NightModeProcessor {
    
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var averagePipeline: MTLComputePipelineState?
    private var maxBlendPipeline: MTLComputePipelineState?
    
    private var accumulatorTexture: MTLTexture?
    private var frameCount: Int = 0
    private var referenceBuffer: CVPixelBuffer?
    
    private let visionRequestHandler = VNSequenceRequestHandler()
    private var textureCache: CVMetalTextureCache?
    
    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw CameraError.configurationFailed("Metal setup failed")
        }
        self.device = device
        self.commandQueue = queue
        
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        
        try loadMetalLibrary()
    }
    
    private func loadMetalLibrary() throws {
        // Load the default library from the bundle
        let bundle = Bundle.module
        guard let library = try? device.makeDefaultLibrary(bundle: bundle) else {
            return
        }
        
        if let averageFunction = library.makeFunction(name: "average_stack_kernel") {
            averagePipeline = try device.makeComputePipelineState(function: averageFunction)
        }
        
        if let maxBlendFunction = library.makeFunction(name: "max_blend_kernel") {
            maxBlendPipeline = try device.makeComputePipelineState(function: maxBlendFunction)
        }
    }
    
    public func reset() {
        accumulatorTexture = nil
        frameCount = 0
        referenceBuffer = nil
    }
    
    public func process(sampleBuffer: CMSampleBuffer, style: NightCaptureStyle) -> CVPixelBuffer? {
        guard style != .off, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return CMSampleBufferGetImageBuffer(sampleBuffer)
        }
        
        // Initialize accumulator if needed
        if accumulatorTexture == nil {
            let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                           width: CVPixelBufferGetWidth(pixelBuffer),
                                                                           height: CVPixelBufferGetHeight(pixelBuffer),
                                                                           mipmapped: false)
            textureDescriptor.usage = [.shaderRead, .shaderWrite]
            accumulatorTexture = device.makeTexture(descriptor: textureDescriptor)
            
            // Copy first frame to accumulator
            copy(pixelBuffer: pixelBuffer, to: accumulatorTexture!)
            
            if style == .deepExposure {
                referenceBuffer = pixelBuffer
            }
            
            frameCount = 1
            return pixelBuffer // Return first frame as is for preview
        }
        
        frameCount += 1
        
        switch style {
        case .deepExposure:
            return processDeepExposure(pixelBuffer: pixelBuffer)
        case .lightTrails:
            return processLightTrails(pixelBuffer: pixelBuffer)
        case .off:
            return pixelBuffer
        }
    }
    
    // MARK: - Deep Exposure (Stacking + Alignment + CLAHE)
    
    private func processDeepExposure(pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        guard let referenceBuffer = referenceBuffer,
              let accumulator = accumulatorTexture,
              let pipeline = averagePipeline,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        
        // Step 1: Alignment
        var sourceTexture: MTLTexture?
        
        let request = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: referenceBuffer)
        do {
            try visionRequestHandler.perform([request], on: pixelBuffer)
            if let observation = request.results?.first as? VNImageTranslationAlignmentObservation {
                let transform = observation.alignmentTransform
                // Apply transform using MPS
                // Note: VNImageTranslationAlignmentObservation returns a transform in image coordinates.
                // We need to translate the image.
                
                if let inputTexture = makeTexture(from: pixelBuffer) {
                    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: inputTexture.pixelFormat, width: inputTexture.width, height: inputTexture.height, mipmapped: false)
                    descriptor.usage = [.shaderRead, .shaderWrite]
                    if let aligned = device.makeTexture(descriptor: descriptor) {
                        
                        // Use MPSImageBilinearScale for translation
                        let scale = MPSImageBilinearScale(device: device)
                        var scaleTransform = MPSScaleTransform(scaleX: 1.0, scaleY: 1.0, translateX: Double(transform.tx), translateY: Double(transform.ty))
                        withUnsafePointer(to: &scaleTransform) { ptr in
                            scale.scaleTransform = ptr
                            scale.encode(commandBuffer: commandBuffer, sourceTexture: inputTexture, destinationTexture: aligned)
                            scale.scaleTransform = nil
                        }
                        sourceTexture = aligned
                    } else {
                        sourceTexture = inputTexture
                    }
                }
            }
        } catch {
            print("Alignment failed: \(error)")
        }
        
        // Fallback if alignment failed or wasn't needed
        if sourceTexture == nil {
            sourceTexture = makeTexture(from: pixelBuffer)
        }
        
        guard let inputTexture = sourceTexture else { return nil }
        
        // Step 2: Averaging
        computeEncoder.setComputePipelineState(pipeline)
        computeEncoder.setTexture(inputTexture, index: 0)
        computeEncoder.setTexture(accumulator, index: 1)
        
        var weight = 1.0 / Float(frameCount)
        computeEncoder.setBytes(&weight, length: MemoryLayout<Float>.size, index: 0)
        
        let w = pipeline.threadExecutionWidth
        let h = pipeline.maxTotalThreadsPerThreadgroup / w
        let threadsPerThreadgroup = MTLSizeMake(w, h, 1)
        let threadsPerGrid = MTLSizeMake(accumulator.width, accumulator.height, 1)
        
        computeEncoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        computeEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        // Step 3: Tone Map (CLAHE)
        // Convert accumulator back to CVPixelBuffer to apply vImage
        // Note: Doing this every frame might be slow. Usually done at the end of capture.
        // But the prompt implies "The processor needs to handle CMSampleBuffers", maybe for preview?
        // If it's for final capture, we might return nil until the end.
        // Assuming we return the updated preview:
        
        if let outputBuffer = makeCVPixelBuffer(from: accumulator) {
             return applyCLAHE(to: outputBuffer)
        }
        
        return nil
    }
    
    // MARK: - Light Trails (Max Blend)
    
    private func processLightTrails(pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        guard let accumulator = accumulatorTexture,
              let pipeline = maxBlendPipeline,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder(),
              let inputTexture = makeTexture(from: pixelBuffer) else {
            return nil
        }
        
        // Step 1: No Alignment
        
        // Step 2: Max Blend
        computeEncoder.setComputePipelineState(pipeline)
        computeEncoder.setTexture(inputTexture, index: 0)
        computeEncoder.setTexture(accumulator, index: 1)
        
        let w = pipeline.threadExecutionWidth
        let h = pipeline.maxTotalThreadsPerThreadgroup / w
        let threadsPerThreadgroup = MTLSizeMake(w, h, 1)
        let threadsPerGrid = MTLSizeMake(accumulator.width, accumulator.height, 1)
        
        computeEncoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        computeEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        // Step 3: Live Update
        return makeCVPixelBuffer(from: accumulator)
    }
    
    // MARK: - Helpers
    
    private func applyCLAHE(to pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return pixelBuffer }
        
        let width = vImagePixelCount(CVPixelBufferGetWidth(pixelBuffer))
        let height = vImagePixelCount(CVPixelBufferGetHeight(pixelBuffer))
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        
        var inBuffer = vImage_Buffer(data: baseAddress, height: height, width: width, rowBytes: rowBytes)

        if #available(iOS 14.0, macOS 11.0, *) {
            var outBuffer = vImage_Buffer()
            let initStatus = vImageBuffer_Init(&outBuffer, height, width, 32, vImage_Flags(kvImageNoFlags))
            guard initStatus == kvImageNoError, let outData = outBuffer.data else {
                return pixelBuffer
            }
            defer { free(outData) }

            let tileWidth: vImagePixelCount = 8
            let tileHeight: vImagePixelCount = 8
            let clipLimit: Float = 3.0
            let histogram: UnsafeMutableRawPointer? = nil

            let claheError = vImageContrastLimitedAdaptiveHistogramEqualization_ARGB8888(
                &inBuffer,
                &outBuffer,
                histogram,
                tileWidth,
                tileHeight,
                clipLimit,
                vImage_Flags(kvImageLeaveAlphaUnchanged)
            )

            if claheError == kvImageNoError {
                _ = vImageCopyBuffer(&outBuffer, &inBuffer, MemoryLayout<UInt32>.size, vImage_Flags(kvImageNoFlags))
            } else {
                print("CLAHE failed with error: \(claheError)")
            }
        } else {
            let error = vImageEqualization_ARGB8888(&inBuffer, &inBuffer, vImage_Flags(kvImageLeaveAlphaUnchanged))
            if error != kvImageNoError {
                print("Equalization failed with error: \(error)")
            }
        }
        
        return pixelBuffer
    }
    
    private func copy(pixelBuffer: CVPixelBuffer, to texture: MTLTexture) {
        guard let inputTexture = makeTexture(from: pixelBuffer) else { return }
        
        let commandBuffer = commandQueue.makeCommandBuffer()
        let blitEncoder = commandBuffer?.makeBlitCommandEncoder()
        
        blitEncoder?.copy(from: inputTexture, to: texture)
        blitEncoder?.endEncoding()
        commandBuffer?.commit()
        commandBuffer?.waitUntilCompleted()
    }
    
    private func makeTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let textureCache = textureCache else { return nil }
        
        var cvTexture: CVMetalTexture?
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                  textureCache,
                                                  pixelBuffer,
                                                  nil,
                                                  .bgra8Unorm,
                                                  width,
                                                  height,
                                                  0,
                                                  &cvTexture)
        
        guard let cvTexture = cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTexture)
    }
    
    private func makeCVPixelBuffer(from texture: MTLTexture) -> CVPixelBuffer? {
        // Create a CVPixelBuffer from MTLTexture
        // This usually requires a pool or creating a new buffer and blitting.
        
        var pixelBuffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, texture.width, texture.height, kCVPixelFormatType_32BGRA, attrs, &pixelBuffer)
        
        guard let buffer = pixelBuffer else { return nil }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        if let bytes = CVPixelBufferGetBaseAddress(buffer) {
            texture.getBytes(bytes, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        
        return buffer
    }
}
#endif

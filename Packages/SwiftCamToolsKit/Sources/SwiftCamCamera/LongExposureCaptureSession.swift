#if canImport(AVFoundation) && canImport(CoreImage) && canImport(Vision)
import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import ImageIO
import Vision
import SwiftCamCore
import SwiftCamImaging

final class LongExposureCaptureSession {
    private let duration: Double
    private let maxFrameCount: Int
    private let settings: ExposureSettings
    private let completion: (Result<Data, CameraError>) -> Void
    
    // Processing Context
    private let context = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: false])
    private let processingQueue = DispatchQueue(label: "SwiftCamTools.LongExposure.Processing", qos: .userInitiated)
    
    // State
    private var startTime: CFTimeInterval?
    private var frameCount = 0
    private var isFinishing = false
    
    // Accumulation
    private var accumulator: CIImage?
    private var totalWeight: Double = 0.0
    private var referencePixelBuffer: CVPixelBuffer?
    
    // Alignment
    private let sequenceRequestHandler = VNSequenceRequestHandler()
    
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
        
        // Retain buffer for async processing
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        
        processingQueue.async { [weak self] in
            guard let self = self else {
                CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
                return
            }
            self.processFrame(pixelBuffer)
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        
        if shouldFinish() {
            forceFinish()
        }
    }

    func forceFinish() {
        guard !isFinishing else { return }
        isFinishing = true
        
        processingQueue.async { [weak self] in
            self?.finalizeCapture()
        }
    }

    private func processFrame(_ pixelBuffer: CVPixelBuffer) {
        let inputImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        guard let reference = referencePixelBuffer else {
            // First frame is our reference
            // Create a copy of the pixel buffer to keep as reference
            // Note: We use a deep copy helper to handle planar buffers correctly.
            if let copy = deepCopy(pixelBuffer) {
                self.referencePixelBuffer = copy
            } else {
                // If copy fails, we can't use alignment, but we should still capture the first frame!
                // We just won't have a reference for future alignment (so future frames might be skipped or unaligned).
                // Actually, if we can't copy, we can't use Vision on a stable buffer.
                // But we can still accumulate this frame.
                print("Warning: Failed to copy reference buffer. Alignment will be disabled.")
            }
            
            // Initial weight for the reference frame
            let sharpness = self.calculateSharpness(of: inputImage)
            let weight = pow(Double(sharpness), 2.0) // Square for stronger differentiation
            
            // Accumulate weighted reference
            let weightedImage = inputImage.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: CGFloat(weight), y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: CGFloat(weight), z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(weight), w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(weight))
            ])
            
            self.accumulator = weightedImage
            self.totalWeight = weight
            self.frameCount = 1
            return
        }
        
        // Align current frame to reference
        // If we have no reference (copy failed previously), we skip alignment and just accumulate (or skip to avoid ghosting?)
        // If we skip alignment, we get ghosting. But better than no image?
        // Let's try to align if we have a reference.
        
        var imageToAccumulate = inputImage
        
        if let alignedImage = align(image: inputImage, to: reference) {
            imageToAccumulate = alignedImage
        } else {
            // Alignment failed.
            // If it failed because of large movement, we should SKIP the frame.
            // If it failed because we have no reference, we might want to accumulate anyway?
            // For now, let's skip to be safe and avoid blurry mess.
            return
        }
        
        // Calculate Sharpness Weight
        let sharpness = calculateSharpness(of: imageToAccumulate)
        let weight = pow(Double(sharpness), 2.0)
        
        // Accumulate Weighted
        if let existing = accumulator {
            let weightedImage = imageToAccumulate.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: CGFloat(weight), y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: CGFloat(weight), z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(weight), w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(weight))
            ])
            
            self.accumulator = existing.applyingFilter("CIAdditionCompositing", parameters: [
                kCIInputBackgroundImageKey: weightedImage
            ])
            self.totalWeight += weight
            self.frameCount += 1
        }
    }
    
    private func deepCopy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        var copy: CVPixelBuffer?
        let attachments: CFDictionary?
        if #available(iOS 15.0, *) {
            attachments = CVBufferCopyAttachments(source, .shouldPropagate)
        } else {
            attachments = CVBufferGetAttachments(source, .shouldPropagate)
        }
        
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let format = CVPixelBufferGetPixelFormatType(source)
        
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attachments, &copy)
        guard status == kCVReturnSuccess, let destination = copy else { return nil }
        
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(destination, [])
        }
        
        if CVPixelBufferIsPlanar(source) {
            let planeCount = CVPixelBufferGetPlaneCount(source)
            for plane in 0..<planeCount {
                guard let srcAddress = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let dstAddress = CVPixelBufferGetBaseAddressOfPlane(destination, plane) else { continue }
                
                let height = CVPixelBufferGetHeightOfPlane(source, plane)
                let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                // Note: Destination might have different padding, so we copy row by row or use the min bytesPerRow
                let dstBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
                let copyBytes = min(bytesPerRow, dstBytesPerRow)
                
                for row in 0..<height {
                    let srcPtr = srcAddress.advanced(by: row * bytesPerRow)
                    let dstPtr = dstAddress.advanced(by: row * dstBytesPerRow)
                    memcpy(dstPtr, srcPtr, copyBytes)
                }
            }
        } else {
            guard let srcAddress = CVPixelBufferGetBaseAddress(source),
                  let dstAddress = CVPixelBufferGetBaseAddress(destination) else { return nil }
            
            let height = CVPixelBufferGetHeight(source)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(source)
            let dstBytesPerRow = CVPixelBufferGetBytesPerRow(destination)
            let copyBytes = min(bytesPerRow, dstBytesPerRow)
            
            for row in 0..<height {
                let srcPtr = srcAddress.advanced(by: row * bytesPerRow)
                let dstPtr = dstAddress.advanced(by: row * dstBytesPerRow)
                memcpy(dstPtr, srcPtr, copyBytes)
            }
        }
        
        return destination
    }
            self.frameCount += 1
        }
    }
    
    private func calculateSharpness(of image: CIImage) -> Float {
        // Use the "Edges" filter to find high frequency components
        let edges = image.applyingFilter("CIEdges", parameters: [
            kCIInputIntensityKey: 2.0
        ])
        
        // Average the edge energy
        let extent = image.extent
        let vec = CIVector(x: extent.origin.x, y: extent.origin.y, z: extent.size.width, w: extent.size.height)
        let average = edges.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: vec])
        
        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(average, toBitmap: &bitmap, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        
        // Luma of the edges
        let sharpness = (Double(bitmap[0]) + Double(bitmap[1]) + Double(bitmap[2])) / 3.0 / 255.0
        return Float(sharpness)
    }
    
    private func align(image: CIImage, to reference: CVPixelBuffer) -> CIImage? {
        let request = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: reference)
        // Use Homographic for better alignment (handles rotation/perspective)
        // let request = VNHomographicImageRegistrationRequest(targetedCVPixelBuffer: reference) 
        // Note: Homographic is slower and can fail more often on low texture. 
        // For night mode, Translational is often safer, but let's try to upgrade to Homographic if we want "Pro" results.
        // However, VNHomographicImageRegistrationRequest is often too unstable for dark noisy images.
        // Let's stick to Translational but add a check for quality.
        
        do {
            try sequenceRequestHandler.perform([request], on: image)
            
            guard let observation = request.results?.first as? VNImageTranslationAlignmentObservation else {
                return nil
            }
            
            let transform = observation.alignmentTransform
            // Reject large movements (hand shake vs intentional panning)
            let distance = hypot(transform.tx, transform.ty)
            if distance > 100 { // Increased threshold slightly
                return nil
            }
            
            return image.transformed(by: transform)
        } catch {
            return nil
        }
    }

    private func finalizeCapture() {
        guard let finalAccumulator = accumulator, frameCount > 0, totalWeight > 0 else {
            completion(.failure(.captureFailed("No frames captured")))
            return
        }
        
        // 1. Normalize (Weighted Average)
        // Divide the accumulated sum by the total weight
        let divisor = CGFloat(totalWeight)
        let averaged = finalAccumulator.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1.0/divisor, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1.0/divisor, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1.0/divisor, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1) // Alpha is usually 1.0, but we weighted it too.
        ])
        
        // 2. Crop to valid area
        var cropped = averaged
        if let ref = referencePixelBuffer {
            let width = CVPixelBufferGetWidth(ref)
            let height = CVPixelBufferGetHeight(ref)
            cropped = averaged.cropped(to: CGRect(x: 0, y: 0, width: Int(width), height: Int(height)))
        }
        
        // 3. "Pro" Post-Processing Pipeline
        
        // A. Noise Reduction (Chroma first)
        // Reduce color noise which is common in night shots
        // We assume the stacking handled most luma noise.
        let noiseLevel = Double(settings.noiseReductionLevel) * 0.05
        var processed = cropped.applyingFilter("CINoiseReduction", parameters: [
            "inputNoiseLevel": noiseLevel,
            "inputSharpness": 0.4
        ])
        
        // B. Low Light Enhancement (MSR)
        // Replaces manual exposure/tone mapping with Multi-Scale Retinex
        if #available(iOS 15.0, *) {
            let enhancer = LowLightEnhancer()
            enhancer.gain = settings.msrGain
            enhancer.offset = settings.msrOffset
            enhancer.saturation = settings.msrSaturation
            
            if let enhanced = enhancer.enhance(image: processed) {
                processed = enhanced
            }
        } else {
            // Fallback logic (should not be reached on iOS 17+)
            // B. Auto-Exposure / Normalization
            let extent = processed.extent
            let vec = CIVector(x: extent.origin.x, y: extent.origin.y, z: extent.size.width, w: extent.size.height)
            let areaAvg = processed.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: vec])
            
            var bitmap = [UInt8](repeating: 0, count: 4)
            context.render(areaAvg, toBitmap: &bitmap, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
            
            let avgLuma = (Double(bitmap[0]) * 0.2126 + Double(bitmap[1]) * 0.7152 + Double(bitmap[2]) * 0.0722) / 255.0
            let biasScale = pow(2.0, Double(settings.exposureBias))
            let targetLuma = 0.20 * biasScale
            
            if avgLuma < targetLuma && avgLuma > 0.0001 {
                let boost = targetLuma / avgLuma
                let safeBoost = min(4.0, boost)
                processed = processed.applyingFilter("CIExposureAdjust", parameters: [
                    kCIInputEVKey: log2(safeBoost)
                ])
            }
            
            // C. Local Tone Mapping
            processed = processed.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1.0,
                "inputShadowAmount": 0.5
            ])
            
            // D. Color Grading
            processed = processed.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: settings.colorSaturation
            ])
        }
        
        // E. Sharpening (Unsharp Mask equivalent)
        processed = processed.applyingFilter("CISharpenLuminance", parameters: [
            "inputSharpness": 0.5
        ])

        // 4. Render
        guard let data = render(image: processed) else {
            completion(.failure(.captureFailed("Rendering failed")))
            return
        }
        
        completion(.success(data))
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
        let heicUTI = AVFileType.heic.rawValue as CFString
        let jpegUTI = AVFileType.jpg.rawValue as CFString
        
        guard let destination = CGImageDestinationCreateWithData(data, heicUTI, 1, nil) ?? 
                                CGImageDestinationCreateWithData(data, jpegUTI, 1, nil) else {
            return nil
        }
        
        let options = [kCGImageDestinationLossyCompressionQuality as String: 0.95] as CFDictionary
        CGImageDestinationAddImage(destination, cgImage, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
#endif

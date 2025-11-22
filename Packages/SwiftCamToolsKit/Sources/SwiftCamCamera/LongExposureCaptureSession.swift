#if canImport(AVFoundation) && canImport(CoreImage) && canImport(Vision)
import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import ImageIO
import Vision
import SwiftCamCore

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
            var copy: CVPixelBuffer?
            let attachments: CFDictionary?
            if #available(iOS 15.0, *) {
                attachments = CVBufferCopyAttachments(pixelBuffer, .shouldPropagate)
            } else {
                attachments = CVBufferGetAttachments(pixelBuffer, .shouldPropagate)
            }
            CVPixelBufferCreate(kCFAllocatorDefault,
                              CVPixelBufferGetWidth(pixelBuffer),
                              CVPixelBufferGetHeight(pixelBuffer),
                              CVPixelBufferGetPixelFormatType(pixelBuffer),
                              attachments,
                              &copy)
            
            if let copy = copy {
                CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
                CVPixelBufferLockBaseAddress(copy, [])
                let src = CVPixelBufferGetBaseAddress(pixelBuffer)
                let dst = CVPixelBufferGetBaseAddress(copy)
                let size = CVPixelBufferGetDataSize(pixelBuffer)
                memcpy(dst, src, size)
                CVPixelBufferUnlockBaseAddress(copy, [])
                CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
                
                self.referencePixelBuffer = copy
                self.accumulator = inputImage
                self.frameCount = 1
            }
            return
        }
        
        // Align current frame to reference
        guard let alignedImage = align(image: inputImage, to: reference) else {
            // If alignment fails, skip this frame to avoid ghosting
            return
        }
        
        // Accumulate
        if let existing = accumulator {
            self.accumulator = existing.applyingFilter("CIAdditionCompositing", parameters: [
                kCIInputBackgroundImageKey: alignedImage
            ])
            self.frameCount += 1
        }
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
        guard let finalAccumulator = accumulator, frameCount > 0 else {
            completion(.failure(.captureFailed("No frames captured")))
            return
        }
        
        // 1. Average (Mean Stacking)
        // This reduces random noise by sqrt(N)
        let divisor = CGFloat(frameCount)
        let averaged = finalAccumulator.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1.0/divisor, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1.0/divisor, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1.0/divisor, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
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
        var processed = cropped.applyingFilter("CINoiseReduction", parameters: [
            "inputNoiseLevel": 0.03,
            "inputSharpness": 0.4
        ])
        
        // B. Auto-Exposure / Normalization
        // We analyze the image to see if it's too dark (common if we protected highlights)
        let extent = processed.extent
        let vec = CIVector(x: extent.origin.x, y: extent.origin.y, z: extent.size.width, w: extent.size.height)
        let areaAvg = processed.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: vec])
        
        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(areaAvg, toBitmap: &bitmap, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        
        let avgLuma = (Double(bitmap[0]) * 0.2126 + Double(bitmap[1]) * 0.7152 + Double(bitmap[2]) * 0.0722) / 255.0
        
        // Target a "night" exposure (not too bright, e.g., 0.18 - 0.25 middle gray)
        // If it's very dark (e.g. 0.05), boost it.
        let targetLuma = 0.20
        if avgLuma > 0.01 && avgLuma < targetLuma {
            let boost = targetLuma / avgLuma
            // Cap the boost to avoid noise explosion (e.g. max 3x)
            let safeBoost = min(3.0, boost)
            processed = processed.applyingFilter("CIExposureAdjust", parameters: [
                kCIInputEVKey: log2(safeBoost)
            ])
        }
        
        // C. Local Tone Mapping (Shadow/Highlight)
        // Stronger recovery for night mode
        processed = processed.applyingFilter("CIHighlightShadowAdjust", parameters: [
            "inputHighlightAmount": 1.0, // Recover blown streetlights
            "inputShadowAmount": 0.5     // Lift deep shadows
        ])
        
        // D. Color Grading
        // Night shots often look too yellow/orange (sodium lights). 
        // A slight cooling filter or just vibrance can help.
        processed = processed.applyingFilter("CIVibrance", parameters: [
            "inputAmount": 0.1 // Subtle vibrance
        ])
        
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

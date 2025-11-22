import CoreImage
import UIKit

/// A class that provides high-performance low-light image enhancement using Multi-Scale Retinex (MSR).
/// This implementation uses Core Image with a custom Metal kernel for GPU acceleration.
@available(iOS 15.0, *)
public class LowLightEnhancer {
    
    private var kernel: CIColorKernel?
    
    // MARK: - Configuration
    
    /// Scales for the Gaussian blurs (Multi-Scale).
    /// These represent the standard deviation (sigma) for the Gaussian blur.
    public var sigmas: [Double] = [15.0, 80.0, 250.0]
    
    /// Gain factor for the Retinex algorithm. Controls the contrast enhancement.
    public var gain: Float = 12.0
    
    /// Offset factor for the Retinex algorithm. Controls the base brightness.
    public var offset: Float = 0.0
    
    /// Color saturation adjustment. 1.0 is default.
    public var saturation: Float = 1.2
    
    // MARK: - Metal Kernel Source
    
    /// The Metal Shading Language source code for the MSR kernel.
    private static let kernelSource = """
    #include <CoreImage/CoreImage.h>
    
    extern "C" float4 msr_luminance(coreimage::sample_t s0, coreimage::sample_t s1, coreimage::sample_t s2, coreimage::sample_t s3, float gain, float offset, float saturation) {
        float3 rgb = s0.rgb;
        float3 blur1 = s1.rgb;
        float3 blur2 = s2.rgb;
        float3 blur3 = s3.rgb;
        
        // Luminance coefficients (Rec. 709)
        float3 lumCoeff = float3(0.2126, 0.7152, 0.0722);
        
        float Y = dot(rgb, lumCoeff);
        float Y1 = dot(blur1, lumCoeff);
        float Y2 = dot(blur2, lumCoeff);
        float Y3 = dot(blur3, lumCoeff);
        
        // Avoid log(0)
        float epsilon = 0.001;
        
        // Multi-Scale Retinex in Log Domain
        // MSR = log(Y) - 1/3 * (log(Y1) + log(Y2) + log(Y3))
        float logY = log(Y + epsilon);
        float logY1 = log(Y1 + epsilon);
        float logY2 = log(Y2 + epsilon);
        float logY3 = log(Y3 + epsilon);
        
        float msr = logY - (logY1 + logY2 + logY3) / 3.0;
        
        // Apply Gain and Offset
        float Y_new = (msr * gain) + offset;
        
        // Normalize to [0, 1] roughly? 
        // Retinex output is arbitrary. We clamp it.
        // Usually we want to map the result back to a visible range.
        // A simple approach is to treat Y_new as the new luminance directly (if offset is handled well).
        // Or we can use a sigmoid or simple clamp.
        
        Y_new = clamp(Y_new, 0.0, 1.0);
        
        // Color Restoration / Preservation
        // NewRGB = OldRGB * (NewY / OldY)
        float scale = Y_new / (Y + epsilon);
        
        float3 newRGB = rgb * scale;
        
        // Simple Saturation Adjustment
        // Interpolate between Luminance (Grayscale) and NewRGB
        float3 gray = float3(Y_new);
        newRGB = mix(gray, newRGB, saturation);
        
        return float4(newRGB, s0.a);
    }
    """
    
    // MARK: - Initialization
    
    public init() {
        do {
            let kernels = try CIKernel.kernels(withMetalString: Self.kernelSource)
            if let firstKernel = kernels.first as? CIColorKernel {
                self.kernel = firstKernel
            }
        } catch {
            print("Failed to compile MSR kernel: \(error)")
        }
    }
    
    // MARK: - Processing
    
    /// Enhances a UIImage for low-light conditions.
    /// - Parameter image: The input UIImage.
    /// - Returns: The enhanced UIImage.
    public func enhance(image: UIImage) -> UIImage? {
        guard let ciImage = CIImage(image: image) else { return nil }
        guard let outputCIImage = enhance(image: ciImage) else { return nil }
        
        let context = CIContext()
        if let cgImage = context.createCGImage(outputCIImage, from: outputCIImage.extent) {
            return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
        }
        return nil
    }
    
    /// Enhances a CIImage for low-light conditions using Multi-Scale Retinex.
    /// - Parameter image: The input CIImage.
    /// - Returns: The enhanced CIImage.
    public func enhance(image: CIImage) -> CIImage? {
        guard let kernel = self.kernel else { return image }
        
        // 1. Create Blurred Versions (Multi-Scale)
        let blur1 = image.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: sigmas[0]])
        let blur2 = image.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: sigmas[1]])
        let blur3 = image.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: sigmas[2]])
        
        // 2. Apply MSR Kernel
        // The kernel takes: Original, Blur1, Blur2, Blur3, Gain, Offset, Saturation
        let args: [Any] = [
            image,
            blur1,
            blur2,
            blur3,
            gain,
            offset,
            saturation
        ]
        
        return kernel.apply(extent: image.extent, arguments: args)
    }
}

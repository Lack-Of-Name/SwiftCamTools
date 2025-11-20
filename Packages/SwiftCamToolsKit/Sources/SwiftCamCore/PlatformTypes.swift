#if canImport(CoreVideo)
import CoreVideo
#if compiler(>=5.9)
extension CVPixelBuffer: @unchecked Sendable {}
#endif
#else
public typealias CVPixelBuffer = AnyObject

public enum CVPixelBufferLockFlags {
    case readOnly
}

@inline(__always) public func CVPixelBufferLockBaseAddress(_ buffer: CVPixelBuffer, _ flags: CVPixelBufferLockFlags) {}
@inline(__always) public func CVPixelBufferUnlockBaseAddress(_ buffer: CVPixelBuffer, _ flags: CVPixelBufferLockFlags) {}
@inline(__always) public func CVPixelBufferGetWidth(_ buffer: CVPixelBuffer) -> Int { 0 }
@inline(__always) public func CVPixelBufferGetHeight(_ buffer: CVPixelBuffer) -> Int { 0 }
@inline(__always) public func CVPixelBufferGetBaseAddress(_ buffer: CVPixelBuffer) -> UnsafeMutableRawPointer? { nil }
#endif

#if !canImport(AVFoundation)
public struct AVCapturePhoto {
    public init() {}
}

public class AVCaptureSession {
    public init() {}
}
#endif

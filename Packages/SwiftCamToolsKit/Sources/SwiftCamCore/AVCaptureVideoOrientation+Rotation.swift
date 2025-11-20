#if canImport(AVFoundation)
import AVFoundation

public extension AVCaptureVideoOrientation {
    var rotationAngle: Double {
        switch self {
        case .portrait: return 90
        case .portraitUpsideDown: return 270
        case .landscapeRight: return 180
        case .landscapeLeft: return 0
        @unknown default:
            return 90
        }
    }
}
#endif

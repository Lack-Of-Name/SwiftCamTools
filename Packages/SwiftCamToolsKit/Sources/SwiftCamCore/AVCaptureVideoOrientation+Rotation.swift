#if canImport(Foundation)
import Foundation
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

public enum CameraOrientation: String, Codable, CaseIterable, Equatable {
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight

    public var rotationAngle: Double {
        switch self {
        case .portrait: return 90
        case .portraitUpsideDown: return 270
        case .landscapeRight: return 180
        case .landscapeLeft: return 0
        }
    }

    #if canImport(AVFoundation)
    @available(iOS, introduced: 10.0, deprecated: 17.0, message: "Use rotationAngle with AVCaptureDeviceRotationCoordinator")
    public var legacyAVOrientation: AVCaptureVideoOrientation {
        switch self {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        }
    }
    #endif
}

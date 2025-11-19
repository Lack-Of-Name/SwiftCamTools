import Foundation

public enum CameraError: Error, Equatable {
    case authorizationDenied
    case configurationFailed(String)
    case captureFailed(String)
    case pipelineBusy
    case unknown
}

extension CameraError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            return "Camera access is required. Enable it in Settings."
        case .configurationFailed(let reason):
            return "Camera configuration failed: \(reason)"
        case .captureFailed(let reason):
            return "Capture failed: \(reason)"
        case .pipelineBusy:
            return "Capture pipeline is busy. Please try again."
        case .unknown:
            return "An unknown camera error occurred."
        }
    }
}

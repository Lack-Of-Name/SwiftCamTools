import Foundation

public enum CaptureMode: String, CaseIterable, Codable {
    case auto
    case longExposure
    case bracketed
    case raw

    public var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .longExposure: return "Long"
        case .bracketed: return "Bracket"
        case .raw: return "RAW"
        }
    }

    public var maxFrameCount: Int {
        switch self {
        case .auto: return 1
        case .longExposure: return 1
        case .bracketed: return 5
        case .raw: return 3
        }
    }
}

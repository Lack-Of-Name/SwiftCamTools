import Foundation

enum CaptureCountdown: CaseIterable {
    case off
    case three
    case five
    case ten

    var seconds: Int {
        switch self {
        case .off: return 0
        case .three: return 3
        case .five: return 5
        case .ten: return 10
        }
    }

    var iconName: String {
        switch self {
        case .off: return "clock"
        case .three: return "3.circle"
        case .five: return "5.circle"
        case .ten: return "10.circle"
        }
    }

    var displayLabel: String {
        switch self {
        case .off: return "Timer Off"
        case .three: return "3s Timer"
        case .five: return "5s Timer"
        case .ten: return "10s Timer"
        }
    }

    func next() -> CaptureCountdown {
        switch self {
        case .off: return .three
        case .three: return .five
        case .five: return .ten
        case .ten: return .off
        }
    }
}

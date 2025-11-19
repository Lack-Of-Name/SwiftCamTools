import SwiftUI

struct CameraTopBar: View {
    @ObservedObject var viewModel: CameraViewModel
    @State private var flashEnabled = false
    @State private var timerMode: TimerMode = .off

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 20) {
                TopBarButton(symbol: flashEnabled ? "bolt.fill" : "bolt.slash") {
                    flashEnabled.toggle()
                }

                TopBarButton(symbol: timerMode.icon) {
                    timerMode = timerMode.next()
                }

                Spacer()

                TopBarButton(symbol: viewModel.showGridOverlay ? "square.grid.3x3" : "square") {
                    viewModel.showGridOverlay.toggle()
                }
            }

            HistogramView(histogram: viewModel.histogram)
                .frame(height: 60)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
    }
}

private struct TopBarButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.black.opacity(0.35), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

private enum TimerMode: String, CaseIterable {
    case off
    case three
    case ten

    var icon: String {
        switch self {
        case .off: return "clock"
        case .three: return "clock.badge.exclamationmark"
        case .ten: return "clock.fill"
        }
    }

    func next() -> TimerMode {
        switch self {
        case .off: return .three
        case .three: return .ten
        case .ten: return .off
        }
    }
}
``
#if canImport(SwiftUI)
import SwiftUI

struct CameraTopBar: View {
    @ObservedObject var viewModel: CameraViewModel
    @State private var flashEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 20) {
                TopBarButton(symbol: flashEnabled ? "bolt.fill" : "bolt.slash") {
                    flashEnabled.toggle()
                }

                TopBarButton(symbol: viewModel.countdownMode.iconName) {
                    guard viewModel.mode == .longExposure else { return }
                    viewModel.cycleCountdownMode()
                }
                .opacity(viewModel.mode == .longExposure ? 1 : 0.35)
                .disabled(viewModel.mode != .longExposure)

                Spacer()

                TopBarButton(symbol: viewModel.showGridOverlay ? "square.grid.3x3" : "square") {
                    viewModel.showGridOverlay.toggle()
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                if viewModel.isPerformanceConstrained {
                    Label {
                        Text("Stabilizing preview…")
                    } icon: {
                        Image(systemName: "tortoise.fill")
                    }
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.25), in: Capsule())
                    .foregroundStyle(.white)
                }

                if let exposureWarning = viewModel.exposureWarning {
                    Label {
                        Text(exposureWarning)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.3), in: Capsule())
                    .foregroundStyle(.white)
                }

                HistogramView(histogram: viewModel.histogram)
                    .frame(height: 60)
            }
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
#endif
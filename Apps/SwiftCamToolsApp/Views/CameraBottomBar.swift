#if canImport(SwiftUI)
import SwiftUI
import SwiftCamCore

struct CameraBottomBar: View {
    @ObservedObject var viewModel: CameraViewModel
    var captureAction: () -> Void
    var controlsAction: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ModeSelector(selectedMode: $viewModel.mode)

            HStack(alignment: .center) {
                BottomCircleButton(symbol: "photo.on.rectangle.angled") {}

                Spacer()

                ShutterButton(action: captureAction)

                Spacer()

                BottomCircleButton(symbol: "slider.horizontal.3") {
                    controlsAction()
                }
            }
            .frame(height: 72)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }
}
#endif

private struct ModeSelector: View {
    @Binding var selectedMode: CaptureMode

    var body: some View {
        HStack(spacing: 16) {
            ForEach(CaptureMode.allCases, id: \.self) { mode in
                Button(action: { withAnimation(.easeInOut(duration: 0.15)) { selectedMode = mode } }) {
                    Text(mode.displayName.uppercased())
                        .font(.system(size: 14, weight: mode == selectedMode ? .semibold : .regular, design: .rounded))
                        .foregroundStyle(mode == selectedMode ? .white : .gray)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct ShutterButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 84, height: 84)
                Circle()
                    .fill(Color.white)
                    .frame(width: 72, height: 72)
            }
            .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 3))
            .shadow(color: Color.white.opacity(0.35), radius: 6, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }
}

private struct BottomCircleButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.black.opacity(0.35), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

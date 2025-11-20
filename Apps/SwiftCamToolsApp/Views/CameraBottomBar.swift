#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct CameraBottomBar: View {
    @ObservedObject var viewModel: CameraViewModel
    var captureAction: () -> Void
    var controlsAction: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center) {
                RecentPhotoButton(image: viewModel.lastCapturedPreview, action: viewModel.openMostRecentPhoto)

                Spacer()

                ShutterButton(
                    action: captureAction,
                    isCapturing: viewModel.isCapturing,
                    isCountdownActive: viewModel.countdownSecondsRemaining != nil
                )

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

private struct ShutterButton: View {
    var action: () -> Void
    var isCapturing: Bool
    var isCountdownActive: Bool

    var body: some View {
        Button(action: {
            guard !isCapturing, !isCountdownActive else { return }
            action()
        }) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 90, height: 90)

                Circle()
                    .fill(Color.white)
                    .frame(width: isCapturing ? 48 : 72, height: isCapturing ? 48 : 72)
                    .animation(.easeInOut(duration: 0.15), value: isCapturing)

                if isCapturing {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .red))
                        .scaleEffect(1.2)
                } else if isCountdownActive {
                    Image(systemName: "timer")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.black.opacity(0.8))
                }
            }
            .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 3))
            .shadow(color: Color.white.opacity(0.35), radius: 6, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isCapturing ? "Capturing photo" : (isCountdownActive ? "Countdown running" : "Shutter")
        )
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

#if canImport(UIKit)
private struct RecentPhotoButton: View {
    let image: UIImage?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo.on.rectangle")
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 52, height: 52)
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open recent photos")
    }
}
#else
private struct RecentPhotoButton: View {
    let image: Any?
    let action: () -> Void

    var body: some View {
        BottomCircleButton(symbol: "photo.on.rectangle.angled", action: action)
    }
}
#endif

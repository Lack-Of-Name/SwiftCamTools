#if canImport(SwiftUI)
import SwiftUI

enum CameraControlKind: String, CaseIterable, Identifiable {
    case iso
    case shutter
    case noise
    case aperture
    case bias

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .iso: return "circle.lefthalf.filled"
        case .shutter: return "timer"
        case .noise: return "waveform"
        case .aperture: return "camera.aperture"
        case .bias: return "plusminus.circle"
        }
    }

    var title: String {
        switch self {
        case .iso: return "ISO"
        case .shutter: return "Shutter"
        case .noise: return "Noise"
        case .aperture: return "F-Stop"
        case .bias: return "Exposure"
        }
    }

    var isAvailable: Bool {
        true
    }
}

struct CameraControlsPanel: View {
    @ObservedObject var viewModel: CameraViewModel
    var onControlSelected: (CameraControlKind) -> Void

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(spacing: 16) {
            Capsule()
                .frame(width: 48, height: 4)
                .foregroundStyle(.white.opacity(0.35))

            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(CameraControlKind.allCases) { control in
                    ControlTile(control: control, subtitle: subtitle(for: control)) {
                        if control.isAvailable {
                            onControlSelected(control)
                        }
                    }
                    .overlay(
                        Group {
                            if !control.isAvailable {
                                Text("Soon")
                                    .font(.caption2.weight(.semibold))
                                    .padding(6)
                                    .background(Color.orange.opacity(0.85), in: Capsule())
                                    .foregroundStyle(.white)
                            }
                        }, alignment: .topTrailing
                    )
                    .opacity(control.isAvailable ? 1.0 : 0.4)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .padding(.horizontal, 24)
    }

    private func subtitle(for control: CameraControlKind) -> String {
        switch control {
        case .iso:
            if viewModel.isAutoISOEnabled {
                return "AUTO"
            }
            return "ISO " + Int(viewModel.isoValue).formatted()
        case .shutter:
            return String(format: "%.2fs", viewModel.shutterSeconds)
        case .noise:
            return String(format: "%d%%", Int(viewModel.noiseReduction * 100))
        case .aperture:
            let aperture = viewModel.apertureValue
            return String(format: "f/%.1f", aperture)
        case .bias:
            return String(format: "%+.1f EV", viewModel.exposureBiasValue)
        }
    }
}

private struct ControlTile: View {
    let control: CameraControlKind
    let subtitle: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: control.icon)
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 48, height: 48)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(.white)

                VStack(spacing: 2) {
                    Text(control.title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
#endif

#if canImport(SwiftUI)
import SwiftUI

enum CameraControlKind: String, CaseIterable, Identifiable {
    case iso
    case shutter
    case aperture
    case bias
    case saturation
    case focus

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .iso: return "circle.lefthalf.filled"
        case .shutter: return "timer"
        case .aperture: return "camera.aperture"
        case .bias: return "plusminus.circle"
        case .saturation: return "drop.halffull"
        case .focus: return "viewfinder.circle"
        }
    }

    var title: String {
        switch self {
        case .iso: return "ISO"
        case .shutter: return "Shutter"
        case .aperture: return "F-Stop"
        case .bias: return "Exposure"
        case .saturation: return "Saturation"
        case .focus: return "Focus"
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
            return Self.shutterDisplayText(viewModel.shutterSeconds)
        case .aperture:
            let aperture = viewModel.apertureValue
            return String(format: "f/%.1f", aperture)
        case .bias:
            return String(format: "%+.1f EV", viewModel.exposureBiasValue)
        case .saturation:
            return String(format: "%d%%", Int(viewModel.saturationValue * 100))
        case .focus:
            return viewModel.isAutofocusEnabled ? "AUTO" : "LOCK"
        }
    }
}

private extension CameraControlKind {
    static func shutterDisplayText(_ seconds: Double) -> String {
        if seconds >= 1 {
            if seconds.truncatingRemainder(dividingBy: 1) == 0 {
                return String(format: "%.0fs", seconds)
            }
            return String(format: "%.1fs", seconds)
        }
        let denominator = max(1, Int(round(1.0 / seconds)))
        return "1/\(denominator)s"
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

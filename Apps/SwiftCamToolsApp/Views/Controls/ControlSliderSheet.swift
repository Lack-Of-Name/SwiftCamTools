#if canImport(SwiftUI)
import SwiftUI

struct ControlSliderSheet: View {
    @ObservedObject var viewModel: CameraViewModel
    let control: CameraControlKind

    var body: some View {
        VStack(spacing: 20) {
            Capsule()
                .frame(width: 40, height: 4)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text(control.title.uppercased())
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(subtitle)
                    .font(.title3.bold())
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            sliderBody
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 32)
        .background(.regularMaterial)
    }

    private var sliderBody: some View {
        switch control {
        case .iso:
            return AnyView(
                VStack(spacing: 20) {
                    Toggle(isOn: Binding(get: { viewModel.isAutoISOEnabled }, set: { viewModel.setAutoISO($0) })) {
                        HStack {
                            Text("Auto ISO")
                                .font(.headline)
                            Spacer()
                            if viewModel.isAutoISOEnabled {
                                Text("LOCKED")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.blue.opacity(0.2), in: Capsule())
                            }
                        }
                    }
                    .toggleStyle(SwitchToggleStyle(tint: .blue))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: viewModel.isAutoISOEnabled)

                    ControlValueSlider(
                        value: Binding(get: { viewModel.isoValue }, set: { viewModel.updateISO($0) }),
                        range: 100...6400,
                        formatter: { "ISO " + Int($0).formatted() },
                        isDisabled: viewModel.isAutoISOEnabled
                    )
                }
            )
        case .shutter:
            return AnyView(
                ControlValueSlider(
                    value: Binding(get: { viewModel.shutterSeconds }, set: { viewModel.updateShutter(seconds: $0) }),
                    range: 0.125...60,
                    formatter: { String(format: "%.2fs", $0) }
                )
            )
        case .noise:
            return AnyView(
                ControlValueSlider(
                    value: Binding(get: { viewModel.noiseReduction }, set: { viewModel.updateNoiseReduction($0) }),
                    range: 0...1,
                    formatter: { String(format: "%d%%", Int($0 * 100)) }
                )
            )
        case .aperture:
            return AnyView(
                VStack(spacing: 12) {
                    Text("Aperture control is coming soon.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    ProgressView()
                }
            )
        }
    }

    private var subtitle: String {
        switch control {
        case .iso:
            return "Manual ISO"
        case .shutter:
            return "Shutter Duration"
        case .noise:
            return "Noise Mix"
        case .aperture:
            return "Planned Update"
        }
    }
}

private struct ControlValueSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let formatter: (Double) -> String
    var isDisabled: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(formatter(value))
                    .font(.title2.monospacedDigit())
                    .foregroundStyle(.primary)
                Spacer()
            }

            Slider(value: $value, in: range)
                .tint(.primary)
                .disabled(isDisabled)
                .overlay {
                    Group {
                        if isDisabled {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.black.opacity(0.25))
                                .overlay(
                                    Image(systemName: "lock.fill")
                                        .font(.caption)
                                        .foregroundStyle(.white)
                                )
                        }
                    }
                }
        }
    }
}
#endif

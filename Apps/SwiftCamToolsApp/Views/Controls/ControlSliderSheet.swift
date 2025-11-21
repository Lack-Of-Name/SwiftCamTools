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
                PresetValueSlider(
                    value: Binding(get: { viewModel.shutterSeconds }, set: { viewModel.updateShutter(seconds: $0) }),
                    presets: viewModel.shutterPresets,
                    formatter: { ControlSliderSheet.shutterDisplayText($0) }
                )
            )
        case .aperture:
            return AnyView(
                VStack(spacing: 20) {
                    Toggle(isOn: Binding(get: { viewModel.isAutoApertureEnabled }, set: { viewModel.setAutoApertureEnabled($0) })) {
                        HStack {
                            Text("Auto F-Stop")
                                .font(.headline)
                            Spacer()
                            if viewModel.isAutoApertureEnabled {
                                Text("AUTO")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.blue.opacity(0.2), in: Capsule())
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                    .toggleStyle(SwitchToggleStyle(tint: .blue))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: viewModel.isAutoApertureEnabled)

                    ControlValueSlider(
                        value: Binding(get: { viewModel.apertureValue }, set: { viewModel.updateAperture($0) }),
                        range: 1.4...8.0,
                        formatter: { String(format: "f/%.1f", $0) },
                        isDisabled: viewModel.isAutoApertureEnabled,
                        step: 0.1
                    )
                }
            )
        case .bias:
            return AnyView(
                ControlValueSlider(
                    value: Binding(get: { viewModel.exposureBiasValue }, set: { viewModel.updateExposureBias($0) }),
                    range: -2.0...2.0,
                    formatter: { String(format: "%+.1f EV", $0) },
                    step: 0.1,
                    tint: .orange
                )
            )
        case .saturation:
            return AnyView(
                ControlValueSlider(
                    value: Binding(get: { viewModel.saturationValue }, set: { viewModel.updateSaturation($0) }),
                    range: 0.8...1.4,
                    formatter: { String(format: "%d%%", Int($0 * 100)) },
                    step: 0.02,
                    tint: .purple
                )
            )
        case .focus:
            return AnyView(
                VStack(alignment: .leading, spacing: 16) {
                    Toggle(isOn: Binding(get: { viewModel.isAutofocusEnabled }, set: { viewModel.setAutofocusEnabled($0) })) {
                        Text("Auto Focus")
                            .font(.headline)
                    }
                    .toggleStyle(SwitchToggleStyle(tint: .blue))

                    Text(viewModel.isAutofocusEnabled ? "Camera tracks focus continuously." : "Focus locked near infinity to reduce breathing during long exposures.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
        case .aperture:
            return "Virtual Aperture"
        case .bias:
            return "Exposure Bias"
        case .saturation:
            return "Color Boost"
        case .focus:
            return "Focus Assist"
        }
    }
}

private struct ControlValueSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let formatter: (Double) -> String
    var isDisabled: Bool = false
    var step: Double?
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(formatter(value))
                    .font(.title2.monospacedDigit())
                    .foregroundStyle(.primary)
                Spacer()
            }

            slider
                .tint(tint)
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

    @ViewBuilder
    private var slider: some View {
        if let step {
            Slider(value: $value, in: range, step: step)
        } else {
            Slider(value: $value, in: range)
        }
    }
}

private struct PresetValueSlider: View {
    @Binding var value: Double
    let presets: [Double]
    let formatter: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(formatter(displayValue))
                    .font(.title2.monospacedDigit())
                    .foregroundStyle(.primary)
                Spacer()
            }

            Slider(
                value: Binding(
                    get: { sliderPosition },
                    set: { newValue in
                        let index = nearestIndex(for: newValue)
                        value = presets[index]
                    }
                ),
                in: sliderRange,
                step: 1
            )
            .tint(.primary)

            HStack(spacing: 0) {
                ForEach(presets.indices, id: \.self) { index in
                    Circle()
                        .fill(index == nearestIndex ? Color.white : Color.white.opacity(0.35))
                        .frame(width: index == nearestIndex ? 8 : 6, height: index == nearestIndex ? 8 : 6)
                    if index != presets.count - 1 {
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(height: 12)
        }
    }

    private var safePresets: [Double] { presets.isEmpty ? [value] : presets }

    private var sliderRange: ClosedRange<Double> {
        0...Double(max(0, safePresets.count - 1))
    }

    private var nearestIndex: Int {
        nearestIndex(for: sliderPosition)
    }

    private var sliderPosition: Double {
        guard let index = safePresets.enumerated().min(by: { abs($0.element - value) < abs($1.element - value) })?.offset else {
            return 0
        }
        return Double(index)
    }

    private var displayValue: Double {
        let index = min(max(Int(sliderPosition.rounded()), 0), safePresets.count - 1)
        return safePresets[index]
    }

    private func nearestIndex(for sliderValue: Double) -> Int {
        let rounded = Int(sliderValue.rounded())
        return min(max(rounded, 0), safePresets.count - 1)
    }
}

private extension ControlSliderSheet {
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
#endif

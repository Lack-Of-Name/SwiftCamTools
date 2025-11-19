#if canImport(SwiftUI)
import SwiftUI
import SwiftCamCore

struct ManualControlsDrawer: View {
    @ObservedObject var viewModel: CameraViewModel

    var body: some View {
        VStack(spacing: 18) {
            Capsule()
                .frame(width: 60, height: 5)
                .foregroundStyle(Color.white.opacity(0.35))
                .padding(.top, 8)

            Toggle("Long Exposure", isOn: Binding(get: {
                viewModel.mode == .longExposure
            }, set: { enabled in
                viewModel.mode = enabled ? .longExposure : .auto
            }))
            .toggleStyle(SwitchToggleStyle(tint: .white))
            .foregroundStyle(.white)

            ControlSliderRow(title: "ISO", value: Binding(get: {
                viewModel.isoValue
            }, set: { newValue in
                viewModel.updateISO(newValue)
            }), range: 100...6400, formatter: { value in
                "ISO " + Int(value).formatted()
            })

            ControlSliderRow(title: "Shutter", value: Binding(get: {
                viewModel.shutterSeconds
            }, set: { newValue in
                viewModel.updateShutter(seconds: newValue)
            }), range: 0.125...8, formatter: { value in
                String(format: "%.2fs", value)
            })

            ControlSliderRow(title: "Noise", value: Binding(get: {
                viewModel.noiseReduction
            }, set: { newValue in
                viewModel.updateNoiseReduction(newValue)
            }), range: 0...1, formatter: { value in
                String(format: "%.0f%%", value * 100)
            })

            HStack {
                Button("Reset") {
                    viewModel.resetManualControls()
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.15))

                Spacer()

                Button(action: viewModel.toggleDrawer) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(Color.black.opacity(0.4), in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .padding(.top, 4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 32))
        .padding(.horizontal, 16)
    }
}
#endif

private struct ControlSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let formatter: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title.uppercased())
                    .font(.caption)
                    .foregroundStyle(.gray)
                Spacer()
                Text(formatter(value))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
            }

            Slider(value: $value, in: range)
                .tint(.white)
        }
    }
}

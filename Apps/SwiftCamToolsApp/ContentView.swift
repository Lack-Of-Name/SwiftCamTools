#if canImport(SwiftUI)
import SwiftUI
import SwiftCamCore
#if canImport(AVFoundation)
import AVFoundation
#endif

struct ContentView: View {
    @EnvironmentObject private var viewModel: CameraViewModel
    @State private var activeControl: CameraControlKind?

    var body: some View {
        ZStack {
            CameraPreviewView(session: viewModel.session, orientation: viewModel.previewOrientation)
                .saturation(Double(viewModel.settings.colorSaturation))
                .ignoresSafeArea()

            if viewModel.showGridOverlay {
                GridOverlayView()
                    .ignoresSafeArea()
            }

            GeometryReader { _ in
                Group {
                    if viewModel.previewOrientation.isLandscape {
                        landscapeChrome
                    } else {
                        portraitChrome
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: viewModel.previewOrientation)
            }

            if let remaining = viewModel.countdownSecondsRemaining {
                CountdownOverlayView(remainingSeconds: remaining)
                    .allowsHitTesting(true)
            }
        }
        .background(Color.black)
        .task {
            await viewModel.prepareSession()
        }
#if canImport(UIKit)
        .onDeviceRotate { orientation in
            viewModel.updateDeviceOrientation(orientation)
        }
#endif
        .sheet(item: $activeControl) { control in
            ControlSliderSheet(viewModel: viewModel, control: control)
                .presentationDetents([.height(260)])
                .presentationDragIndicator(.visible)
        }
        .alert(item: Binding(get: {
            viewModel.lastError.map(IdentifiedCameraError.init)
        }, set: { newValue in
            viewModel.lastError = newValue?.error
        })) { item in
            Alert(title: Text("Capture Error"), message: Text(item.error.localizedDescription), dismissButton: .default(Text("OK")))
        }
    }
}

private extension ContentView {
    var portraitChrome: some View {
        VStack(spacing: 0) {
            CameraTopBar(viewModel: viewModel)
                .disabled(viewModel.isCaptureLocked)

            Spacer()

            if viewModel.isControlsPanelPresented {
                CameraControlsPanel(viewModel: viewModel) { control in
                    activeControl = control
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.bottom, 8)
                .disabled(viewModel.isCaptureLocked)
            }

            CameraBottomBar(viewModel: viewModel, captureAction: {
                viewModel.capture()
            }, controlsAction: {
                viewModel.toggleControlsPanel()
            })
            .disabled(viewModel.isCaptureLocked)
            .opacity(viewModel.isCaptureLocked ? 0.8 : 1)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    var landscapeChrome: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(spacing: 16) {
                CameraTopBar(viewModel: viewModel)
                    .disabled(viewModel.isCaptureLocked)
                Spacer()
            }
            .frame(width: 220)

            Spacer(minLength: 12)

            VStack(spacing: 16) {
                Spacer()

                if viewModel.isControlsPanelPresented {
                    CameraControlsPanel(viewModel: viewModel) { control in
                        activeControl = control
                    }
                    .frame(maxWidth: 320)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .disabled(viewModel.isCaptureLocked)
                }

                CameraBottomBar(viewModel: viewModel, captureAction: {
                    viewModel.capture()
                }, controlsAction: {
                    viewModel.toggleControlsPanel()
                })
                .disabled(viewModel.isCaptureLocked)
                .opacity(viewModel.isCaptureLocked ? 0.8 : 1)
            }
            .frame(width: 320)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
    }
}

#Preview {
    ContentView()
        .environmentObject(CameraViewModel())
}

private struct IdentifiedCameraError: Identifiable {
    let id = UUID()
    let error: CameraError
}
#endif

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
                .ignoresSafeArea()

            if viewModel.showGridOverlay {
                GridOverlayView()
                    .ignoresSafeArea()
            }

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

#Preview {
    ContentView()
        .environmentObject(CameraViewModel())
}

private struct IdentifiedCameraError: Identifiable {
    let id = UUID()
    let error: CameraError
}
#endif

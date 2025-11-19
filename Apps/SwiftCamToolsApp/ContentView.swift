#if canImport(SwiftUI)
import SwiftUI
import SwiftCamCore

struct ContentView: View {
    @EnvironmentObject private var viewModel: CameraViewModel

    var body: some View {
        ZStack {
            CameraPreviewView(session: viewModel.session)
                .ignoresSafeArea()

            if viewModel.showGridOverlay {
                GridOverlayView()
                    .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                CameraTopBar(viewModel: viewModel)

                Spacer()

                if viewModel.isControlDrawerPresented {
                    ManualControlsDrawer(viewModel: viewModel)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 8)
                }

                CameraBottomBar(viewModel: viewModel, captureAction: {
                    viewModel.capture()
                }, controlsAction: {
                    viewModel.toggleDrawer()
                })
            }
        }
        .background(Color.black)
        .task {
            await viewModel.prepareSession()
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

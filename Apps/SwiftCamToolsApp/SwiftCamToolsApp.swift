#if canImport(SwiftUI)
import SwiftUI
import SwiftCamCore

@main
struct SwiftCamToolsApp: App {
    @StateObject private var viewModel = CameraViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
        }
    }
}
#endif

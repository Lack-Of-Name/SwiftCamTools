#if canImport(SwiftUI)
import SwiftUI

/// Legacy manual controls drawer placeholder retained to preserve previews referencing the type.
/// The new controls experience lives in `CameraControlsPanel` + `ControlSliderSheet`.
struct ManualControlsDrawer: View {
    var body: some View {
        EmptyView()
    }
}
#endif

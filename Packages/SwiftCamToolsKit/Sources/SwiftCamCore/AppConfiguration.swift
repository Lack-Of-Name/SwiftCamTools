import Foundation

public struct AppConfiguration {
    public var defaultMode: CaptureMode
    public var maxLongExposureSeconds: Double
    public var metalDenoiseEnabled: Bool

    public init(defaultMode: CaptureMode = .auto, maxLongExposureSeconds: Double = 3.0, metalDenoiseEnabled: Bool = true) {
        self.defaultMode = defaultMode
        self.maxLongExposureSeconds = maxLongExposureSeconds
        self.metalDenoiseEnabled = metalDenoiseEnabled
    }
}

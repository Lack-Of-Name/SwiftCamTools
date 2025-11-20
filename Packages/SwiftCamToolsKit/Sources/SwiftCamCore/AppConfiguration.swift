import Foundation

public struct AppConfiguration {
    public var maxLongExposureSeconds: Double
    public var metalDenoiseEnabled: Bool

    public init(maxLongExposureSeconds: Double = 10.0, metalDenoiseEnabled: Bool = true) {
        self.maxLongExposureSeconds = maxLongExposureSeconds
        self.metalDenoiseEnabled = metalDenoiseEnabled
    }
}

import Foundation
#if canImport(CoreMedia)
import CoreMedia
#else
public typealias CMTimeValue = Int64
#endif

public struct ExposureSafetyLimits {
    public let minISO: Float
    public let maxISO: Float
    public let minShutterSeconds: Double
    public let maxShutterSeconds: Double
    public let previewMaxShutterSeconds: Double
    public let highlightRatioThreshold: Double
    public let recoveryFrameBudget: Int
    public let recoveryISO: Float
    public let recoveryShutterSeconds: Double

    public init(
        minISO: Float,
        maxISO: Float,
        minShutterSeconds: Double,
        maxShutterSeconds: Double,
        previewMaxShutterSeconds: Double,
        highlightRatioThreshold: Double,
        recoveryFrameBudget: Int,
        recoveryISO: Float,
        recoveryShutterSeconds: Double
    ) {
        self.minISO = minISO
        self.maxISO = maxISO
        self.minShutterSeconds = minShutterSeconds
        self.maxShutterSeconds = maxShutterSeconds
        self.previewMaxShutterSeconds = previewMaxShutterSeconds
        self.highlightRatioThreshold = highlightRatioThreshold
        self.recoveryFrameBudget = recoveryFrameBudget
        self.recoveryISO = recoveryISO
        self.recoveryShutterSeconds = recoveryShutterSeconds
    }

    public static let longExposureDefaults = ExposureSafetyLimits(
        minISO: 80,
        maxISO: 4800,
        minShutterSeconds: 0.1,
        maxShutterSeconds: 10.0,
        previewMaxShutterSeconds: 0.08,
        highlightRatioThreshold: 0.88,
        recoveryFrameBudget: 4,
        recoveryISO: 400,
        recoveryShutterSeconds: 0.5
    )

    public func clamp(iso value: Float) -> Float {
        max(minISO, min(value, maxISO))
    }

    public func clamp(duration value: CMTimeValue) -> CMTimeValue {
        let seconds = Double(value) / 1_000_000_000.0
        let clamped = clamp(durationSeconds: seconds)
        return CMTimeValue(clamped * 1_000_000_000.0)
    }

    public func clamp(durationSeconds seconds: Double) -> Double {
        max(minShutterSeconds, min(seconds, maxShutterSeconds))
    }

    public func clampPreview(duration value: CMTimeValue) -> CMTimeValue {
        let seconds = Double(value) / 1_000_000_000.0
        let clamped = clampPreview(durationSeconds: seconds)
        return CMTimeValue(clamped * 1_000_000_000.0)
    }

    public func clampPreview(durationSeconds seconds: Double) -> Double {
        let capped = min(seconds, previewMaxShutterSeconds)
        return max(1.0 / 1000.0, capped)
    }
}

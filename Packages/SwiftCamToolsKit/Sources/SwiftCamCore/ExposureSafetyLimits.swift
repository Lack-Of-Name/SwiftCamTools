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
    public let highlightRatioThreshold: Double
    public let recoveryFrameBudget: Int
    public let recoveryISO: Float
    public let recoveryShutterSeconds: Double

    public static func forMode(_ mode: CaptureMode) -> ExposureSafetyLimits {
        switch mode {
        case .auto:
            return ExposureSafetyLimits(
                minISO: 80,
                maxISO: 1600,
                minShutterSeconds: 1.0 / 500.0,
                maxShutterSeconds: 0.12,
                highlightRatioThreshold: 0.85,
                recoveryFrameBudget: 3,
                recoveryISO: 200,
                recoveryShutterSeconds: 0.02
            )
        case .longExposure:
            return ExposureSafetyLimits(
                minISO: 80,
                maxISO: 4800,
                minShutterSeconds: 0.1,
                maxShutterSeconds: 10.0,
                highlightRatioThreshold: 0.88,
                recoveryFrameBudget: 4,
                recoveryISO: 400,
                recoveryShutterSeconds: 0.5
            )
        case .bracketed:
            return ExposureSafetyLimits(
                minISO: 80,
                maxISO: 2000,
                minShutterSeconds: 1.0 / 125.0,
                maxShutterSeconds: 0.75,
                highlightRatioThreshold: 0.86,
                recoveryFrameBudget: 3,
                recoveryISO: 250,
                recoveryShutterSeconds: 0.04
            )
        case .raw:
            return ExposureSafetyLimits(
                minISO: 64,
                maxISO: 1600,
                minShutterSeconds: 1.0 / 250.0,
                maxShutterSeconds: 0.5,
                highlightRatioThreshold: 0.85,
                recoveryFrameBudget: 3,
                recoveryISO: 160,
                recoveryShutterSeconds: 0.02
            )
        }
    }

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
}

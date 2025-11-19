import Foundation
import Collections
#if canImport(CoreMedia)
import CoreMedia
#else
public typealias CMTimeValue = Int64
#endif

public struct ExposureSettings: Equatable, Codable {
    public var iso: Float
    public var duration: CMTimeValue
    public var bracketOffsets: [Float]
    public var noiseReductionLevel: Float

    public init(iso: Float = 800, duration: CMTimeValue = 1_000_000_000, bracketOffsets: [Float] = [], noiseReductionLevel: Float = 0.6) {
        self.iso = iso
        self.duration = duration
        self.bracketOffsets = bracketOffsets
        self.noiseReductionLevel = noiseReductionLevel
    }
}

public final class ExposureQueue {
    private var jobs = Deque<ExposureSettings>()
    public init() {}

    public func enqueue(_ job: ExposureSettings) {
        jobs.append(job)
    }

    public func dequeue() -> ExposureSettings? {
        jobs.popFirst()
    }

    public var pending: [ExposureSettings] {
        Array(jobs)
    }
}

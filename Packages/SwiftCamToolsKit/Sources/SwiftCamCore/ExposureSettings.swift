import Foundation
import Collections
#if canImport(CoreMedia)
import CoreMedia
#endif

public struct ExposureSettings: Equatable, Codable {
    public var iso: Float
    public var duration: CMTimeValue
    public var bracketOffsets: [Float]
    public var noiseReductionLevel: Float
    public var autoISO: Bool
    public var aperture: Float
    public var exposureBias: Float
    public var autoFocus: Bool
    public var autoAperture: Bool
    public var colorSaturation: Float
    
    // MSR Parameters
    public var msrGain: Float
    public var msrOffset: Float
    public var msrSaturation: Float

    public init(
        iso: Float = 800,
        duration: CMTimeValue = 1_000_000_000,
        bracketOffsets: [Float] = [],
        noiseReductionLevel: Float = 0.6,
        autoISO: Bool = false,
        aperture: Float = 1.8,
        exposureBias: Float = 0.0,
        autoFocus: Bool = true,
        autoAperture: Bool = true,
        colorSaturation: Float = 1.0,
        msrGain: Float = 12.0,
        msrOffset: Float = 0.0,
        msrSaturation: Float = 1.2
    ) {
        self.iso = iso
        self.duration = duration
        self.bracketOffsets = bracketOffsets
        self.noiseReductionLevel = noiseReductionLevel
        self.autoISO = autoISO
        self.aperture = aperture
        self.exposureBias = exposureBias
        self.autoFocus = autoFocus
        self.autoAperture = autoAperture
        self.colorSaturation = colorSaturation
        self.msrGain = msrGain
        self.msrOffset = msrOffset
        self.msrSaturation = msrSaturation
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

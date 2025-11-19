import Foundation
import Algorithms

public struct HistogramBin: Identifiable, Equatable {
    public let id = UUID()
    public let value: Double
    public let frequency: Double
}

public struct HistogramModel {
    public var bins: [HistogramBin]

    public init(samples: [Double], bucketCount: Int = 32) {
        guard bucketCount > 0, !samples.isEmpty else {
            self.bins = []
            return
        }

        let minValue = samples.min() ?? 0
        let maxValue = samples.max() ?? 1
        let width = max((maxValue - minValue) / Double(bucketCount), 0.0001)
        let grouped = samples.chunked(on: { Int(($0 - minValue) / width) })
        bins = grouped.map { key, values in
            HistogramBin(value: minValue + (Double(key) * width), frequency: Double(values.count) / Double(samples.count))
        }
    }
}

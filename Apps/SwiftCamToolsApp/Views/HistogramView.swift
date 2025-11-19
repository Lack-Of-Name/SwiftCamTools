import SwiftUI
import SwiftCamCore

struct HistogramView: View {
    let histogram: HistogramModel

    var body: some View {
        GeometryReader { proxy in
            let bins = histogram.bins
            let maxFrequency = bins.map(\.frequency).max() ?? 1

            HStack(alignment: .bottom, spacing: 2) {
                ForEach(bins) { bin in
                    Rectangle()
                        .fill(LinearGradient(colors: [.mint, .blue], startPoint: .bottom, endPoint: .top))
                        .frame(height: max(CGFloat(bin.frequency / maxFrequency) * proxy.size.height, 2))
                }
            }
        }
        .frame(height: 80)
    }
}

#Preview {
    HistogramView(histogram: HistogramModel(samples: stride(from: 0.0, through: 1.0, by: 0.05).map { _ in Double.random(in: 0...1) }))
        .frame(height: 120)
        .padding()
        .background(Color.black)
}

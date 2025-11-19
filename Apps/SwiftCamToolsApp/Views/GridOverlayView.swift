#if canImport(SwiftUI)
import SwiftUI

struct GridOverlayView: View {
    var body: some View {
        GeometryReader { geo in
            Path { path in
                let columns = 2
                let rows = 2
                let columnWidth = geo.size.width / CGFloat(columns + 1)
                let rowHeight = geo.size.height / CGFloat(rows + 1)

                for index in 1...columns {
                    let x = CGFloat(index) * columnWidth
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: geo.size.height))
                }

                for index in 1...rows {
                    let y = CGFloat(index) * rowHeight
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.8)
        }
        .allowsHitTesting(false)
    }
}
#endif

#Preview {
    GridOverlayView()
        .background(Color.black)
}

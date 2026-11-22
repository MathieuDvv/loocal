import SwiftUI

/// The "audio-lines" glyph (six rounded vertical strokes, after Lucide's audio-lines),
/// drawn natively so it matches Geist's stroke weight and can animate.
struct AudioLinesIcon: View {
    var size: CGFloat = 20
    /// Optional live levels (0…1) per bar; nil draws the static icon.
    var levels: [Double]? = nil

    /// Lucide geometry on a 24-unit grid: x position and the static top/bottom of each bar.
    private static let bars: [(x: CGFloat, top: CGFloat, bottom: CGFloat)] = [(2, 10, 13), (6, 6, 17), (10, 3, 21), (14, 8, 15), (18, 5, 18), (22, 10, 13)]

    var body: some View {
        Canvas { context, canvas in
            let s = canvas.width / 24
            var path = Path()
            for (i, bar) in Self.bars.enumerated() {
                var top = bar.top, bottom = bar.bottom
                if let levels, levels.indices.contains(i) {
                    let half = 1.5 + 9 * levels[i]
                    top = 12 - half; bottom = 12 + half
                }
                path.move(to: CGPoint(x: bar.x * s, y: top * s))
                path.addLine(to: CGPoint(x: bar.x * s, y: bottom * s))
            }
            context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 1.9 * s, lineCap: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

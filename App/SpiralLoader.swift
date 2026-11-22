import SwiftUI

/// Native port of the 21st.dev "Spiral Loader" (Agent Elements, MIT).
///
/// The original is two Lottie clips of the same cursive three-loop stroke: a trimmed
/// segment slides along the path while the path itself scrolls left by one loop, so the
/// stroke appears to be written in place. A fast clip (0.5 s) plays four times, then a
/// slow clip (1 s) plays twice, and the cycle repeats. Keyframes and easing curves below
/// are copied from the source animation data (16 × 16 canvas, 60 fps).
struct SpiralLoader: View {
    var size: CGFloat = 16
    var color: Color = Ink.primary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            Canvas { canvas, canvasSize in
                let frame = Self.frame(at: reduceMotion ? 0.25 : context.date.timeIntervalSinceReferenceDate)
                let scale = canvasSize.width / 16
                var transform = CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: frame.offset, y: 8)
                guard let moved = Self.path.copy(using: &transform) else { return }
                let trimmed = Path(moved).trimmedPath(from: frame.start, to: frame.end)
                canvas.stroke(trimmed, with: .color(color), style: StrokeStyle(lineWidth: 1.4 * scale, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .accessibilityLabel("Working")
    }

    private struct Frame { var offset: CGFloat; var start: CGFloat; var end: CGFloat }

    private static func frame(at time: TimeInterval) -> Frame {
        // 4 × 0.5 s fast + 2 × 1 s slow = 4 s cycle.
        let cycle = time.truncatingRemainder(dividingBy: 4)
        let fast = cycle < 2
        let p = fast ? cycle.truncatingRemainder(dividingBy: 0.5) / 0.5 : (cycle - 2).truncatingRemainder(dividingBy: 1)
        let startEase = fast ? Bezier(0.32, 0.154, 0.826, 0.579) : Bezier(0.32, 0.313, 0.826, 0.143)
        let endEase = fast ? Bezier(0.341, 0.488, 0.269, 0.75) : Bezier(0.341, 0.992, 0.269, 0.491)
        let offset = 12 - 8 * Bezier(0.167, 0.167, 0.833, 0.833).value(p)
        return Frame(offset: offset, start: 0.23 + 0.34 * startEase.value(p), end: 0.44 + 0.33 * endEase.value(p))
    }

    /// Cursive loop stroke in Lottie's vertex / in-tangent / out-tangent form, centred on the origin.
    static let path: CGPath = {
        let v: [(CGFloat, CGFloat)] = [(-12, 6), (-4.975, -1.012), (-8, -6), (-11.025, -1.012), (-4, 6), (3.025, -1.012), (0, -6), (-3.025, -1.012), (4, 6), (11.025, -1.012), (8, -6), (4.98, -1.012), (12, 6)]
        let i: [(CGFloat, CGFloat)] = [(0, 0), (-0.289, 3.296), (2.218, 0), (-0.23, -2.627), (-4.452, 0), (-0.289, 3.296), (2.218, 0), (-0.23, -2.627), (-4.452, 0), (-0.289, 3.296), (2.218, 0), (-0.232, -2.627), (-4.443, 0)]
        let o: [(CGFloat, CGFloat)] = [(4.452, 0), (0.23, -2.627), (-2.218, 0), (0.289, 3.296), (4.452, 0), (0.23, -2.627), (-2.218, 0), (0.289, 3.296), (4.452, 0), (0.23, -2.627), (-2.218, 0), (0.292, 3.296), (0, 0)]
        let path = CGMutablePath()
        path.move(to: CGPoint(x: v[0].0, y: v[0].1))
        for k in 1..<v.count {
            path.addCurve(to: CGPoint(x: v[k].0, y: v[k].1),
                          control1: CGPoint(x: v[k - 1].0 + o[k - 1].0, y: v[k - 1].1 + o[k - 1].1),
                          control2: CGPoint(x: v[k].0 + i[k].0, y: v[k].1 + i[k].1))
        }
        return path
    }()
}

/// CSS-style cubic-bezier timing curve.
private struct Bezier {
    let x1, y1, x2, y2: Double
    init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) { (self.x1, self.y1, self.x2, self.y2) = (x1, y1, x2, y2) }

    func value(_ x: Double) -> Double {
        var t = x
        for _ in 0..<8 { // Newton–Raphson on x(t)
            let dx = sample(t, x1, x2) - x
            let d = slope(t, x1, x2)
            if abs(dx) < 1e-5 || abs(d) < 1e-6 { break }
            t -= dx / d
        }
        return sample(min(max(t, 0), 1), y1, y2)
    }
    private func sample(_ t: Double, _ a: Double, _ b: Double) -> Double { ((1 - 3 * b + 3 * a) * t + (3 * b - 6 * a)) * t * t + 3 * a * t }
    private func slope(_ t: Double, _ a: Double, _ b: Double) -> Double { 3 * (1 - 3 * b + 3 * a) * t * t + 2 * (3 * b - 6 * a) * t + 3 * a }
}

/// The full loop stroke, untrimmed. Used for brand marks.
struct LoopMark: View {
    var color: Color = Ink.primary
    /// Dashed: the temporary-chat mark.
    var dashed = false
    var body: some View {
        Canvas { canvas, size in
            let scale = size.width / 26
            var transform = CGAffineTransform(translationX: size.width / 2, y: size.height / 2).scaledBy(x: scale, y: scale)
            guard let path = SpiralLoader.path.copy(using: &transform) else { return }
            canvas.stroke(Path(path), with: .color(color), style: StrokeStyle(lineWidth: 1.4 * scale, lineCap: .round, lineJoin: .round, dash: dashed ? [3.4 * scale, 2.6 * scale] : []))
        }
        .aspectRatio(2, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

#Preview {
    VStack(spacing: 40) {
        SpiralLoader(size: 64)
        SpiralLoader(size: 16)
        LoopMark().frame(width: 120)
    }
}

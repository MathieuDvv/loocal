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

    private static func frame(at time: TimeInterval) -> LoopGeometry.Frame { LoopGeometry.frame(at: time) }
    static var path: CGPath { LoopGeometry.path }
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

/// The loop mark that unravels into a ghost (temporary chat) and winds back. It's one
/// thread: its right end pulls away and goes on to draw the ghost in a single line, while
/// the loops run out behind it.
struct LoopGhostMark: View {
    /// 0 is the loop, 1 the ghost.
    var progress: CGFloat
    var color: Color = Ink.primary

    var body: some View {
        GeometryReader { proxy in
            LoopGhostShape(progress: progress)
                .stroke(color, style: StrokeStyle(lineWidth: 1.4 * proxy.size.width / 26, lineCap: .round, lineJoin: .round))
        }
        .aspectRatio(2, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

struct LoopGhostShape: Shape {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let p = min(max(progress, 0), 1)
        // The visible stretch slides along the thread: loop → bridge → ghost.
        let from = p * Self.ghostStart
        let to = Self.loopEnd + p * (1 - Self.loopEnd)
        let scale = rect.width / 26
        let transform = CGAffineTransform(translationX: rect.midX, y: rect.midY).scaledBy(x: scale, y: scale)
        return Self.thread.trimmedPath(from: from, to: to).applying(transform)
    }

    /// The whole thread: the loop left to right, a short slack from its right end, then a
    /// ghost outline that starts and ends at its bottom right. Units match the loop (≈ 24 × 12).
    private static let parts: (thread: Path, loop: CGFloat, bridge: CGFloat, ghost: CGFloat) = {
        let loop = Path(SpiralLoader.path)
        var bridge = Path()
        bridge.move(to: CGPoint(x: 12, y: 6))
        bridge.addQuadCurve(to: CGPoint(x: 5, y: 4.8), control: CGPoint(x: 9, y: 7.6))
        var ghost = Path()
        ghost.move(to: CGPoint(x: 5, y: 4.8))
        ghost.addLine(to: CGPoint(x: 5, y: -0.6))
        ghost.addCurve(to: CGPoint(x: 0, y: -6), control1: CGPoint(x: 5, y: -3.9), control2: CGPoint(x: 2.8, y: -6))
        ghost.addCurve(to: CGPoint(x: -5, y: -0.6), control1: CGPoint(x: -2.8, y: -6), control2: CGPoint(x: -5, y: -3.9))
        ghost.addLine(to: CGPoint(x: -5, y: 4.8))
        for k in 0..<4 {
            let x0 = -5 + CGFloat(k) * 2.5
            ghost.addQuadCurve(to: CGPoint(x: x0 + 2.5, y: 4.8), control: CGPoint(x: x0 + 1.25, y: 6.6))
        }
        var thread = loop
        thread.addPath(bridge)
        thread.addPath(ghost)
        return (thread, length(loop), length(bridge), length(ghost))
    }()

    private static let thread = parts.thread
    private static var total: CGFloat { parts.loop + parts.bridge + parts.ghost }
    private static let loopEnd = parts.loop / (parts.loop + parts.bridge + parts.ghost)
    private static let ghostStart = (parts.loop + parts.bridge) / (parts.loop + parts.bridge + parts.ghost)

    private static func length(_ path: Path) -> CGFloat {
        var points: [CGPoint] = []
        for i in 0...240 {
            if let point = path.trimmedPath(from: 0, to: max(CGFloat(i) / 240, 0.0005)).currentPoint { points.append(point) }
        }
        return zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }
}

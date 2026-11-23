import SwiftUI
import UIKit

// MARK: - Entering paint mode

/// A fluid-acrylic pour: vivid marbled paint (blues, cyan, lime, yolk, coral, magenta,
/// violet, ink, gold veins, white cells) wells up round the model selector, rounded like the
/// pill, and pours down to fill the screen with a dripping front, then drains from the top
/// while fading out. The pill is drawn on top, as if the paint came out from under it.
/// The paint is drawn by `acrylicPour` (Pour.metal).
struct PaintInfusion: View {
    /// The selector's centre and size, in this view's (full-screen) space, and its label.
    let origin: CGPoint
    let pill: CGSize
    let name: String
    @State private var start = Date.now

    static var duration: Double { 1.3 * pace }
    /// `-slowPour` (debug builds) plays it five times slower, to look at it closely.
    #if DEBUG
    static let pace: Double = ProcessInfo.processInfo.arguments.contains("-slowPour") ? 5 : 1
    #else
    static let pace: Double = 1
    #endif

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation) { context in
                let elapsed = context.date.timeIntervalSince(start) / Self.pace
                // Reaches the bottom in about half a second, speeding up as it falls, drains
                // from the top right after, and fades from the halfway mark as it goes.
                let fill = pow(min(max(elapsed / 0.55, 0), 1), 1.4)
                let drain = pow(min(max((elapsed - 0.5) / 0.8, 0), 1), 1.3)
                let fade = min(max((elapsed - 0.65) / 0.65, 0), 1)
                ZStack {
                    Rectangle()
                        .fill(.white)
                        .colorEffect(ShaderLibrary.acrylicPour(
                            .float2(proxy.size), .float(elapsed + 3), .float(fill), .float(drain),
                            .float2(origin), .float2(pill)))
                        .opacity(1 - fade * fade * (3 - 2 * fade))
                    PaintedPill(name: name, size: pill)
                        .position(origin)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The selector as it looks at rest on a picture model, drawn over the pour so the paint
/// seems to come from beneath it. The same paint, in step, as the real one underneath.
private struct PaintedPill: View {
    let name: String
    let size: CGSize

    var body: some View {
        Text(name)
            .font(.geist(15, .medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .frame(width: size.width, height: size.height)
            .background(LiquidPaint())
            .shadow(color: Color(red: 1, green: 0.3, blue: 0.5).opacity(0.25), radius: 12, y: 4)
    }
}

/// A small, repeatable random sequence, so a pour (or a canvas) looks the same every time.
struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    /// 0…1
    mutating func unit() -> CGFloat { CGFloat(next() >> 11) / CGFloat(UInt64(1) << 53) }
}

// MARK: - Painting a picture

/// The reply while a picture is painted: a grey rounded square slowly covered in textured
/// brush strokes laid at random, overlapping, with the percentage in the corner. The finished
/// picture is then brushed in over them. Afterwards, just the picture.
struct PaintCanvasView: View {
    let id: UUID
    let info: PaintInfo
    let status: ChatMessage.Status
    let step: PaintStep?
    let image: UIImage?
    /// Finished while on screen: brush the picture in once.
    let fresh: Bool

    @State private var revealStart: Date?
    @State private var stepAt = Date.now
    @State private var smoother = Smoother()
    private let side: CGFloat = 288

    /// Glides the shown progress towards its target, so a step finishing never jumps it.
    /// A reference type, updated while drawing without invalidating the view.
    final class Smoother {
        private var value = 0.0
        private var last: Date?
        func follow(_ target: Double, at now: Date) -> Double {
            let dt = last.map { now.timeIntervalSince($0) } ?? 0
            last = now
            value += (target - value) * (1 - exp(-dt / 0.9))
            return value
        }
    }

    var body: some View {
        ZStack {
            if image == nil || revealStart != nil {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: status != .generating)) { context in
                    let shown = image != nil ? 1 : smoother.follow(progress(at: context.date), at: context.date)
                    BrushCover(seed: id, coverage: shown)
                        .overlay(alignment: .topTrailing) {
                            if image == nil {
                                Text(status == .interrupted ? "Stopped" : "\(Int(shown * 100))%")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Ink.primary)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(.regularMaterial, in: .capsule)
                                    .padding(10)
                            }
                        }
                }
                .transition(.opacity)
            }
            if let image {
                if let revealStart {
                    BrushReveal(image: image, start: revealStart)
                } else {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(.rect(cornerRadius: 22))
        .contextMenu {
            if let image {
                ShareLink(item: SwiftUI.Image(uiImage: image), preview: SharePreview(info.prompt, image: SwiftUI.Image(uiImage: image)))
                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.image = image }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { if fresh, image != nil { revealStart = .now } }
        .onChange(of: image != nil) { _, has in if has && fresh { revealStart = .now } }
        .onChange(of: step?.done) { _, _ in stepAt = .now }
        .task(id: revealStart) {
            guard revealStart != nil else { return }
            try? await Task.sleep(for: .seconds(BrushReveal.duration + 0.1))
            withAnimation(.smooth) { revealStart = nil }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(image == nil ? "Painting: \(info.prompt)" : "Picture: \(info.prompt)")
    }

    /// Smooth progress between the model's few, coarse steps: what's done, plus most of the
    /// step under way, approached gradually. Holds below 100% until the picture is there.
    private func progress(at now: Date) -> Double {
        let since = now.timeIntervalSince(stepAt)
        guard let step, step.total > 0 else {
            // Loading the model, before the first step: creep towards a tenth.
            return 0.1 * (1 - exp(-since / 4))
        }
        let share = 0.85 / Double(step.total)
        let base = 0.1 + share * Double(step.done)
        return min(base + share * 0.9 * (1 - exp(-since / 2.5)), 0.99)
    }
}

/// Brush strokes laid down one by one on a grey ground, at random places and angles,
/// overlapping, until they cover it. Each has bristle texture: streaks of slightly different
/// tone and length, dry and broken at the ends.
private struct BrushCover: View {
    let seed: UUID
    /// 0…1: how many of the strokes are down.
    let coverage: Double
    @Environment(\.colorScheme) private var scheme

    private struct Bristle { let offset: CGFloat; let width: CGFloat; let alpha: Double; let from: CGFloat; let to: CGFloat }
    private struct Stroke { let start: CGPoint; let end: CGPoint; let bend: CGFloat; let width: CGFloat; let tone: Double; let bristles: [Bristle] }

    static let count = 70

    private static func strokes(_ seed: UUID) -> [Stroke] {
        // The same strokes for the same picture, every time it's drawn.
        var rng = SplitMix(seed: seed.uuidString.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 })
        return (0..<count).map { _ in
            let center = CGPoint(x: rng.unit(), y: rng.unit())
            let angle = rng.unit() * .pi
            let length = 0.3 + rng.unit() * 0.45
            let d = CGPoint(x: cos(angle) * length / 2, y: sin(angle) * length / 2)
            let bristles = (0..<9).map { _ in
                Bristle(offset: rng.unit() - 0.5, width: 0.06 + rng.unit() * 0.12, alpha: 0.35 + Double(rng.unit()) * 0.65,
                        from: rng.unit() * 0.12, to: 0.86 + rng.unit() * 0.14)
            }
            return Stroke(start: CGPoint(x: center.x - d.x, y: center.y - d.y), end: CGPoint(x: center.x + d.x, y: center.y + d.y),
                          bend: (rng.unit() - 0.5) * 0.15, width: 0.08 + rng.unit() * 0.08, tone: Double(rng.unit()), bristles: bristles)
        }
    }

    var body: some View {
        let strokes = Self.strokes(seed)
        let dark = scheme == .dark
        Canvas { canvas, size in
            canvas.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: dark ? 0.17 : 0.9)))
            let down = coverage * Double(Self.count)
            for (i, stroke) in strokes.enumerated() where Double(i) < down {
                // The newest stroke is still going on: it grows along its length.
                let drawn = min(1, CGFloat(down - Double(i)))
                let a = CGPoint(x: stroke.start.x * size.width, y: stroke.start.y * size.height)
                let b = CGPoint(x: stroke.end.x * size.width, y: stroke.end.y * size.height)
                let length = max(hypot(b.x - a.x, b.y - a.y), 1)
                let normal = CGVector(dx: -(b.y - a.y) / length, dy: (b.x - a.x) / length)
                let control = CGPoint(x: (a.x + b.x) / 2 + normal.dx * stroke.bend * size.width, y: (a.y + b.y) / 2 + normal.dy * stroke.bend * size.width)
                let width = stroke.width * size.width
                // Greys a little darker or lighter than the ground, so overlaps read as layers.
                let tone = dark ? 0.22 + stroke.tone * 0.24 : 0.6 + stroke.tone * 0.28
                var body = Path()
                body.move(to: a)
                body.addQuadCurve(to: b, control: control)
                canvas.stroke(body.trimmedPath(from: 0.04, to: 0.04 + 0.92 * drawn), with: .color(Color(white: tone).opacity(0.55)),
                              style: StrokeStyle(lineWidth: width * 0.8, lineCap: .round))
                for bristle in stroke.bristles {
                    let shift = bristle.offset * width
                    var path = Path()
                    path.move(to: CGPoint(x: a.x + normal.dx * shift, y: a.y + normal.dy * shift))
                    path.addQuadCurve(to: CGPoint(x: b.x + normal.dx * shift, y: b.y + normal.dy * shift),
                                      control: CGPoint(x: control.x + normal.dx * shift, y: control.y + normal.dy * shift))
                    canvas.stroke(path.trimmedPath(from: bristle.from, to: bristle.from + (bristle.to - bristle.from) * drawn),
                                  with: .color(Color(white: tone + (bristle.alpha - 0.6) * 0.14).opacity(bristle.alpha)),
                                  style: StrokeStyle(lineWidth: bristle.width * width, lineCap: .round))
                }
            }
        }
    }
}

/// The finished picture brushed in with broad diagonal strokes, one after another, while
/// the wet canvas underneath fades.
private struct BrushReveal: View {
    let image: UIImage
    let start: Date
    static let duration = 1.7

    private struct Stroke { let y0: CGFloat; let y1: CGFloat; let bend: CGFloat; let width: CGFloat }
    /// Strokes sweep left to right, stepping down the canvas, a little overlapped.
    private static let strokes: [Stroke] = (0..<11).map { i in
        let y = (CGFloat(i) - 0.5) / 9
        let jitter = CGFloat((i * 37) % 11) / 11 - 0.5
        return Stroke(y0: y + 0.08 + jitter * 0.04, y1: y - 0.1 + jitter * 0.05, bend: 0.06 * jitter, width: 0.17 + 0.03 * jitter)
    }

    var body: some View {
        TimelineView(.animation) { context in
            let p = min(max(context.date.timeIntervalSince(start) / Self.duration, 0), 1)
            Image(uiImage: image).resizable().scaledToFill()
                .mask {
                    Canvas { canvas, size in
                        let count = Double(Self.strokes.count)
                        for (i, stroke) in Self.strokes.enumerated() {
                            // Each stroke starts a little after the last and takes a third of the time.
                            let begin = Double(i) / count * 0.66
                            let local = min(max((p - begin) / 0.34, 0), 1)
                            guard local > 0 else { continue }
                            let eased = 1 - pow(1 - local, 2.2)
                            var path = Path()
                            let a = CGPoint(x: -0.1 * size.width, y: stroke.y0 * size.height)
                            let b = CGPoint(x: 1.1 * size.width, y: stroke.y1 * size.height)
                            path.move(to: a)
                            path.addQuadCurve(to: b, control: CGPoint(x: size.width * 0.5, y: (stroke.y0 + stroke.y1) / 2 * size.height + stroke.bend * size.height))
                            canvas.stroke(path.trimmedPath(from: 0, to: eased), with: .color(.black),
                                          style: StrokeStyle(lineWidth: stroke.width * size.height * (0.75 + 0.25 * eased), lineCap: .round))
                        }
                        // Fully covered by the end, whatever the strokes missed.
                        if p >= 1 { canvas.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black)) }
                    }
                }
                // Still wet at first: saturated and soft, settling as it dries.
                .saturation(1 + 0.6 * (1 - p))
                .blur(radius: 3 * (1 - p))
        }
    }
}

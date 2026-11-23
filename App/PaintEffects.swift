import SwiftUI
import UIKit

// MARK: - Entering paint mode

/// Colour bleeding out of the model selector across the app, like ink dropped in water,
/// when a picture model is picked; it drains back into the pill when you leave. Never stays.
struct PaintInfusion: View {
    let entering: Bool
    /// Where the paint comes from (and goes back to): the selector, near the top.
    var origin = UnitPoint(x: 0.5, y: 0.095)
    @State private var start = Date.now
    @Environment(\.colorScheme) private var scheme

    static func duration(entering: Bool) -> Double { entering ? 1.9 : 0.7 }
    private var duration: Double { Self.duration(entering: entering) }

    /// One drop of colour: its direction, reach and size.
    private struct Drop { let color: Color; let angle: Double; let reach: CGFloat; let size: CGFloat; let delay: Double }
    private static let drops: [Drop] = {
        let c = LiquidPaint.colors
        return [
            Drop(color: c[0], angle: 115, reach: 0.55, size: 0.62, delay: 0),
            Drop(color: c[1], angle: 70, reach: 0.42, size: 0.5, delay: 0.05),
            Drop(color: c[2], angle: 95, reach: 0.85, size: 0.7, delay: 0.12),
            Drop(color: c[3], angle: 40, reach: 0.7, size: 0.48, delay: 0.18),
            Drop(color: c[4], angle: 145, reach: 0.75, size: 0.45, delay: 0.22),
            Drop(color: c[0], angle: 20, reach: 0.95, size: 0.4, delay: 0.3),
            Drop(color: c[2], angle: 160, reach: 1.0, size: 0.42, delay: 0.34),
        ]
    }()

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(start)
            Canvas { canvas, size in
                let height = max(size.height, 1)
                let origin = CGPoint(x: origin.x * size.width, y: origin.y * size.height)
                // Overall strength: swells in fast, lingers, then fades away entirely.
                let p = min(max(elapsed / duration, 0), 1)
                let envelope = entering ? (p < 0.18 ? p / 0.18 : 1 - pow((p - 0.18) / 0.82, 1.6)) : (1 - p) * 0.8
                guard envelope > 0.001 else { return }
                canvas.addFilter(.blur(radius: 38))
                for (i, drop) in Self.drops.enumerated() {
                    let local = min(max((elapsed - drop.delay * (entering ? 1 : 0.3)) / (duration * 0.8), 0), 1)
                    // Out from the pill, easing like ink spreading; or back in when leaving.
                    let spread = entering ? 1 - pow(1 - local, 3) : 1 - local
                    let angle = (drop.angle + sin(elapsed * 1.7 + Double(i)) * 8) * .pi / 180
                    let distance = drop.reach * height * spread
                    let center = CGPoint(x: origin.x + cos(angle) * distance, y: origin.y + sin(angle) * distance)
                    let radius = max(6, drop.size * height * 0.55 * (0.2 + 0.8 * spread))
                    let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                    canvas.opacity = envelope * (scheme == .dark ? 0.6 : 0.42)
                    canvas.fill(Path(ellipseIn: rect), with: .radialGradient(Gradient(colors: [drop.color, drop.color.opacity(0)]), center: center, startRadius: 0, endRadius: radius))
                }
            }
            // Light on a dark page; ink soaking into paper on a light one.
            .blendMode(scheme == .dark ? .plusLighter : .multiply)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Painting a picture

/// The reply while a picture is painted: a dark canvas covered in faint brush dabs, where wet
/// colour wanders and blooms as the model works; then the picture is brushed in, stroke by
/// stroke. Afterwards, just the picture.
struct PaintCanvasView: View {
    let info: PaintInfo
    let status: ChatMessage.Status
    let step: PaintStep?
    let image: UIImage?
    /// Finished while on screen: brush the picture in once.
    let fresh: Bool

    @State private var revealStart: Date?
    private let side: CGFloat = 288

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                if image == nil || revealStart != nil {
                    WetCanvas(progress: step?.fraction ?? 0, stopped: status == .interrupted)
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
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Ink.hairline))
            .overlay(alignment: .topTrailing) {
                if image == nil {
                    Text("\(info.width) × \(info.height)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(.black.opacity(0.35), in: .capsule)
                        .padding(10)
                }
            }
            .contextMenu {
                if let image {
                    ShareLink(item: SwiftUI.Image(uiImage: image), preview: SharePreview(info.prompt, image: SwiftUI.Image(uiImage: image)))
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.image = image }
                }
            }
            caption
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { if fresh, image != nil { revealStart = .now } }
        .onChange(of: image != nil) { _, has in if has && fresh { revealStart = .now } }
        .task(id: revealStart) {
            guard revealStart != nil else { return }
            try? await Task.sleep(for: .seconds(BrushReveal.duration + 0.1))
            withAnimation(.smooth) { revealStart = nil }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(image == nil ? "Painting: \(info.prompt)" : "Picture: \(info.prompt)")
    }

    @ViewBuilder private var caption: some View {
        VStack(alignment: .leading, spacing: 3) {
            if image == nil {
                HStack(spacing: 6) {
                    Text(status == .interrupted ? "Stopped" : "Painting")
                        .font(.geist(14, .medium)).foregroundStyle(Ink.primary)
                        .shimmer()
                    if let step, step.total > 0, status == .generating {
                        Text("step \(min(step.done + 1, step.total)) of \(step.total)")
                            .font(.geist(13).monospacedDigit()).foregroundStyle(Ink.tertiary)
                            .contentTransition(.numericText())
                    }
                }
            }
            Text("“\(info.prompt)”")
                .font(.geist(13)).foregroundStyle(Ink.secondary).lineLimit(2)
                .frame(maxWidth: side, alignment: .leading)
        }
        .padding(.leading, 2)
        .animation(.smooth, value: step)
    }
}

/// Faint brush dabs on a dark ground. Wet colour wanders over them, morphing as it goes:
/// dabs under it swell, lengthen, turn with the flow and take its colour. The more the
/// picture has come along, the wider the wet patch.
private struct WetCanvas: View {
    let progress: Double
    let stopped: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 40, paused: stopped || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                canvas.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.075)))
                let w = size.width, h = size.height
                // Two wet patches drifting on slow, unrelated loops.
                let centers = [
                    CGPoint(x: w * (0.5 + 0.3 * sin(t * 0.53)), y: h * (0.5 + 0.28 * sin(t * 0.71 + 1))),
                    CGPoint(x: w * (0.5 + 0.32 * cos(t * 0.41 + 2)), y: h * (0.5 + 0.3 * sin(t * 0.37 + 4))),
                ]
                let reach = w * (0.17 + 0.16 * progress)
                let radii = [reach * (1 + 0.25 * sin(t * 1.3)), reach * 0.8 * (1 + 0.3 * cos(t * 1.1 + 1))]
                let colors = LiquidPaint.colors
                // A soft coloured bloom under the dabs.
                var glow = canvas
                glow.addFilter(.blur(radius: 26))
                for (i, c) in centers.enumerated() {
                    let r = radii[i] * 1.5
                    glow.opacity = stopped ? 0.12 : 0.35
                    glow.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                              with: .color(colors[(i * 2 + Int(t / 3)) % colors.count]))
                }
                let spacing: CGFloat = 14
                let cols = Int(w / spacing), rows = Int(h / spacing)
                let inset = CGPoint(x: (w - CGFloat(cols - 1) * spacing) / 2, y: (h - CGFloat(rows - 1) * spacing) / 2)
                for row in 0..<rows {
                    for col in 0..<cols {
                        let p = CGPoint(x: inset.x + CGFloat(col) * spacing, y: inset.y + CGFloat(row) * spacing)
                        // Wetness here: the nearer a patch, the more.
                        var wet: CGFloat = 0
                        var hue = 0
                        for (i, c) in centers.enumerated() {
                            let d = hypot(p.x - c.x, p.y - c.y) / radii[i]
                            let v = exp(-d * d * 1.6)
                            if v > wet { wet = v; hue = i }
                        }
                        if stopped { wet *= 0.3 }
                        let seed = Double((row * 73 + col * 151) % 97) / 97
                        let angle = Angle.degrees(-38 + (seed - 0.5) * 50 + Double(wet) * 25 * sin(t * 1.4 + seed * 6))
                        let length = 4.5 + 9 * wet
                        let thickness = 2 + 1.6 * wet
                        var dab = Path(roundedRect: CGRect(x: -length / 2, y: -thickness / 2, width: length, height: thickness), cornerRadius: thickness / 2)
                        dab = dab.applying(CGAffineTransform(rotationAngle: angle.radians)).applying(CGAffineTransform(translationX: p.x, y: p.y))
                        let tint = colors[(hue * 2 + Int(seed * 3) + Int(t / 3)) % colors.count]
                        canvas.opacity = 0.1 + 0.85 * wet
                        canvas.fill(dab, with: .color(wet > 0.25 ? tint : .white))
                    }
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

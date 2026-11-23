import SwiftUI
import UIKit

/// Centered model picker. At rest it's a capsule hugging the current name. Press and drag
/// sideways and it widens (height never changes) into a carousel of model names that
/// follows your finger and snaps to the nearest one, ticking as each name passes centre.
///
/// Picture models sit past the chat models on the far right, across a gap marked by a brush.
/// Crossing it takes a longer drag than moving between neighbours (the carousel holds back,
/// then gives), either way. On a picture model the capsule turns to wet paint.
struct ModelSelector: View {
    let options: [ModelChoice]
    var disabled = false
    @Binding var selection: String
    var dimmed = false

    @State private var expanded = false
    @State private var dragging = false
    @State private var live: CGFloat = 0     // fractional position under the centre, in drag space
    @State private var start: CGFloat = 0
    @State private var openedByTap = false
    @State private var midX: CGFloat = 0     // centre in screen space, for tap-to-pick

    /// Where the chat's selector sits on screen, for the paint poured out of it.
    @MainActor static var screenCenter: CGPoint?
    /// The capsule's size at rest around `name`.
    static func restingSize(_ name: String) -> CGSize {
        let font = UIFont(name: "Geist-Medium", size: 15) ?? .systemFont(ofSize: 15, weight: .medium)
        return CGSize(width: ceil((name as NSString).size(withAttributes: [.font: font]).width) + 34, height: 38)
    }

    private let slot: CGFloat = 124
    private let height: CGFloat = 38
    private let expandedWidth: CGFloat = 300
    private let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)
    /// Extra finger travel, in slots, to cross into picture models (or back).
    static let barrier: CGFloat = 0.8
    /// Extra room on screen, in slots, between the last chat model and the first picture one.
    static let gap: CGFloat = 0.55

    private var index: Int { options.firstIndex { $0.id == selection } ?? 0 }
    /// First picture model, if any.
    private var split: Int? { options.firstIndex { !$0.chats } }
    private var painted: Bool { options.indices.contains(index) && !options[index].chats }

    /// Where option `i` sits in drag space (fingers) and on screen.
    private func dragPosition(_ i: Int) -> CGFloat { CGFloat(i) + (split.map { i >= $0 ? Self.barrier : 0 } ?? 0) }
    private func screenPosition(_ i: Int) -> CGFloat { CGFloat(i) + (split.map { i >= $0 ? Self.gap : 0 } ?? 0) }

    /// Drag space → screen. Across the barrier the names hold back for the first half of the
    /// way, then catch up, so the crossing feels like pushing through.
    private func screen(_ value: CGFloat) -> CGFloat {
        guard let split, split > 0 else { return value }
        let a = CGFloat(split - 1), b = a + 1 + Self.barrier
        if value <= a { return value }
        if value >= b { return value - Self.barrier + Self.gap }
        let t = (value - a) / (b - a)
        let eased = t < 0.6 ? t * 0.45 : 0.27 + (t - 0.6) / 0.4 * 0.73
        return a + eased * (1 + Self.gap)
    }

    private func nearest(_ value: CGFloat) -> Int {
        options.indices.min { abs(dragPosition($0) - value) < abs(dragPosition($1) - value) } ?? 0
    }

    private var collapsedWidth: CGFloat {
        let font = UIFont(name: "Geist-Medium", size: 15) ?? .systemFont(ofSize: 15, weight: .medium)
        let name = options.indices.contains(index) ? options[index].name : ""
        return ceil((name as NSString).size(withAttributes: [.font: font]).width) + 34
    }

    var body: some View {
        capsule
            .sensoryFeedback(.selection, trigger: selection)
            .sensoryFeedback(.impact(weight: .light), trigger: expanded) { _, now in now }
            // Crossing into pictures (or back) lands with more weight than a neighbour.
            .sensoryFeedback(.impact(weight: .medium, intensity: 0.9), trigger: painted)
            .onAppear { live = dragPosition(index) }
            .onChange(of: selection) { _, _ in if !dragging { withAnimation(spring) { live = dragPosition(index) } } }
            .onChange(of: options.map(\.id)) { _, _ in if !dragging { live = dragPosition(index) } }
            .task(id: expanded && !dragging) {
                // A tap-opened carousel closes itself after a moment of no interaction.
                guard expanded && !dragging else { return }
                try? await Task.sleep(for: .seconds(2.5))
                if !Task.isCancelled && !dragging { withAnimation(spring) { expanded = false } }
            }
            .accessibilityElement()
            .accessibilityLabel("Model")
            .accessibilityValue(spoken)
            .accessibilityAdjustableAction(adjust)
            .accessibilityIdentifier("modelSelector")
    }

    private var spoken: String {
        guard options.indices.contains(index) else { return "" }
        return options[index].name + (painted ? ", paints pictures" : "")
    }

    private func adjust(_ direction: AccessibilityAdjustmentDirection) {
        let next = direction == .increment ? index + 1 : index - 1
        if options.indices.contains(next) { selection = options[next].id }
    }

    private var capsule: some View {
        let width = expanded ? expandedWidth : collapsedWidth
        return names(screen(live))
        .frame(width: width, height: height)
        .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: expanded ? 0.2 : 0), .init(color: .black, location: expanded ? 0.8 : 1), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing)
        }
        .background {
            ZStack {
                Capsule().fill(Ink.fill)
                // Wet paint while a picture model is picked, closed or opened.
                LiquidPaint().opacity(painted ? 1 : 0)
            }
        }
        .overlay(Capsule().stroke(Ink.hairline.opacity(expanded && !painted ? 1 : 0)))
        .scaleEffect(dragging ? 1.02 : 1)
        .shadow(color: glow, radius: 12, y: 4)
        .contentShape(.capsule)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { midX = $0.midX; Self.screenCenter = CGPoint(x: $0.midX, y: $0.midY) }
        .gesture(drag, isEnabled: !disabled)
        .opacity(disabled ? 0.5 : 1)
        .animation(.smooth(duration: 0.5), value: painted)
    }

    /// The brush marking the gap, and every model's name, placed around the centre.
    private func names(_ shown: CGFloat) -> some View {
        ZStack {
            if let split, split > 0 {
                // The brush between chat and picture models.
                Image(systemName: "paintbrush.pointed.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(painted ? AnyShapeStyle(.white) : AnyShapeStyle(LiquidPaint.gradient))
                    .rotationEffect(.degrees(-35))
                    .offset(x: ((CGFloat(split - 1) + screenPosition(split)) / 2 - shown) * slot)
                    .opacity(expanded ? 1 : 0)
                    .allowsHitTesting(false)
            }
            ForEach(Array(options.enumerated()), id: \.element.id) { i, option in
                name(option, distance: abs(screenPosition(i) - shown), offset: (screenPosition(i) - shown) * slot)
            }
        }
    }

    private func name(_ option: ModelChoice, distance: CGFloat, offset: CGFloat) -> some View {
        let centred = distance < 0.5
        let color: Color = painted ? .white.opacity(centred ? 1 : 0.72) : centred ? (dimmed ? Ink.secondary : Ink.primary) : Ink.tertiary
        let opacity: CGFloat = expanded ? max(0, 1 - distance * 0.42) : (centred ? 1 : 0)
        return Text(option.name)
            .font(.geist(15, centred ? .medium : .regular))
            .foregroundStyle(color)
            .lineLimit(1)
            // Open, each name keeps to its slot so long shared names don't overlap.
            .frame(maxWidth: expanded ? slot - 10 : nil)
            .fixedSize(horizontal: !expanded, vertical: false)
            .scaleEffect(1 - min(distance, 2) * 0.07)
            .opacity(opacity)
            .offset(x: offset)
            .allowsHitTesting(false)
    }

    private var glow: Color { painted ? Color(red: 1, green: 0.3, blue: 0.5).opacity(0.25) : .black.opacity(expanded ? 0.08 : 0) }

    /// Measured in screen space: the capsule widens mid-gesture, which would otherwise
    /// shift local coordinates under the finger and swallow most of the drag.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if !dragging {
                    dragging = true
                    openedByTap = !expanded
                    start = dragPosition(index)
                    withAnimation(spring) { expanded = true }
                }
                guard abs(value.translation.width) > 2 else { return }
                live = rubberBand(start - value.translation.width / slot)
                let nearest = nearest(live)
                if options[nearest].id != selection { selection = options[nearest].id }
            }
            .onEnded { value in
                dragging = false
                let moved = abs(value.translation.width) > 4
                var target: Int
                if moved {
                    target = nearest(start - value.predictedEndTranslation.width / slot)
                    // A fling never jumps the barrier on momentum alone: it stops at the edge.
                    if let split, (index < split) != (target < split) { target = index }
                } else if openedByTap {
                    return // A plain tap just opens the carousel.
                } else {
                    // Tap on a neighbour while open picks it.
                    let spot = screen(live) + (value.location.x - midX) / slot
                    target = options.indices.min { abs(screenPosition($0) - spot) < abs(screenPosition($1) - spot) } ?? index
                }
                withAnimation(spring) {
                    selection = options[target].id
                    live = dragPosition(target)
                    expanded = false
                }
            }
    }

    /// Resist past either end instead of stopping dead.
    private func rubberBand(_ value: CGFloat) -> CGFloat {
        let upper = dragPosition(options.count - 1)
        if value < 0 { return -(1 - 1 / (1 - value * 0.6)) }
        if value > upper { return upper + (1 - 1 / (1 + (value - upper) * 0.6)) }
        return value
    }
}

/// Wet, flowing paint in a soft blob of a capsule, as if it was just poured on.
struct LiquidPaint: View {
    static let colors: [Color] = [
        Color(red: 1.0, green: 0.24, blue: 0.5),   // rose
        Color(red: 1.0, green: 0.55, blue: 0.2),   // tangerine
        Color(red: 0.55, green: 0.36, blue: 1.0),  // violet
        Color(red: 0.2, green: 0.78, blue: 1.0),   // sky
        Color(red: 1.0, green: 0.82, blue: 0.25),  // yolk
    ]
    /// The same colours as components, for blending between them smoothly.
    private static let rgb: [SIMD3<Double>] = [[1.0, 0.24, 0.5], [1.0, 0.55, 0.2], [0.55, 0.36, 1.0], [0.2, 0.78, 1.0], [1.0, 0.82, 0.25]]
    static let gradient = LinearGradient(colors: [colors[0], colors[1], colors[2]], startPoint: .topLeading, endPoint: .bottomTrailing)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            MeshGradient(width: 3, height: 3, points: Self.points(t), colors: Self.mesh(t))
                .overlay {
                    // A sheen sliding along, like light on a wet coat.
                    LinearGradient(colors: [.white.opacity(0), .white.opacity(0.28), .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 40)
                        .offset(x: CGFloat(sin(t * 0.9)) * 80)
                        .blendMode(.softLight)
                }
                .clipShape(WetEdge(phase: t))
        }
    }

    private static func points(_ t: Double) -> [SIMD2<Float>] {
        func w(_ speed: Double, _ offset: Double, _ amount: Float) -> Float { Float(sin(t * speed + offset)) * amount }
        return [
            [0, 0], [0.5 + w(0.8, 0, 0.2), 0], [1, 0],
            [0, 0.5 + w(1.1, 1, 0.25)], [0.5 + w(0.7, 2, 0.3), 0.5 + w(0.9, 3, 0.3)], [1, 0.5 + w(1.3, 4, 0.25)],
            [0, 1], [0.5 + w(0.6, 5, 0.2), 1], [1, 1],
        ]
    }

    /// Each mesh point glides round the palette at its own pace, blending continuously from
    /// one colour into the next: the loop never jumps.
    private static func mesh(_ t: Double) -> [Color] {
        (0..<9).map { i in
            let speed = 0.11 + Double(i % 4) * 0.025
            let position = (Double(i) * 0.37 + t * speed).truncatingRemainder(dividingBy: 1) * Double(rgb.count)
            let a = rgb[Int(position) % rgb.count], b = rgb[(Int(position) + 1) % rgb.count]
            let f = position - position.rounded(.down)
            let eased = f * f * (3 - 2 * f)
            let c = a + (b - a) * eased
            return Color(red: c.x, green: c.y, blue: c.z)
        }
    }
}

/// A capsule whose outline swells and sinks in a few slow, soft lobes travelling round it:
/// a drop of paint holding its shape, not a ragged edge.
struct WetEdge: Shape {
    var phase: Double

    func path(in rect: CGRect) -> Path {
        let r = rect.height / 2
        let samples = 160
        var path = Path()
        let straight = max(rect.width - 2 * r, 0)
        let perimeter = 2 * straight + 2 * .pi * r
        for i in 0..<samples {
            let s = CGFloat(i) / CGFloat(samples) * perimeter
            let u = Double(s / perimeter) * 2 * .pi
            var point: CGPoint
            var normal: CGVector
            if s < straight { // top edge, left to right
                point = CGPoint(x: rect.minX + r + s, y: rect.minY); normal = CGVector(dx: 0, dy: -1)
            } else if s < straight + .pi * r { // right cap
                let a = -CGFloat.pi / 2 + (s - straight) / r
                point = CGPoint(x: rect.maxX - r + cos(a) * r, y: rect.midY + sin(a) * r); normal = CGVector(dx: cos(a), dy: sin(a))
            } else if s < 2 * straight + .pi * r { // bottom edge, right to left
                point = CGPoint(x: rect.maxX - r - (s - straight - .pi * r), y: rect.maxY); normal = CGVector(dx: 0, dy: 1)
            } else { // left cap
                let a = CGFloat.pi / 2 + (s - 2 * straight - .pi * r) / r
                point = CGPoint(x: rect.minX + r + cos(a) * r, y: rect.midY + sin(a) * r); normal = CGVector(dx: cos(a), dy: sin(a))
            }
            // Three and five lobes, drifting opposite ways: round bulges, always smooth.
            let swell = 1.7 * sin(3 * u + phase * 0.9) + 0.9 * sin(5 * u - phase * 1.3) - 1.0
            point.x += normal.dx * swell
            point.y += normal.dy * swell
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

#Preview {
    @Previewable @State var selection = ModelChoice.standard.id
    ModelSelector(options: ModelChoice.all, selection: $selection)
}

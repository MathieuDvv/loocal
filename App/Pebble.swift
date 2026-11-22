import SwiftUI

// MARK: - The errand bot

/// What the bot's face is doing.
enum BotMood: Equatable {
    case neutral, attentive, curious, excited, working, happy, sad, sleepy, waiting
}

/// Each persona gets its own body, so you can tell who's on an errand at a glance.
enum BotShape: String, CaseIterable, Hashable {
    case pebble, round, squircle, capsule, droplet, triangle

    /// Persona ids in their Settings order, kept current by the app state, so each
    /// persona gets a different body.
    @MainActor static var personaOrder: [UUID] = []
    /// Shapes and colours picked in a persona's editor.
    @MainActor static var chosen: [UUID: BotShape] = [:]
    @MainActor static var tints: [UUID: BotTint] = [:]

    /// Keeps the lookups in step with the saved personas.
    @MainActor static func sync(_ personas: [Persona]) {
        personaOrder = personas.map(\.id)
        chosen = Dictionary(uniqueKeysWithValues: personas.compactMap { p in p.shape.flatMap(BotShape.init(rawValue:)).map { (p.id, $0) } })
        tints = Dictionary(uniqueKeysWithValues: personas.compactMap { p in p.tint.flatMap(BotTint.init(rawValue:)).map { (p.id, $0) } })
    }

    /// The default bot is the pebble; a persona has the shape picked for it, or else the
    /// next one in line. A persona that's since been deleted keeps a stable shape from its id.
    @MainActor init(personaID: UUID?) {
        guard let personaID else { self = .pebble; return }
        if let picked = Self.chosen[personaID] { self = picked; return }
        let others: [BotShape] = [.round, .squircle, .capsule, .droplet, .triangle]
        let index = Self.personaOrder.firstIndex(of: personaID) ?? Int(personaID.uuid.0)
        self = others[index % others.count]
    }

    var body: AnyShape {
        switch self {
        case .pebble: AnyShape(PebbleShape())
        case .round: AnyShape(RoundBody())
        case .squircle: AnyShape(SquircleBody())
        case .capsule: AnyShape(CapsuleBody())
        case .droplet: AnyShape(DropletBody())
        case .triangle: AnyShape(RoundedTriangle(inset: -0.04, radius: 0.15))
        }
    }

    var name: String {
        switch self {
        case .pebble: "Pebble"; case .round: "Round"; case .squircle: "Squircle"
        case .capsule: "Capsule"; case .droplet: "Droplet"; case .triangle: "Triangle"
        }
    }

    /// Where the face sits, as a fraction of the size.
    var face: CGPoint {
        switch self {
        case .pebble: CGPoint(x: 0, y: 0.015)
        case .round: CGPoint(x: 0, y: 0.03)
        case .squircle: CGPoint(x: 0, y: 0.02)
        case .capsule: CGPoint(x: 0, y: 0.0)
        case .droplet: CGPoint(x: 0, y: 0.13)
        case .triangle: CGPoint(x: 0, y: 0.15)
        }
    }
}

/// The colour of a persona's errand bot. Ink is the default; the others are muted so the
/// bots still sit quietly in the monochrome app, and read in light and dark.
enum BotTint: String, CaseIterable, Hashable {
    case ink, clay, moss, sky, plum, sand

    var color: Color {
        switch self {
        case .ink: Ink.primary
        case .clay: Color(red: 0.76, green: 0.41, blue: 0.27)
        case .moss: Color(red: 0.38, green: 0.49, blue: 0.32)
        case .sky: Color(red: 0.30, green: 0.48, blue: 0.67)
        case .plum: Color(red: 0.48, green: 0.32, blue: 0.52)
        case .sand: Color(red: 0.72, green: 0.59, blue: 0.37)
        }
    }

    var name: String { rawValue.capitalized }

    /// A persona's bot colour, or nil for plain ink.
    @MainActor static func color(for personaID: UUID?) -> Color? {
        personaID.flatMap { BotShape.tints[$0] }.flatMap { $0 == .ink ? nil : $0.color }
    }
}

/// A triangle with soft, rounded corners, point up. `inset` and `radius` are fractions of
/// the width.
struct RoundedTriangle: Shape {
    var inset: CGFloat = 0
    var radius: CGFloat = 0.18
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let top = CGPoint(x: rect.midX, y: rect.minY + h * (inset + 0.04))
        let right = CGPoint(x: rect.maxX - w * inset, y: rect.maxY - h * (inset + 0.06))
        let left = CGPoint(x: rect.minX + w * inset, y: rect.maxY - h * (inset + 0.06))
        let r = w * radius
        var path = Path()
        path.move(to: CGPoint(x: (left.x + right.x) / 2, y: left.y))
        path.addArc(tangent1End: right, tangent2End: top, radius: r)
        path.addArc(tangent1End: top, tangent2End: left, radius: r)
        path.addArc(tangent1End: left, tangent2End: right, radius: r)
        path.closeSubpath()
        return path
    }
}

private struct RoundBody: Shape {
    func path(in rect: CGRect) -> Path {
        Path(ellipseIn: CGRect(x: rect.minX + rect.width * 0.07, y: rect.minY + rect.height * 0.1, width: rect.width * 0.86, height: rect.height * 0.8))
    }
}

private struct SquircleBody: Shape {
    func path(in rect: CGRect) -> Path {
        let inset = CGRect(x: rect.minX + rect.width * 0.1, y: rect.minY + rect.height * 0.12, width: rect.width * 0.8, height: rect.height * 0.76)
        return Path(roundedRect: inset, cornerRadius: rect.width * 0.3, style: .continuous)
    }
}

private struct CapsuleBody: Shape {
    func path(in rect: CGRect) -> Path {
        let band = CGRect(x: rect.minX + rect.width * 0.02, y: rect.minY + rect.height * 0.23, width: rect.width * 0.96, height: rect.height * 0.54)
        return Path(roundedRect: band, cornerRadius: band.height / 2, style: .continuous)
    }
}

private struct DropletBody: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        var path = Path()
        path.move(to: p(0.5, 0.03))
        path.addCurve(to: p(0.88, 0.6), control1: p(0.6, 0.2), control2: p(0.88, 0.36))
        path.addCurve(to: p(0.5, 0.95), control1: p(0.88, 0.82), control2: p(0.71, 0.95))
        path.addCurve(to: p(0.12, 0.6), control1: p(0.29, 0.95), control2: p(0.12, 0.82))
        path.addCurve(to: p(0.5, 0.03), control1: p(0.12, 0.36), control2: p(0.4, 0.2))
        path.closeSubpath()
        return path
    }
}

/// A tilted ink pebble, the body of the errand bot. Drawn in a unit square.
struct PebbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        var path = Path()
        // Wider than tall, sitting a little lower on the left: a river stone at rest.
        path.move(to: p(0.03, 0.59))
        path.addCurve(to: p(0.45, 0.14), control1: p(0.01, 0.33), control2: p(0.21, 0.15))
        path.addCurve(to: p(0.97, 0.44), control1: p(0.71, 0.13), control2: p(0.97, 0.23))
        path.addCurve(to: p(0.55, 0.87), control1: p(0.97, 0.67), control2: p(0.79, 0.87))
        path.addCurve(to: p(0.03, 0.59), control1: p(0.29, 0.87), control2: p(0.05, 0.82))
        path.closeSubpath()
        return path
    }
}

/// A shallow arc for closed eyes: ^ when happy, ‿ when sleepy.
private struct EyeArc: Shape {
    var up: Bool
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let top = up ? rect.minY : rect.maxY
        let bottom = up ? rect.maxY : rect.minY
        path.move(to: CGPoint(x: rect.minX, y: bottom))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: bottom), control: CGPoint(x: rect.midX, y: top - (bottom - top) * 0.9))
        return path
    }
}

/// The errand bot: a glossy pebble with two pill eyes that blink, glance around, follow
/// what you type and change with its mood. Ink on paper, so it flips with dark mode.
struct PebbleBot: View {
    var mood: BotMood = .neutral
    var shape: BotShape = .pebble
    var size: CGFloat = 120
    /// Where it looks, -1…1 on each axis. `nil` lets it glance around on its own.
    var gaze: CGPoint? = nil
    /// Idle life: breathing, blinking, glancing. Off for tiny list icons.
    var lively = true
    /// Bump to make it hop.
    var reaction = 0
    /// Body colour; ink when nil.
    var tint: Color? = nil

    @State private var blink = false
    @State private var glance: CGPoint = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !lively || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let breathe = lively && !reduceMotion ? sin(t * 1.7) : 0
            let look = currentGaze(t)
            ZStack {
                figure(look: look)
            }
            .scaleEffect(x: 1 - breathe * 0.008, y: 1 + breathe * 0.014, anchor: .bottom)
            .offset(y: -breathe * size * 0.012)
            .rotationEffect(.degrees(look.x * 4))
        }
        .frame(width: size, height: size)
        .keyframeAnimator(initialValue: Hop(), trigger: reaction) { content, hop in
            content
                .scaleEffect(x: hop.squash, y: 2 - hop.squash, anchor: .bottom)
                .offset(y: hop.lift * size)
        } keyframes: { _ in
            KeyframeTrack(\.squash) {
                SpringKeyframe(1.14, duration: 0.1)
                SpringKeyframe(0.92, duration: 0.18)
                SpringKeyframe(1.04, duration: 0.16)
                SpringKeyframe(1, duration: 0.3)
            }
            KeyframeTrack(\.lift) {
                LinearKeyframe(0, duration: 0.1)
                SpringKeyframe(-0.16, duration: 0.2)
                SpringKeyframe(0, duration: 0.34)
            }
        }
        .task(id: lively) { await live() }
        .accessibilityHidden(true)
    }

    private struct Hop { var squash: CGFloat = 1; var lift: CGFloat = 0 }

    private func currentGaze(_ t: TimeInterval) -> CGPoint {
        if mood == .working && !reduceMotion {
            // Reading something: the eyes sweep across a line, then hop back.
            let sweep = (t * 0.9).truncatingRemainder(dividingBy: 1)
            return CGPoint(x: -0.7 + sweep * 1.4, y: 0.25)
        }
        return gaze ?? glance
    }

    private func figure(look: CGPoint) -> some View {
        ZStack {
            shape.body.fill(tint ?? Ink.primary)
            // Clay gloss: a soft light from the top left, a little weight bottom right.
            shape.body.fill(
                LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0), .black.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            Ellipse()
                .fill(.white.opacity(0.22))
                .frame(width: size * 0.26, height: size * 0.12)
                .blur(radius: size * 0.04)
                .rotationEffect(.degrees(-28))
                .offset(x: -size * 0.2, y: -size * 0.2)
                .mask(shape.body)
            eyes
                .offset(x: look.x * size * 0.075, y: look.y * size * (shape == .capsule ? 0.035 : 0.06))
                .offset(x: size * shape.face.x, y: size * shape.face.y)
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: look)
    }

    // MARK: Eyes

    private struct EyeSpec: Equatable {
        enum Kind { case pill, happy, closed }
        var kind: Kind = .pill
        var width: CGFloat
        var height: CGFloat
        var tilt: Double = 0
    }

    private func spec(left: Bool) -> EyeSpec {
        switch mood {
        case .neutral: EyeSpec(width: 0.085, height: 0.19)
        case .attentive: EyeSpec(width: 0.085, height: 0.16)
        case .curious: left ? EyeSpec(width: 0.085, height: 0.19) : EyeSpec(width: 0.09, height: 0.12)
        case .excited: EyeSpec(width: 0.135, height: 0.145)
        case .working: EyeSpec(width: 0.11, height: 0.075)
        case .happy: EyeSpec(kind: .happy, width: 0.13, height: 0.07)
        case .sad: EyeSpec(width: 0.08, height: 0.13, tilt: left ? 22 : -22)
        case .sleepy: EyeSpec(kind: .closed, width: 0.12, height: 0.05)
        case .waiting: EyeSpec(width: 0.085, height: 0.12)
        }
    }

    private var eyes: some View {
        HStack(spacing: size * 0.12) {
            eye(spec(left: true))
            eye(spec(left: false))
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.7), value: mood)
    }

    private func eye(_ spec: EyeSpec) -> some View {
        let closed = blink && spec.kind == .pill
        return ZStack {
            Capsule()
                .fill(Ink.paper)
                .frame(width: size * spec.width, height: size * spec.height * (closed ? 0.12 : 1))
                .rotationEffect(.degrees(spec.tilt))
                .opacity(spec.kind == .pill ? 1 : 0)
            EyeArc(up: spec.kind == .happy)
                .stroke(Ink.paper, style: StrokeStyle(lineWidth: size * 0.045, lineCap: .round))
                .frame(width: size * spec.width, height: size * spec.height)
                .opacity(spec.kind == .pill ? 0 : 1)
        }
        .frame(width: size * 0.14, height: size * 0.2)
        .animation(.easeOut(duration: 0.07), value: blink)
    }

    // MARK: Idle life

    private func live() async {
        guard lively, !reduceMotion else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 2.2...4.8)))
            guard !Task.isCancelled else { return }
            if mood != .sleepy && mood != .happy {
                blink = true
                try? await Task.sleep(for: .milliseconds(110))
                blink = false
                if Bool.random() && Int.random(in: 0..<4) == 0 {
                    try? await Task.sleep(for: .milliseconds(140))
                    blink = true
                    try? await Task.sleep(for: .milliseconds(100))
                    blink = false
                }
            }
            if gaze == nil && Int.random(in: 0..<3) == 0 {
                glance = Int.random(in: 0..<3) == 0 ? .zero : CGPoint(x: .random(in: -0.8...0.8), y: .random(in: -0.4...0.5))
            }
        }
    }
}

extension ErrandRun {
    /// How a run's little bot looks in lists and the crew.
    var mood: BotMood {
        switch status {
        case .queued: stage == ErrandRun.nextUp ? .waiting : .curious
        case .running: .working
        case .done: .happy
        case .failed: .sad
        case .stopped: .sleepy
        }
    }
}

// MARK: - Custom tab glyphs

/// Drawn icons for the Errands set, in the weight of the SF Symbols beside them.
struct TabGlyph: View {
    let tab: AppTab
    let selected: Bool

    var body: some View {
        Group {
            switch tab {
            case .results: ResultsGlyph(selected: selected)
            case .errand: BotGlyph(selected: selected)
            case .routines: RoutineGlyph(selected: selected)
            case .history: HistoryGlyph(selected: selected)
            case .chat: ChatGlyph(selected: selected)
            case .settings: GearGlyph(selected: selected)
            }
        }
        .foregroundStyle(selected ? Ink.primary : Ink.tertiary)
    }
}

/// A little pop when a drawn glyph is picked, like the symbols' bounce.
private struct GlyphPop: ViewModifier {
    let selected: Bool
    @State private var pops = 0
    func body(content: Content) -> some View {
        content
            .keyframeAnimator(initialValue: CGFloat(1), trigger: pops) { view, scale in
                view.scaleEffect(scale)
            } keyframes: { _ in
                SpringKeyframe(0.82, duration: 0.1)
                SpringKeyframe(1, duration: 0.35, spring: .bouncy)
            }
            .onChange(of: selected) { _, now in if now { pops += 1 } }
    }
}

/// New errand: the bot's face. Picked, the pebble fills in and the eyes cut through.
private struct BotGlyph: View {
    let selected: Bool
    var body: some View {
        ZStack {
            if selected {
                PebbleShape().fill(.foreground)
            } else {
                PebbleShape().stroke(.foreground, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
            }
            HStack(spacing: 3.2) {
                Capsule().frame(width: 2.4, height: 5.4)
                Capsule().frame(width: 2.4, height: 5.4)
            }
            .offset(x: 0.9, y: 0.6)
            .blendMode(selected ? .destinationOut : .normal)
        }
        .compositingGroup()
        .frame(width: 22, height: 21)
        .modifier(GlyphPop(selected: selected))
    }
}

/// Results: a delivered card with a tick.
private struct ResultsGlyph: View {
    let selected: Bool
    var body: some View {
        ZStack {
            if selected {
                RoundedRectangle(cornerRadius: 6.5, style: .continuous).fill(.foreground)
            } else {
                RoundedRectangle(cornerRadius: 6.5, style: .continuous).stroke(.foreground, lineWidth: 1.6)
            }
            Tick()
                .stroke(.foreground, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                .frame(width: 8.5, height: 6)
                .offset(y: 0.5)
                .blendMode(selected ? .destinationOut : .normal)
        }
        .compositingGroup()
        .frame(width: 19, height: 20)
        .rotationEffect(.degrees(selected ? -6 : 0))
        .animation(.spring(response: 0.45, dampingFraction: 0.65), value: selected)
        .frame(width: 24, height: 24)
        .modifier(GlyphPop(selected: selected))
    }

    private struct Tick: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            return path
        }
    }
}

/// Routines: a soft triangle as a clock face. Picked, it fills in and the hands cut
/// through and tick forward.
private struct RoutineGlyph: View {
    let selected: Bool
    var body: some View {
        ZStack {
            if selected {
                RoundedTriangle(inset: -0.04, radius: 0.24).fill(.foreground)
            } else {
                RoundedTriangle(inset: -0.04, radius: 0.24).stroke(.foreground, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
            }
            // The hands turn about the triangle's centre, which sits low.
            ClockHands(minute: selected ? 360 : 0, hour: 4.4, length: 4)
                .stroke(.foreground, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                .frame(width: 25, height: 24)
                .offset(y: 3.2)
                .blendMode(selected ? .destinationOut : .normal)
        }
        .compositingGroup()
        .frame(width: 25, height: 24)
        .animation(.spring(response: 0.9, dampingFraction: 0.8), value: selected)
        .modifier(GlyphPop(selected: selected))
    }
}

/// History: a round clock whose hands tick forward when picked, like Routines.
private struct HistoryGlyph: View {
    let selected: Bool
    var body: some View {
        ZStack {
            if selected {
                Circle().fill(.foreground)
            } else {
                Circle().stroke(.foreground, lineWidth: 1.6)
            }
            ClockHands(minute: selected ? 360 : 0, hour: 5, length: 4.2)
                .stroke(.foreground, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                .blendMode(selected ? .destinationOut : .normal)
        }
        .compositingGroup()
        .frame(width: 20, height: 20)
        .animation(.spring(response: 0.9, dampingFraction: 0.8), value: selected)
        .frame(width: 24, height: 24)
        .modifier(GlyphPop(selected: selected))
    }
}

/// Chat: a speech bubble that, picked, fills in and pops up into place like a text
/// that was just sent: it rises from below, small, and settles with a little overshoot.
private struct ChatGlyph: View {
    let selected: Bool
    @State private var sends = 0

    private struct Send { var scale: CGFloat = 1; var rise: CGFloat = 0 }

    var body: some View {
        Image(systemName: selected ? "bubble.fill" : "bubble")
            .font(.system(size: 19, weight: .regular))
            .contentTransition(.opacity)
            .keyframeAnimator(initialValue: Send(), trigger: sends) { content, send in
                content
                    .scaleEffect(send.scale, anchor: .bottomLeading)
                    .offset(y: send.rise)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    LinearKeyframe(0.35, duration: 0.01)
                    SpringKeyframe(1.08, duration: 0.22, spring: .snappy)
                    SpringKeyframe(1, duration: 0.35, spring: .smooth)
                }
                KeyframeTrack(\.rise) {
                    LinearKeyframe(7, duration: 0.01)
                    SpringKeyframe(-1, duration: 0.24, spring: .snappy)
                    SpringKeyframe(0, duration: 0.35, spring: .smooth)
                }
            }
            .onChange(of: selected) { _, now in if now { sends += 1 } }
    }
}

/// Settings: the gear fills in and turns an eighth when picked, settling like a dial.
private struct GearGlyph: View {
    let selected: Bool
    @State private var turns = 0.0
    var body: some View {
        Image(systemName: selected ? "gearshape.fill" : "gearshape")
            .font(.system(size: 19, weight: .regular))
            .contentTransition(.opacity)
            .rotationEffect(.degrees(turns * 90))
            .animation(.spring(response: 0.7, dampingFraction: 0.62), value: turns)
            .onChange(of: selected) { _, now in if now { turns += 1 } }
            .modifier(GlyphPop(selected: selected))
    }
}

/// Two hands from the centre: the hour hand up, the minute hand at `minute` degrees.
private struct ClockHands: Shape {
    var minute: Double
    var hour: CGFloat = 4.6
    var length: CGFloat = 3.8
    var animatableData: Double { get { minute } set { minute = newValue } }
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.move(to: CGPoint(x: c.x, y: c.y - hour))
        path.addLine(to: c)
        let angle = Angle.degrees(minute).radians
        path.addLine(to: CGPoint(x: c.x + length * cos(angle), y: c.y + length * sin(angle)))
        return path
    }
}

#Preview("Moods") {
    let moods: [BotMood] = [.neutral, .attentive, .curious, .excited, .working, .happy, .sad, .sleepy, .waiting]
    LazyVGrid(columns: [GridItem(), GridItem(), GridItem()]) {
        ForEach(Array(moods.enumerated()), id: \.offset) { _, mood in PebbleBot(mood: mood, size: 90) }
    }
    .padding()
}

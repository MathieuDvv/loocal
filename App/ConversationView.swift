import SwiftUI

/// Full-screen voice conversation: the Tide swell with handwritten captions, driven by the
/// live pipeline (or the scripted mock in the simulator demo).
struct ConversationView: View {
    /// Live pipeline in normal use; the scripted mock in the simulator demo.
    @State private var mock: any ConversationSource
    @State private var appeared = false
    @Environment(\.dismiss) private var dismiss

    init(source: any ConversationSource) {
        _mock = State(initialValue: source)
    }

    var body: some View {
        ZStack {
            Ink.paper.ignoresSafeArea()
            TideConversation(mock: mock)
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : 0.96)
            .animation(.spring(response: 0.6, dampingFraction: 0.85).delay(0.1), value: appeared)
        }
        .safeAreaInset(edge: .top, spacing: 0) { status }
        .safeAreaInset(edge: .bottom, spacing: 0) { controls }
        .onAppear { appeared = true; mock.start() }
        .onDisappear { mock.stop() }
        .sensoryFeedback(.impact(weight: .light), trigger: mock.phase)
        .statusBarHidden()
    }

    private var status: some View {
        HStack(spacing: 8) {
            Circle().fill(mock.phase == .listening && !mock.muted ? Ink.primary : Ink.tertiary)
                .frame(width: 6, height: 6)
                .scaleEffect(mock.phase == .listening ? 1.3 : 1)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: mock.phase == .listening)
            Text(statusText)
                .font(.geist(14, .medium)).foregroundStyle(Ink.secondary)
                .contentTransition(.opacity)
        }
        .animation(.smooth(duration: 0.3), value: mock.phase)
        .animation(.smooth(duration: 0.3), value: mock.muted)
        .padding(.top, 14)
        .frame(maxWidth: .infinity)
    }

    private var statusText: String {
        if mock.muted && mock.phase == .listening { return "Muted" }
        switch mock.phase {
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        }
    }

    /// Over the tide the controls invert: they sit on ink, not paper.
    private let onInk = true

    private var controls: some View {
        HStack(spacing: 28) {
            Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { mock.muted.toggle() } } label: {
                Image(systemName: mock.muted ? "mic.slash" : "mic")
                    .font(.system(size: 20))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(mock.muted != onInk ? Ink.paper : Ink.primary)
                    .frame(width: 60, height: 60)
                    .background(onInk ? (mock.muted ? Ink.paper : Ink.paper.opacity(0.14)) : (mock.muted ? Ink.primary : Ink.fill), in: .circle)
            }
            .buttonStyle(PressStyle(scale: 0.9))
            .accessibilityLabel(mock.muted ? "Unmute" : "Mute")
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(onInk ? Ink.primary : Ink.paper)
                    .frame(width: 60, height: 60)
                    .background(onInk ? Ink.paper : Ink.primary, in: .circle)
            }
            .buttonStyle(PressStyle(scale: 0.9))
            .accessibilityLabel("End conversation")
        }
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity)
        .sensoryFeedback(.selection, trigger: mock.muted)
    }
}

/// Handwritten caption thread: you on the right in italic, the model on the left.
private struct CaptionThread: View {
    let mock: any ConversationSource

    var body: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 18) {
                        ForEach(mock.lines) { line in
                            HandwrittenText(text: AttributedString(line.text.isEmpty ? " " : line.text), live: line.id == mock.current?.id)
                                .font(line.fromUser ? .serif(24, italic: true) : .serif(26))
                                .foregroundStyle(line.fromUser ? Ink.secondary : Ink.primary)
                                .multilineTextAlignment(line.fromUser ? .trailing : .leading)
                                .frame(maxWidth: .infinity, alignment: line.fromUser ? .trailing : .leading)
                                .padding(line.fromUser ? .leading : .trailing, 40)
                                .opacity(line.id == mock.current?.id ? 1 : 0.45)
                                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 20)), removal: .opacity))
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, 24).padding(.top, 40)
                    .animation(.spring(response: 0.5, dampingFraction: 0.85), value: mock.lines.map(\.id))
                }
                .scrollIndicators(.hidden)
                .defaultScrollAnchor(.bottom)
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.25), .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom))
                .onChange(of: mock.current?.text) { _, _ in if let id = mock.current?.id { proxy.scrollTo(id, anchor: .bottom) } }
            }
    }
}

// MARK: - Tide

/// A liquid ink swell rising from the bottom edge, behind the controls. It heaves with the
/// voice, settles low and breathes while thinking. Captions write themselves above it.
private struct TideConversation: View {
    let mock: any ConversationSource

    var body: some View {
        ZStack(alignment: .bottom) {
            TideSwell(mock: mock)
                .frame(height: 340)
                .ignoresSafeArea(edges: .bottom)
                .offset(y: 120) // sits under the bottom safe area and the controls
            VStack(spacing: 0) {
                CaptionThread(mock: mock)
                Color.clear.frame(height: 170)
            }
        }
    }
}

private struct TideSwell: View {
    let mock: any ConversationSource

    var body: some View {
        TimelineView(.animation) { timeline in
            let date = timeline.date
            let t = date.timeIntervalSinceReferenceDate
            let thinking = mock.phase == .thinking
            let level = thinking ? 0.1 + 0.05 * sin(t * 2.2) : mock.level(at: date)
            Canvas { context, size in
                let w = size.width, h = size.height
                let crest = h * (0.42 - 0.26 * level)          // top of the swell; higher when loud
                var path = Path()
                path.move(to: CGPoint(x: 0, y: h))
                let steps = 90
                for k in 0...steps {
                    let u = Double(k) / Double(steps)
                    let dome = sin(u * .pi)                       // rises toward the middle
                    let swell = (5 + 20 * level) * sin(u * 2 * .pi * 1.4 + t * 2.3)
                        + (3 + 12 * level) * sin(u * 2 * .pi * 3.2 - t * 3.4)
                        + 2.5 * sin(u * 2 * .pi * 0.7 + t * 0.9)
                    let y = h - (h - crest) * (0.5 + 0.5 * dome) + swell
                    path.addLine(to: CGPoint(x: w * u, y: y))
                }
                path.addLine(to: CGPoint(x: w, y: h))
                path.closeSubpath()
                // Soft glow above the surface, brighter with the voice.
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: 34))
                    layer.opacity = 0.16 + 0.32 * level
                    layer.fill(path.offsetBy(dx: 0, dy: -22), with: .color(Ink.primary))
                }
                context.fill(path, with: .color(Ink.primary))
            }
            .overlay(alignment: .top) {
                if thinking {
                    SpiralLoader(size: 40, color: Ink.paper)
                        .padding(.top, 168) // inside the ink, above the controls
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.8), value: thinking)
        }
    }
}

#Preview { ConversationView(source: ConversationMock()) }

import SwiftUI

/// Send button that doubles as the persona switcher, in the same visual language as the
/// model selector: one capsule that only grows sideways.
///
/// Tap: send. Press and hold: a capsule unrolls leftward out of the button with the persona
/// icons in a row. Slide along it and an ink circle glides under the icon you're on; release
/// to pick it. Releasing on the button itself leaves the capsule open for a tap.
struct SendControl: View {
    @Bindable var store: AppState
    /// Owned by the composer so only one tray (this or +) is open at a time.
    @Binding var open: Bool
    let canSend: Bool
    let send: () -> Void
    let addPersona: () -> Void

    @State private var openedThisPress = false
    @State private var pressing = false
    @State private var highlighted: Int?
    @State private var hold: DispatchWorkItem?
    @State private var center: CGPoint = .zero
    @State private var sendTaps = 0
    @State private var picks = 0

    private enum Item: Hashable { case none, persona(Persona), add }
    private var items: [Item] {
        [.none] + store.personas.map { .persona($0) } + (store.personas.count < Persona.limit ? [.add] : [])
    }
    /// Icon spacing; tightens when many icons must fit the composer width.
    private var slot: CGFloat { min(42, 246 / CGFloat(max(items.count, 1))) } // fits beside the other composer buttons
    private let size: CGFloat = 38
    private let spring = Animation.spring(response: 0.32, dampingFraction: 0.8)
    /// How long a still finger must rest before the capsule opens.
    /// Uses a precise main-queue timer: `Task.sleep` may be coalesced and fire late.
    private let holdDelay: DispatchTimeInterval = .milliseconds(180)

    /// Offset of item `i` from the button's centre (items run right to left).
    private func dx(_ i: Int) -> CGFloat { -slot * CGFloat(i + 1) - 6 }
    private var trayWidth: CGFloat { open ? slot * CGFloat(items.count) + size + 18 : size }
    /// The ink circle rests on the active persona and follows the finger while dragging.
    private var marker: Int? { highlighted ?? (pressing ? nil : items.firstIndex(where: isActive)) }

    var body: some View {
        ZStack {
            tray
            button
        }
        .frame(width: size, height: size)
        .onGeometryChange(for: CGPoint.self) { proxy in
            let frame = proxy.frame(in: .global)
            return CGPoint(x: frame.midX, y: frame.midY)
        } action: { center = $0 }
        // While open, the control's own frame grows to cover the capsule: SwiftUI only
        // delivers a gesture inside its view's frame, so taps on the icons need this.
        .frame(width: open ? trayWidth - 4 : size, height: size, alignment: .trailing)
        .contentShape(.rect)
        .highPriorityGesture(press)
        .sensoryFeedback(.impact(weight: .medium), trigger: sendTaps)
        .sensoryFeedback(.impact(weight: .light), trigger: open) { _, now in now }
        .sensoryFeedback(.selection, trigger: highlighted) { _, now in now != nil }
        .sensoryFeedback(.success, trigger: picks)
        .task(id: open && !pressing) {
            // Left open by a plain hold, the capsule folds away if ignored.
            guard open && !pressing else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled && !pressing { close() }
        }
        .accessibilityElement()
        .accessibilityLabel("Send message")
        .accessibilityValue(canSend ? "Ready" : "Unavailable")
        .accessibilityHint("Hold to choose a persona")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if canSend { sendTaps += 1; send() } }
        .accessibilityActions {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Button(label(item)) { choose(item) }
            }
        }
        .accessibilityIdentifier("send")
    }

    // MARK: Pieces

    private var button: some View {
        Image(systemName: open ? "xmark" : "arrow.up")
            .font(.system(size: open ? 13 : 16, weight: .semibold))
            .contentTransition(.symbolEffect(.replace))
            .foregroundStyle(open ? Ink.secondary : (canSend ? Ink.paper : Ink.tertiary))
            .symbolEffect(.bounce.up, value: sendTaps)
            .frame(width: size, height: size)
            .background(open ? Ink.fill : (canSend ? Ink.primary : Ink.hairline), in: .circle)
            .scaleEffect(pressing && !open ? 0.9 : (canSend || open ? 1 : 0.92))
            .animation(.spring(response: 0.3, dampingFraction: 0.65), value: pressing)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: canSend)
            .animation(spring, value: open)
    }

    private var tray: some View {
        ZStack {
            Capsule()
                .fill(Ink.paper)
                .overlay(Capsule().stroke(Ink.hairline))
                .shadow(color: .black.opacity(open ? 0.10 : 0), radius: 14, y: 5)
                .frame(width: trayWidth, height: open ? 46 : size)
                .offset(x: size / 2 + (open ? 4 : 0) - trayWidth / 2)
                .opacity(open ? 1 : 0)

            if let marker {
                Circle().fill(Ink.primary)
                    .frame(width: min(36, slot - 4), height: min(36, slot - 4))
                    .offset(x: open ? dx(marker) : 0)
                    .opacity(open ? 1 : 0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.72), value: marker)
            }

            ForEach(Array(items.enumerated()), id: \.element) { i, item in
                let lit = marker == i && open
                icon(item, lit: lit)
                    .foregroundStyle(lit ? Ink.paper : Ink.primary)
                    .frame(width: min(36, slot - 4), height: min(36, slot - 4))
                    .scaleEffect(open ? (highlighted == i ? 1.08 : 1) : 0.4)
                    .opacity(open ? 1 : 0)
                    .blur(radius: open ? 0 : 3)
                    .offset(x: open ? dx(i) : 0)
                    .animation(spring.delay(open ? Double(i) * 0.02 : 0), value: open)
                    .animation(.spring(response: 0.25, dampingFraction: 0.6), value: lit)
            }
        }
        .allowsHitTesting(false)
        .animation(spring, value: open)
        .animation(spring, value: items.count)
        // Invisible hit area matching the open capsule, so taps on it reach the gesture.
        .background {
            Color.clear
                .frame(width: trayWidth, height: 46)
                .offset(x: size / 2 + 4 - trayWidth / 2)
                .contentShape(.rect)
                .allowsHitTesting(open)
        }
    }

    @ViewBuilder private func icon(_ item: Item, lit: Bool) -> some View {
        switch item {
        case .none: LoopMark(color: lit ? Ink.paper : Ink.primary).frame(width: 18)
        case .persona(let persona): Image(systemName: persona.icon).font(.system(size: 15, weight: .regular))
        case .add: Image(systemName: "plus").font(.system(size: 15, weight: .regular)).foregroundStyle(lit ? Ink.paper : Ink.secondary)
        }
    }

    // MARK: Gesture

    private var press: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if !pressing {
                    pressing = true
                    openedThisPress = false
                    if !open {
                        let item = DispatchWorkItem { if pressing && !open { reveal() } }
                        hold = item
                        DispatchQueue.main.asyncAfter(deadline: .now() + holdDelay, execute: item)
                    }
                }
                // Sliding left opens at once, without waiting for the hold.
                if !open && value.translation.width < -10 { hold?.cancel(); reveal() }
                if open { highlighted = hit(value.location) }
            }
            .onEnded { value in
                hold?.cancel()
                pressing = false
                if open {
                    if let index = hit(value.location) { choose(items[index]) }
                    else if !openedThisPress { close() } // tapped the ✕ or away from the icons
                    highlighted = nil
                } else if canSend {
                    sendTaps += 1
                    send()
                }
            }
    }

    private func hit(_ point: CGPoint) -> Int? {
        guard abs(point.y - center.y) < 48 else { return nil }
        let offset = point.x - center.x
        let index = items.indices.min { abs(dx($0) - offset) < abs(dx($1) - offset) }
        guard let index, abs(dx(index) - offset) < slot / 2 + (index == items.count - 1 ? 14 : 0) else { return nil }
        return index
    }

    private func choose(_ item: Item) {
        switch item {
        case .none: store.personaID = nil
        case .persona(let persona): store.personaID = persona.id
        case .add: addPersona()
        }
        if item != .add { picks += 1 }
        close()
    }

    private func reveal() {
        openedThisPress = true
        withAnimation(spring) { open = true }
    }

    private func close() {
        highlighted = nil
        withAnimation(spring) { open = false }
    }

    private func isActive(_ item: Item) -> Bool {
        switch item {
        case .none: store.persona == nil // also covers a deleted persona
        case .persona(let persona): store.personaID == persona.id
        case .add: false
        }
    }

    private func label(_ item: Item) -> String {
        switch item {
        case .none: "No persona"
        case .persona(let persona): "Persona: \(persona.name)"
        case .add: "Add a persona"
        }
    }
}

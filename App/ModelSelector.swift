import SwiftUI
import UIKit

/// Centered model picker. At rest it's a capsule hugging the current name. Press and drag
/// sideways and it widens (height never changes) into a carousel of model names that
/// follows your finger and snaps to the nearest one, ticking as each name passes centre.
struct ModelSelector: View {
    let options: [ModelChoice]
    var disabled = false
    @Binding var selection: String
    var dimmed = false

    @State private var expanded = false
    @State private var dragging = false
    @State private var live: CGFloat = 0     // fractional index under the centre
    @State private var start: CGFloat = 0
    @State private var openedByTap = false
    @State private var midX: CGFloat = 0     // centre in screen space, for tap-to-pick

    private let slot: CGFloat = 124
    private let height: CGFloat = 38
    private let expandedWidth: CGFloat = 300
    private let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)

    private var index: Int { options.firstIndex { $0.id == selection } ?? 0 }
    private var collapsedWidth: CGFloat {
        let font = UIFont(name: "Geist-Medium", size: 15) ?? .systemFont(ofSize: 15, weight: .medium)
        let name = options.indices.contains(index) ? options[index].name : ""
        return ceil((name as NSString).size(withAttributes: [.font: font]).width) + 34
    }

    var body: some View {
        let width = expanded ? expandedWidth : collapsedWidth
        ZStack {
            ForEach(Array(options.enumerated()), id: \.element.id) { i, option in
                let distance = abs(CGFloat(i) - live)
                Text(option.name)
                    .font(.geist(15, distance < 0.5 ? .medium : .regular))
                    .foregroundStyle(distance < 0.5 ? (dimmed ? Ink.secondary : Ink.primary) : Ink.tertiary)
                    .lineLimit(1).fixedSize()
                    .scaleEffect(1 - min(distance, 2) * 0.07)
                    .opacity(expanded ? max(0, 1 - distance * 0.42) : (distance < 0.5 ? 1 : 0))
                    .offset(x: (CGFloat(i) - live) * slot)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: height)
        .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: expanded ? 0.2 : 0), .init(color: .black, location: expanded ? 0.8 : 1), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing)
        }
        .background(Capsule().fill(Ink.fill))
        .overlay(Capsule().stroke(Ink.hairline.opacity(expanded ? 1 : 0)))
        .scaleEffect(dragging ? 1.02 : 1)
        .shadow(color: .black.opacity(expanded ? 0.08 : 0), radius: 12, y: 4)
        .contentShape(.capsule)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midX } action: { midX = $0 }
        .gesture(drag, isEnabled: !disabled)
        .opacity(disabled ? 0.5 : 1)
        .sensoryFeedback(.selection, trigger: selection)
        .sensoryFeedback(.impact(weight: .light), trigger: expanded) { _, now in now }
        .onAppear { live = CGFloat(index) }
        .onChange(of: selection) { _, _ in if !dragging { withAnimation(spring) { live = CGFloat(index) } } }
        .task(id: expanded && !dragging) {
            // A tap-opened carousel closes itself after a moment of no interaction.
            guard expanded && !dragging else { return }
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled && !dragging { withAnimation(spring) { expanded = false } }
        }
        .accessibilityElement()
        .accessibilityLabel("Model")
        .accessibilityValue(options.indices.contains(index) ? options[index].name : "")
        .accessibilityAdjustableAction { direction in
            let next = direction == .increment ? index + 1 : index - 1
            if options.indices.contains(next) { selection = options[next].id }
        }
        .accessibilityIdentifier("modelSelector")
    }

    /// Measured in screen space: the capsule widens mid-gesture, which would otherwise
    /// shift local coordinates under the finger and swallow most of the drag.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if !dragging {
                    dragging = true
                    openedByTap = !expanded
                    start = CGFloat(index)
                    withAnimation(spring) { expanded = true }
                }
                guard abs(value.translation.width) > 2 else { return }
                live = rubberBand(start - value.translation.width / slot)
                let nearest = Int(live.rounded())
                if options.indices.contains(nearest), options[nearest].id != selection { selection = options[nearest].id }
            }
            .onEnded { value in
                dragging = false
                let moved = abs(value.translation.width) > 4
                var target: Int
                if moved {
                    target = Int((start - value.predictedEndTranslation.width / slot).rounded())
                } else if openedByTap {
                    return // A plain tap just opens the carousel.
                } else {
                    // Tap on a neighbour while open picks it.
                    target = Int((live + (value.location.x - midX) / slot).rounded())
                }
                target = min(max(target, 0), options.count - 1)
                withAnimation(spring) {
                    selection = options[target].id
                    live = CGFloat(target)
                    expanded = false
                }
            }
    }

    /// Resist past either end instead of stopping dead.
    private func rubberBand(_ value: CGFloat) -> CGFloat {
        let upper = CGFloat(options.count - 1)
        if value < 0 { return -(1 - 1 / (1 - value * 0.6)) }
        if value > upper { return upper + (1 - 1 / (1 + (value - upper) * 0.6)) }
        return value
    }
}

#Preview {
    @Previewable @State var selection = ModelChoice.standard.id
    ModelSelector(options: ModelChoice.all, selection: $selection)
}

import Foundation
import Observation

/// Scripted stand-in for a live voice conversation, so the conversation-mode prototypes can
/// be judged in the simulator: no microphone, no speech, no model. It walks through
/// listening → thinking → speaking with word-by-word transcripts and a fake voice level.
@MainActor @Observable
final class ConversationMock: ConversationSource {
    private(set) var phase: ConversationPhase = .listening
    private(set) var lines: [ConversationLine] = []
    var muted = false
    /// When the last word arrived; drives the voice envelope.
    @ObservationIgnored private(set) var lastWord = Date.distantPast
    @ObservationIgnored private var task: Task<Void, Never>?

    private let script: [(user: String, reply: String)] = [
        ("What should I cook tonight with leeks, eggs and some old bread?", "A leek and bread strata. Soften the leeks in butter, layer them with torn bread, pour over beaten eggs and milk, and bake until puffed and golden."),
        ("How long in the oven?", "About forty minutes at one eighty. It's done when the middle no longer wobbles."),
        ("Nice. Can you remind me to buy cheese?", "I can't set reminders yet, but I'll mention it at the end. A little gruyère would be perfect in it."),
    ]

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func run() async {
        var turn = 0
        while !Task.isCancelled {
            let pair = script[turn % script.count]
            turn += 1
            phase = .listening
            try? await Task.sleep(for: .milliseconds(700))
            await speak(pair.user, fromUser: true, pace: 0.26)
            try? await Task.sleep(for: .milliseconds(500))
            phase = .thinking
            try? await Task.sleep(for: .milliseconds(1300))
            phase = .speaking
            await speak(pair.reply, fromUser: false, pace: 0.2)
            try? await Task.sleep(for: .milliseconds(900))
            if lines.count > 6 { lines.removeFirst(2) }
        }
    }

    private func speak(_ text: String, fromUser: Bool, pace: Double) async {
        lines.append(ConversationLine(fromUser: fromUser, text: ""))
        for word in text.split(separator: " ") {
            guard !Task.isCancelled else { return }
            if fromUser && muted { try? await Task.sleep(for: .milliseconds(200)); continue }
            lines[lines.count - 1].text += (lines[lines.count - 1].text.isEmpty ? "" : " ") + word
            lastWord = .now
            try? await Task.sleep(for: .seconds(pace + Double.random(in: -0.06...0.08)))
        }
    }

    /// Overall voice level 0…1 at time `t`: a decaying envelope from the last word, with
    /// syllable-like wobble. Quiet while thinking.
    func level(at date: Date) -> Double {
        if phase == .thinking || (muted && phase == .listening) { return 0.06 }
        let since = date.timeIntervalSince(lastWord)
        let envelope = exp(-since * 2.6)
        let t = date.timeIntervalSinceReferenceDate
        let wobble = 0.55 + 0.25 * sin(t * 17) + 0.2 * sin(t * 7.3 + 1.2)
        return min(1, max(0.04, envelope * wobble))
    }


}

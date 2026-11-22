import AVFoundation
import SwiftUI

/// Settings › Voice: pick a voice (tap previews it), and download open-source natural voices.
struct VoiceSettingsView: View {
    @Bindable var store: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID = VoiceLibrary.selectedID
    @State private var appeared = false

    private var neural: NeuralVoiceStore { store.neuralVoices }

    var body: some View {
        let current = VoiceLibrary.current(neural) // resolved once per redraw, not per row
        let rows = self.rows
        return ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 10) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Ink.primary).frame(width: 38, height: 38).background(Ink.fill, in: .circle)
                    }
                    .buttonStyle(PressStyle(scale: 0.88))
                    .accessibilityLabel("Back")
                    Text("Voice").font(.geist(17, .medium)).foregroundStyle(Ink.primary)
                }
                .padding(.top, 8)

                block("Your voices", order: 0) {
                    card {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                            voiceRow(row, selected: isSelected(row, current))
                            if i < rows.count - 1 { divider }
                        }
                    }
                    Text(VoiceLibrary.hasNaturalSystemVoice
                         ? "Tap a voice to hear it. More system voices: Settings › Accessibility › Spoken Content › Voices."
                         : "iPhone ships compact system voices. Download a natural voice below, or a Premium one in Settings › Accessibility › Spoken Content › Voices.")
                        .font(.geist(13)).foregroundStyle(Ink.tertiary).lineSpacing(2).padding(.horizontal, 4)
                }

                if !available.isEmpty {
                    block("Natural voices", order: 1) {
                        card {
                            ForEach(Array(available.enumerated()), id: \.element.id) { i, voice in
                                downloadRow(voice)
                                if i < available.count - 1 { divider }
                            }
                        }
                        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: available.map(\.id))
                        engineNote
                    }
                }
                if let error = neural.error {
                    Text(error).font(.geist(13)).foregroundStyle(Ink.secondary).padding(.horizontal, 4)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(Ink.paper)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { appeared = true }
        .onDisappear { Speaker.shared.stop() }
        .sensoryFeedback(.selection, trigger: selectedID)
        .animation(.smooth, value: neural.error)
    }

    // MARK: Rows

    private struct Row: Identifiable {
        let id: String
        let name: String
        let tags: [String]
        let natural: Bool
        let choice: VoiceChoice
    }

    /// Installed system voices plus every downloaded natural voice.
    private var rows: [Row] {
        let natural = neural.readyVoices.map { voice in
            Row(id: VoiceLibrary.id(voice), name: voice.name, tags: [voice.female ? "Female" : "Male", "Natural"], natural: true, choice: .neural(voice))
        }
        let system = VoiceLibrary.installed().prefix(8).map { voice in
            Row(id: voice.identifier, name: voice.name, tags: [VoiceLibrary.gender(voice), VoiceLibrary.label(voice.quality)].compactMap { $0 }, natural: false, choice: .system(voice))
        }
        return natural + system
    }

    /// Natural voices not yet usable (not downloaded, or downloading).
    private var available: [NeuralVoice] { NeuralVoice.catalog.filter { !neural.isReady($0) } }

    private func isSelected(_ row: Row, _ current: VoiceChoice) -> Bool {
        switch current {
        case .neural(let voice): row.id == VoiceLibrary.id(voice)
        case .system(let voice): row.id == voice?.identifier
        }
    }

    private func voiceRow(_ row: Row, selected: Bool) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                VoiceLibrary.selectedID = row.id
                selectedID = row.id
            }
            Speaker.shared.say("Hi, I’m \(row.name). This is how I’ll sound when we talk.", as: row.choice)
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .strokeBorder(selected ? Ink.primary : Ink.hairline, lineWidth: selected ? 5.5 : 1.5)
                    .frame(width: 18, height: 18)
                Text(row.name).font(.geist(15, .medium)).foregroundStyle(Ink.primary)
                Spacer(minLength: 8)
                ForEach(row.tags, id: \.self) { tag(tag: $0, strong: $0 == "Natural" || $0 == "Premium" || $0 == "Enhanced") }
            }
            .padding(.horizontal, 16).frame(height: 52)
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
    }

    private func downloadRow(_ voice: NeuralVoice) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(voice.name).font(.geist(15, .medium)).foregroundStyle(Ink.primary)
                Text(voice.accent).font(.geist(13)).foregroundStyle(Ink.secondary)
            }
            Spacer(minLength: 8)
            tag(tag: voice.female ? "Female" : "Male", strong: false)
            // One fixed-width slot for "Get" and for the loader, so the tag beside it never moves.
            ZStack {
                if neural.isDownloading(voice) {
                    HStack(spacing: 5) {
                        SpiralLoader(size: 13)
                        if neural.installed.contains(voice.id) {
                            Text(neural.engine.progress, format: .percent.precision(.fractionLength(0)))
                                .font(.geist(12, .medium).monospacedDigit()).foregroundStyle(Ink.secondary)
                                .contentTransition(.numericText(value: neural.engine.progress))
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }
                    }
                    .frame(width: Self.slot, height: 32)
                    .overlay(Capsule().stroke(Ink.hairline))
                    .transition(.blurReplace)
                } else {
                    Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { neural.download(voice) } } label: {
                        Text("Get").font(.geist(14, .medium)).foregroundStyle(Ink.paper)
                            .frame(width: Self.slot, height: 32)
                            .background(Ink.primary, in: .capsule)
                    }
                    .buttonStyle(PressStyle(scale: 0.92))
                    .accessibilityLabel("Download \(voice.name)")
                    .transition(.blurReplace)
                }
            }
            .frame(width: Self.slot)
        }
        .padding(.horizontal, 16).frame(height: 60)
        .animation(.smooth(duration: 0.3), value: neural.isDownloading(voice))
    }

    private var engineNote: some View {
        Group {
            if neural.engine.isReady {
                Text("Kokoro-82M, open source (Apache 2.0), runs on your iPhone. English voices; each is 0.5 MB.")
            } else {
                Text("Kokoro-82M, open source (Apache 2.0), runs on your iPhone. English voices. The first one also downloads the 327 MB voice engine; each extra voice is 0.5 MB.")
            }
        }
        .font(.geist(13)).foregroundStyle(Ink.tertiary).lineSpacing(2).padding(.horizontal, 4)
    }

    // MARK: Pieces

    /// Width shared by the Get button and the download progress.
    private static let slot: CGFloat = 64

    private func tag(tag: String, strong: Bool) -> some View {
        Text(tag)
            .font(.geist(12, .medium))
            .foregroundStyle(strong ? Ink.primary : Ink.tertiary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .overlay(Capsule().stroke(strong ? Ink.primary.opacity(0.4) : Ink.hairline))
    }

    private var divider: some View { Rectangle().fill(Ink.hairline).frame(height: 1).padding(.leading, 16) }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Ink.hairline))
    }

    private func block<Content: View>(_ title: String, order: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: title)
            content()
        }
        .rise(appeared, delay: Double(order) * 0.06)
    }
}

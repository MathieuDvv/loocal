import AVFoundation
import Foundation
import FoundationModels
import Observation
import Speech

enum ConversationPhase: Equatable { case listening, thinking, speaking }

struct ConversationLine: Identifiable, Equatable {
    let id = UUID()
    let fromUser: Bool
    var text: String
}

/// What the conversation-mode visuals read from: the scripted mock or the live pipeline.
@MainActor
protocol ConversationSource: AnyObject {
    var phase: ConversationPhase { get }
    var lines: [ConversationLine] { get }
    var muted: Bool { get set }
    func level(at date: Date) -> Double
    func start()
    func stop()
}

extension ConversationSource {
    var current: ConversationLine? { lines.last }
    var previous: ConversationLine? { lines.count > 1 ? lines[lines.count - 2] : nil }

    /// Per-band levels for bar visualisations, offset so bars move independently.
    func bands(_ count: Int, at date: Date) -> [Double] {
        let base = level(at: date)
        let t = date.timeIntervalSinceReferenceDate
        return (0..<count).map { i in
            let shimmer = 0.6 + 0.4 * sin(t * (9 + Double(i) * 1.3) + Double(i) * 1.7)
            let shape = 1 - abs(Double(i) - Double(count - 1) / 2) / Double(count)
            return min(1, max(0.05, base * shimmer * (0.55 + shape)))
        }
    }
}

/// Microphone level written from the audio thread, read by the UI.
private final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 0
    func update(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        let db = 20 * log10(max(rms, 0.000_01))
        let normalized = min(1, max(0, Double(db + 50) / 40))  // -50 dB … -10 dB → 0 … 1
        lock.withLock { value = value * 0.6 + normalized * 0.4 }
    }
    func read() -> Double { lock.withLock { value } }
    func reset() { lock.withLock { value = 0 } }
}

/// Live voice conversation, fully on device: Speech framework transcription, a reply from
/// Apple's on-device model (or the selected local model when Apple Intelligence is off),
/// spoken sentence by sentence while it streams. The mic is closed while Loocal speaks.
@MainActor @Observable
final class VoiceConversation: ConversationSource {
    private(set) var phase: ConversationPhase = .listening
    private(set) var lines: [ConversationLine] = []
    var muted = false {
        didSet {
            guard muted != oldValue, phase == .listening else { return }
            muted ? stopListening() : startListening()
        }
    }

    @ObservationIgnored private weak var store: AppState?
    @ObservationIgnored private let audio = AVAudioEngine()
    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognition: SFSpeechRecognitionTask?
    /// System or Kokoro voice, chosen in Settings › Voice.
    @ObservationIgnored private var output: SpeechOutput?
    @ObservationIgnored private let meter = LevelMeter()
    @ObservationIgnored private var lastHeard = Date.distantPast
    @ObservationIgnored private var lastWord = Date.distantPast
    @ObservationIgnored private var silence: Task<Void, Never>?
    @ObservationIgnored private var replying: Task<Void, Never>?
    @ObservationIgnored private var session: LanguageModelSession?
    @ObservationIgnored private var history: [ChatMessage] = []
    @ObservationIgnored private var spoken = 0
    @ObservationIgnored private var replyDone = false
    @ObservationIgnored private var running = false
    @ObservationIgnored private var tapInstalled = false

    /// A pause this long after speech ends your turn.
    private static let endOfTurn: TimeInterval = 1.1

    init(store: AppState) {
        self.store = store
    }

    // MARK: Lifecycle

    func start() {
        guard !running else { return }
        running = true
        Task {
            guard await authorize() else {
                lines.append(ConversationLine(fromUser: false, text: "Loocal needs the microphone and speech recognition. Allow both in Settings."))
                return
            }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
                try session.setActive(true)
            } catch {
                lines.append(ConversationLine(fromUser: false, text: "The microphone couldn’t start: \(error.localizedDescription)"))
                return
            }
            let output = VoiceLibrary.output(for: VoiceLibrary.current(store?.neuralVoices), neural: store?.neuralVoices)
            output.onIdle = { [weak self] in
                guard let self, self.replyDone, self.running else { return }
                self.resumeListening()
            }
            self.output = output
            startListening()
        }
    }

    func stop() {
        running = false
        replying?.cancel()
        silence?.cancel()
        output?.stop()
        stopListening()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        store?.endVoice()
    }

    private func authorize() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        return speech == .authorized && mic
    }

    // MARK: Listening

    private func startListening() {
        guard running, !muted else { return }
        guard let recognizer, recognizer.isAvailable else {
            lines.append(ConversationLine(fromUser: false, text: "Speech recognition isn’t available for this language right now."))
            return
        }
        // Speech never leaves the phone: without on-device recognition, Loocal doesn't listen.
        guard recognizer.supportsOnDeviceRecognition else {
            lines.append(ConversationLine(fromUser: false, text: "On-device speech recognition isn’t available for this language, and Loocal never sends your voice to a server."))
            return
        }
        phase = .listening
        if lines.last?.fromUser != true || lines.last?.text.isEmpty == false {
            lines.append(ConversationLine(fromUser: true, text: ""))
        }
        trim()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = true
        self.request = request
        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        let meter = self.meter
        if tapInstalled { input.removeTap(onBus: 0) }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
            meter.update(buffer)
        }
        tapInstalled = true
        audio.prepare()
        do { try audio.start() } catch {
            lines[lines.count - 1].text = "The microphone couldn’t start."
            return
        }
        lastHeard = .now
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            Task { @MainActor in self?.heard(text, final: isFinal, failed: error != nil && result == nil) }
        }
        silence?.cancel()
        silence = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, self.phase == .listening else { continue }
                let said = self.lines.last?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !said.isEmpty && Date.now.timeIntervalSince(self.lastHeard) > Self.endOfTurn { self.endTurn() }
            }
        }
    }

    private func heard(_ text: String?, final: Bool, failed: Bool) {
        guard phase == .listening, let index = lines.indices.last, lines[index].fromUser else { return }
        if let text, text != lines[index].text {
            lines[index].text = text
            lastHeard = .now
            lastWord = .now
        }
        if final { endTurn() }
        if failed && lines[index].text.isEmpty { stopListening(); startListening() } // recognizer timed out; keep listening
    }

    private func stopListening() {
        silence?.cancel()
        if audio.isRunning { audio.stop() }
        if tapInstalled { audio.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio()
        recognition?.cancel()
        request = nil
        recognition = nil
        meter.reset()
    }

    private func endTurn() {
        guard phase == .listening else { return }
        let said = lines.last?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !said.isEmpty else { return }
        stopListening()
        phase = .thinking
        reply(to: said)
    }

    // MARK: Replying

    private var instructions: String {
        (store?.systemPrompt ?? InferenceEngine.defaultSystemPrompt)
            + "\n\nThis is a spoken conversation. Reply in one to three short, natural sentences. No lists, headings or markdown."
    }

    private func reply(to said: String) {
        lines.append(ConversationLine(fromUser: false, text: ""))
        spoken = 0
        replyDone = false
        replying = Task { [weak self] in
            guard let self else { return }
            var final = ""
            do {
                if SystemLanguageModel.default.isAvailable {
                    if self.session == nil { self.session = LanguageModelSession(instructions: self.instructions) }
                    for try await snapshot in self.session!.streamResponse(to: said) {
                        final = snapshot.content
                        self.received(final)
                    }
                } else if let store = self.store {
                    self.history.append(ChatMessage(role: .user, text: said))
                    final = try await store.localReply(self.history, system: self.instructions) { partial in
                        await MainActor.run { self.received(partial) }
                    }
                    self.history.append(ChatMessage(role: .assistant, text: final))
                }
            } catch is CancellationError {
                return
            } catch let error as LanguageModelSession.GenerationError {
                if case .guardrailViolation = error { final = "I’d rather not answer that one." } else { final = "Sorry, I lost my thought. Try again?" }
                self.received(final)
            } catch {
                final = "Sorry, I couldn’t answer: \(error.localizedDescription)"
                self.received(final)
            }
            guard !Task.isCancelled else { return }
            self.replyDone = true
            self.speakPending(final: true)
            self.store?.recordVoiceTurn(user: said, reply: Self.plain(final))
            if self.output?.isIdle ?? true { self.resumeListening() }
        }
    }

    private func received(_ text: String) {
        guard let index = lines.indices.last, !lines[index].fromUser else { return }
        lines[index].text = Self.plain(text)
        speakPending(final: false)
    }

    /// Speak each sentence as soon as it's complete, so the voice starts early.
    private func speakPending(final: Bool) {
        guard let text = lines.last?.text, !(lines.last?.fromUser ?? true) else { return }
        let characters = Array(text)
        var end = spoken
        if final {
            end = characters.count
        } else {
            for i in stride(from: characters.count - 2, through: spoken, by: -1) where ".!?…\n".contains(characters[i]) && characters[i + 1].isWhitespace {
                end = i + 1
                break
            }
        }
        guard end > spoken else { return }
        let sentence = String(characters[spoken..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        spoken = end
        guard !sentence.isEmpty else { return }
        phase = .speaking
        output?.speak(sentence)
    }

    private func resumeListening() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.startListening()
        }
    }

    // MARK: Visual level

    func level(at date: Date) -> Double {
        switch phase {
        case .thinking: return 0.06
        case .listening: return muted ? 0.04 : max(0.04, meter.read())
        case .speaking: return output?.level(at: date) ?? 0.05
        }
    }

    private func trim() { if lines.count > 8 { lines.removeFirst(lines.count - 8) } }

    /// Speech-friendly text: no markdown symbols.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "#", with: "")
    }

}

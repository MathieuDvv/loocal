import AVFoundation
import Foundation
import MLX
import Observation
#if !targetEnvironment(simulator)
import KokoroSwift
#endif

/// An open-source Kokoro-82M voice (Apache 2.0). English only; ~0.5 MB each on top of the
/// shared 327 MB voice engine.
struct NeuralVoice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let female: Bool
    let british: Bool
    let sha256: String

    static let size: Int64 = 522_320
    static let repository = "mlx-community/Kokoro-82M-bf16"
    static let revision = "a71e4d38b236d968966a2002c4c895dbd12b1c3c"

    var url: URL { URL(string: "https://huggingface.co/\(Self.repository)/resolve/\(Self.revision)/voices/\(id).safetensors")! }
    var accent: String { british ? "British" : "American" }

    static let catalog: [NeuralVoice] = [
        .init(id: "af_heart", name: "Heart", female: true, british: false, sha256: "2c1c733b0e6576c810e268d3e440c21dea4e0f0131a3ba4cfc98d7fe6136d094"),
        .init(id: "af_bella", name: "Bella", female: true, british: false, sha256: "112d310468cbb3cf23404d3d0b50ad3adf017b87bf38bf9edd15f4ad572df6a3"),
        .init(id: "af_nicole", name: "Nicole", female: true, british: false, sha256: "574656386022c81a029e9a72558191925f44c3de2dad2fa2e45751938557d062"),
        .init(id: "af_sarah", name: "Sarah", female: true, british: false, sha256: "4940072182542f54c1035d1daf4c1cf3136ca9baa9ac57c8e006b4befcc50be6"),
        .init(id: "af_kore", name: "Kore", female: true, british: false, sha256: "c491174280cb1ad25210a842f2f34b46a9ef904ec6f6a8e784839531795fa278"),
        .init(id: "am_michael", name: "Michael", female: false, british: false, sha256: "3940147ded35deba0bb52e8132f89b719298e0520258c34584358aa5a24da2ea"),
        .init(id: "am_fenrir", name: "Fenrir", female: false, british: false, sha256: "9abed964b906c4cae6f404d9849e76260689aea862bc6ca85fc3f5207ba96538"),
        .init(id: "am_puck", name: "Puck", female: false, british: false, sha256: "9a8c2e56413bd2063f814cb4c3885fc425876157369117c3f8258d03c8a9ad89"),
        .init(id: "bf_emma", name: "Emma", female: true, british: true, sha256: "8878a75a6661305849eeb1d6293a7177250193616e161b4c3100636434dfe69f"),
        .init(id: "bm_george", name: "George", female: false, british: true, sha256: "a3d9b8995cbbe5536f954b6be2a0f1f312f077118ba0d4d2178fc41dc8306672"),
        .init(id: "bm_fable", name: "Fable", female: false, british: true, sha256: "9fa80184e96d016a744bc13b0b2e7695e55d6b855556fa003325cb1e5ebf2c2b"),
    ]

    /// The shared voice engine weights, pinned and hash-verified like the chat models.
    static let engineSpec = ModelSpec(repository: repository, revision: revision, files: [
        .init(name: "kokoro-v1_0.safetensors", size: 327_115_152, sha256: "4e9ecdf03b8b6cf906070390237feda473dc13327cb8d56a43deaa374c02acd8"),
    ])
}

/// Downloads and tracks the voice engine and individual voices.
@MainActor @Observable
final class NeuralVoiceStore {
    let directory: URL
    let engine: ModelDownload
    private(set) var installed: Set<String> = []
    private(set) var downloading: Set<String> = []
    var error: String?

    init(models: URL) {
        directory = models.appendingPathComponent("Kokoro", isDirectory: true)
        engine = ModelDownload(spec: NeuralVoice.engineSpec, directory: directory, sessionID: ModelDownload.sessionID + ".kokoro", chunked: true)
        try? FileManager.default.createDirectory(at: voicesDirectory, withIntermediateDirectories: true)
        installed = Set(NeuralVoice.catalog.filter { DownloadDelegate.size(of: file(for: $0)) == NeuralVoice.size }.map(\.id))
    }

    var voicesDirectory: URL { directory.appendingPathComponent("voices", isDirectory: true) }
    func file(for voice: NeuralVoice) -> URL { voicesDirectory.appendingPathComponent(voice.id + ".safetensors") }
    func isReady(_ voice: NeuralVoice) -> Bool { engine.isReady && installed.contains(voice.id) }
    func isDownloading(_ voice: NeuralVoice) -> Bool { downloading.contains(voice.id) || (installed.contains(voice.id) && engine.isDownloading) }
    var readyVoices: [NeuralVoice] { NeuralVoice.catalog.filter(isReady) }

    /// Fetch a voice (and the engine, the first time).
    func download(_ voice: NeuralVoice) {
        #if targetEnvironment(simulator)
        error = "Natural voices run on iPhone only. The simulator can’t run the voice engine."
        #else
        error = nil
        if !engine.isReady && !engine.isDownloading { engine.start() }
        guard !installed.contains(voice.id), !downloading.contains(voice.id) else { return }
        downloading.insert(voice.id)
        Task {
            do {
                let (temporary, response) = try await URLSession.shared.download(from: voice.url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw IslandError.message("The voice server returned an error.") }
                try DownloadDelegate.verify(temporary, file: .init(name: voice.id, size: NeuralVoice.size, sha256: voice.sha256))
                let destination = file(for: voice)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)
                installed.insert(voice.id)
            } catch {
                self.error = "\(voice.name) couldn’t download. \(error.localizedDescription)"
            }
            downloading.remove(voice.id)
        }
        #endif
    }
}

/// Runs Kokoro off the main thread, one sentence at a time.
actor KokoroEngine {
    static let shared = KokoroEngine()
    #if !targetEnvironment(simulator)
    private var tts: KokoroTTS?
    #endif
    private var styles: [String: MLXArray] = [:]

    func synthesize(_ text: String, voice: NeuralVoice, directory: URL) throws -> [Float] {
        #if targetEnvironment(simulator)
        throw IslandError.message("Natural voices run on iPhone only.")
        #else
        if tts == nil { tts = KokoroTTS(modelPath: directory.appendingPathComponent("kokoro-v1_0.safetensors")) }
        let style: MLXArray
        if let cached = styles[voice.id] { style = cached } else {
            guard let loaded = try MLX.loadArrays(url: directory.appendingPathComponent("voices/\(voice.id).safetensors"))["voice"] else {
                throw IslandError.message("The \(voice.name) voice file is unreadable.")
            }
            styles[voice.id] = loaded
            style = loaded
        }
        let (audio, _) = try tts!.generateAudio(voice: style, language: voice.british ? .enGB : .enUS, text: text)
        GPU.clearCache()
        return audio
        #endif
    }

    func unload() {
        #if !targetEnvironment(simulator)
        tts = nil
        #endif
        styles = [:]
    }
}

// MARK: - Speech output

/// Where spoken sentences go: a system voice or a Kokoro voice.
@MainActor
protocol SpeechOutput: AnyObject {
    /// Called when everything queued has finished playing.
    var onIdle: (() -> Void)? { get set }
    var isIdle: Bool { get }
    func speak(_ sentence: String)
    func stop()
    /// Loudness 0…1 of what's playing now, for the Tide swell.
    func level(at date: Date) -> Double
}

@MainActor
final class SystemSpeech: NSObject, SpeechOutput, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?
    private var queued = 0
    private var lastWord = Date.distantPast
    var onIdle: (() -> Void)?
    var isIdle: Bool { queued == 0 }

    init(voice: AVSpeechSynthesisVoice?) {
        self.voice = voice
        super.init()
        synth.delegate = self
    }

    func speak(_ sentence: String) {
        let utterance = AVSpeechUtterance(string: sentence)
        utterance.voice = voice
        queued += 1
        synth.speak(utterance)
    }

    func stop() {
        queued = 0
        synth.stopSpeaking(at: .immediate)
    }

    func level(at date: Date) -> Double {
        let envelope = exp(-date.timeIntervalSince(lastWord) * 2.6)
        let t = date.timeIntervalSinceReferenceDate
        return min(1, max(0.05, envelope * (0.55 + 0.25 * sin(t * 17) + 0.2 * sin(t * 7.3 + 1.2))))
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor in self.lastWord = .now }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.done() }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.done() }
    }
    private func done() {
        guard queued > 0 else { return }
        queued -= 1
        if queued == 0 { onIdle?() }
    }
}

@MainActor
final class NeuralSpeech: SpeechOutput {
    private let voice: NeuralVoice
    private let directory: URL
    private let audio = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private var chain: Task<Void, Never>?
    private var queued = 0
    private var generation = 0
    private var cursor = Date.distantPast
    private var segments: [(start: Date, samples: [Float])] = []
    var onIdle: (() -> Void)?
    var isIdle: Bool { queued == 0 }

    init(voice: NeuralVoice, directory: URL) {
        self.voice = voice
        self.directory = directory
        audio.attach(player)
        audio.connect(player, to: audio.mainMixerNode, format: format)
    }

    func speak(_ sentence: String) {
        // Kokoro handles up to ~510 phonemes; long sentences are split at spaces.
        for piece in Self.pieces(sentence) {
            queued += 1
            let previous = chain, voice = voice, directory = directory, run = generation
            chain = Task { [weak self] in
                await previous?.value
                guard !Task.isCancelled else { return }
                let samples = try? await KokoroEngine.shared.synthesize(piece, voice: voice, directory: directory)
                guard let self, self.generation == run else { return }
                if let samples, !samples.isEmpty { self.play(samples, run: run) } else { self.done(run) }
            }
        }
    }

    private func play(_ samples: [Float], run: Int) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { done(run); return }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        if !audio.isRunning { try? audio.start() }
        if !player.isPlaying { player.play() }
        let start = max(.now, cursor)
        cursor = start.addingTimeInterval(Double(samples.count) / 24_000)
        segments.append((start, samples))
        if segments.count > 6 { segments.removeFirst() }
        player.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in self?.done(run) }
        }
    }

    private func done(_ run: Int) {
        guard run == generation, queued > 0 else { return }
        queued -= 1
        if queued == 0 { onIdle?() }
    }

    func stop() {
        generation += 1
        chain?.cancel()
        chain = nil
        queued = 0
        player.stop()
        segments = []
        cursor = .distantPast
    }

    func level(at date: Date) -> Double {
        guard let segment = segments.last(where: { $0.start <= date }) else { return 0.05 }
        let index = Int(date.timeIntervalSince(segment.start) * 24_000)
        guard index < segment.samples.count else { return 0.05 }
        let window = segment.samples[max(0, index - 600)..<min(segment.samples.count, index + 600)]
        let rms = sqrt(window.reduce(0) { $0 + $1 * $1 } / Float(max(window.count, 1)))
        return min(1, max(0.05, Double(rms) * 4.5))
    }

    static func pieces(_ text: String) -> [String] {
        guard text.count > 280 else { return [text] }
        var pieces: [String] = [], current = ""
        for word in text.split(separator: " ") {
            if current.count + word.count > 260 { pieces.append(current); current = "" }
            current += (current.isEmpty ? "" : " ") + word
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}

import AVFoundation
import Foundation

/// The voice Loocal speaks with: a system voice, or a downloaded Kokoro voice.
/// iPhones ship compact system voices only; Enhanced and Premium ones are free downloads
/// in Settings › Accessibility › Spoken Content › Voices. Siri's voice isn't available to apps.
enum VoiceChoice: Equatable {
    case system(AVSpeechSynthesisVoice?)
    case neural(NeuralVoice)
}

enum VoiceLibrary {
    private static let key = "voice.id"
    private static let neuralPrefix = "kokoro:"

    static var language: String { Locale.current.language.languageCode?.identifier ?? "en" }

    /// Installed system voices for the device language, best first. Novelty voices are left out.
    /// Asking iOS for its voices is slow (and was being done many times per redraw), so the
    /// list is read once, preloaded at launch, and refreshed only when iOS reports a change.
    static func installed() -> [AVSpeechSynthesisVoice] {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cached { return cached }
        let list = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) && !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice) }
            .sorted { ($0.quality.rawValue, $1.name) > ($1.quality.rawValue, $0.name) }
        cached = list
        return list
    }

    nonisolated(unsafe) private static var cached: [AVSpeechSynthesisVoice]?
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var observer: NSObjectProtocol?

    /// Warm the cache off the main thread, and drop it whenever voices are added or removed.
    static func preload() {
        observer = NotificationCenter.default.addObserver(forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil, queue: nil) { _ in
            cacheLock.lock(); cached = nil; cacheLock.unlock()
            _ = installed()
        }
        Task.detached(priority: .utility) { _ = installed() }
    }

    static var selectedID: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func id(_ voice: NeuralVoice) -> String { neuralPrefix + voice.id }

    /// The chosen voice if still usable; otherwise the best installed system voice.
    @MainActor static func current(_ neural: NeuralVoiceStore?) -> VoiceChoice {
        if let id = selectedID, id.hasPrefix(neuralPrefix),
           let voice = NeuralVoice.catalog.first(where: { neuralPrefix + $0.id == id }), neural?.isReady(voice) == true {
            return .neural(voice)
        }
        if let id = selectedID, let voice = installed().first(where: { $0.identifier == id }) ?? AVSpeechSynthesisVoice(identifier: id) { return .system(voice) }
        return .system(installed().first ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode()))
    }

    @MainActor static func output(for choice: VoiceChoice, neural: NeuralVoiceStore?) -> SpeechOutput {
        switch choice {
        case .neural(let voice): NeuralSpeech(voice: voice, directory: neural!.directory)
        case .system(let voice): SystemSpeech(voice: voice)
        }
    }

    @MainActor static func summary(_ neural: NeuralVoiceStore?) -> String {
        switch current(neural) {
        case .neural(let voice): "\(voice.name) · Natural"
        case .system(let voice): voice.map { "\($0.name) · \(label($0.quality))" } ?? "System"
        }
    }

    static var hasNaturalSystemVoice: Bool { installed().contains { $0.quality != .default } }

    static func label(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: "Premium"
        case .enhanced: "Enhanced"
        default: "Standard"
        }
    }

    static func gender(_ voice: AVSpeechSynthesisVoice) -> String? {
        switch voice.gender {
        case .female: "Female"
        case .male: "Male"
        default: nil
        }
    }

    /// Split text into sentences so speech can start before everything is synthesised.
    static func sentences(_ text: String) -> [String] {
        var result: [String] = [], current = ""
        for character in text {
            current.append(character)
            if ".!?…\n".contains(character), current.trimmingCharacters(in: .whitespaces).count > 1 {
                result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { result.append(rest) }
        return result.filter { !$0.isEmpty }
    }
}

/// Reads text aloud outside conversation mode (voice previews, "Read aloud").
@MainActor
final class Speaker {
    static let shared = Speaker()
    private var output: SpeechOutput?

    func say(_ text: String, as choice: VoiceChoice? = nil) {
        stop()
        let neural = AppRuntime.store?.neuralVoices
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let output = VoiceLibrary.output(for: choice ?? VoiceLibrary.current(neural), neural: neural)
        self.output = output
        VoiceLibrary.sentences(VoiceConversation.plain(text)).forEach(output.speak)
    }

    func stop() {
        output?.stop()
        output = nil
    }
}

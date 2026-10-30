import AVFoundation
import Observation

/// Speaks while the reply is still arriving: as soon as a sentence closes,
/// that sentence is queued for synthesis. So the first word comes out after
/// the first sentence, not when the reply is complete.
@MainActor
@Observable
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private(set) var isSpeaking = false
    var onFinished: (() -> Void)?
    var rate: Double = 0.52
    var localeID = "it-IT"
    /// Voice chosen by hand. Empty = the best one installed for that language.
    var voiceIdentifier = ""

    /// Available voices, from best to worst. Siri voices don't appear: Apple
    /// doesn't expose them to third-party apps. The downloadable «premium» ones
    /// from Settings are almost as good, though, and change everything compared
    /// with the stock compact voice.
    static func voices(for language: String) -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == language }
            .sorted { rank($0) > rank($1) }
    }

    static func rank(_ v: AVSpeechSynthesisVoice) -> Int {
        if v.voiceTraits.contains(.isPersonalVoice) { return 4 }
        if isSiri(v) { return 0 }              // at the bottom: almost always unusable
        switch v.quality {
        case .premium: return 3
        case .enhanced: return 2
        default: return 1
        }
    }

    static func qualityLabel(_ v: AVSpeechSynthesisVoice) -> String {
        if v.voiceTraits.contains(.isPersonalVoice) { return "la tua voce" }
        if isSiri(v) { return "Siri — di solito bloccata" }
        switch v.quality {
        case .premium: return "premium"
        case .enhanced: return "migliorata"
        default: return "base"
        }
    }

    /// Siri voices appear in the list but Apple doesn't allow third-party apps
    /// to use them: requesting them silently falls back to the stock voice.
    /// Worth trying them — the preview tells you in a second — but better to
    /// know beforehand than to blame the app.
    static func isSiri(_ v: AVSpeechSynthesisVoice) -> Bool {
        v.identifier.lowercased().contains("siri")
    }

    /// The Personal Voice recorded by the user (Settings → Accessibility →
    /// Personal Voice) is the only Apple-quality voice actually granted to
    /// third-party apps, but it has to be authorized once.
    static func requestPersonalVoice(_ done: @escaping @Sendable (Bool) -> Void) {
        AVSpeechSynthesizer.requestPersonalVoiceAuthorization { status in
            DispatchQueue.main.async { done(status == .authorized) }
        }
    }

    private let synth = AVSpeechSynthesizer()
    private var buffer = ""
    private var pending = 0
    private var closed = false
    private var interrupted = false

    override init() {
        super.init()
        synth.delegate = self
        // Uses our audio session: it stays on the A2DP route to the car.
        synth.usesApplicationAudioSession = true
    }

    func begin() {
        buffer = ""; pending = 0; closed = false; interrupted = false
    }

    /// Receives text deltas from the stream.
    func feed(_ text: String) {
        buffer += text
        while let range = buffer.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?\n"),
                                                  options: .backwards) {
            let sentence = String(buffer[..<range.upperBound])
            // Don't split on decimals or very short abbreviations.
            guard sentence.trimmingCharacters(in: .whitespacesAndNewlines).count > 12 else { break }
            buffer = String(buffer[range.upperBound...])
            enqueue(sentence)
        }
    }

    /// The stream has ended: speak whatever is left.
    func close() {
        closed = true
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        if !rest.isEmpty { enqueue(rest) }
        if pending == 0 && !interrupted { onFinished?() }
    }

    func say(_ text: String, thenFinish: Bool = true) {
        begin()
        enqueue(text)
        closed = thenFinish
    }

    /// Barge-in: cuts the voice off instantly.
    func stop() {
        interrupted = true
        buffer = ""
        pending = 0
        synth.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    private func enqueue(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !interrupted else { return }
        let u = AVSpeechUtterance(string: clean)
        u.voice = voiceIdentifier.isEmpty
            ? Self.bestVoice(localeID)
            : (AVSpeechSynthesisVoice(identifier: voiceIdentifier) ?? Self.bestVoice(localeID))
        u.rate = Float(rate)
        u.postUtteranceDelay = 0.05
        pending += 1
        isSpeaking = true
        synth.speak(u)
    }

    /// Prefers an "enhanced"/"premium" voice if the user has downloaded it:
    /// in the car, with rolling noise, you can hear the difference.
    private static func bestVoice(_ id: String) -> AVSpeechSynthesisVoice? {
        voices(for: id).first ?? AVSpeechSynthesisVoice(language: id)
    }

    /// Preview in settings, to choose it by ear.
    func preview(_ identifier: String) {
        stop()
        interrupted = false
        let u = AVSpeechUtterance(string: "Martedì alle quindici, riunione con Stefano. Confermi?")
        u.voice = AVSpeechSynthesisVoice(identifier: identifier)
        u.rate = Float(rate)
        pending += 1
        isSpeaking = true
        synth.speak(u)
    }

    // MARK: - Delegate

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in
            pending = max(0, pending - 1)
            if pending == 0 {
                isSpeaking = false
                if closed && !interrupted { onFinished?() }
            }
        }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in
            pending = max(0, pending - 1)
            if pending == 0 { isSpeaking = false }
        }
    }
}

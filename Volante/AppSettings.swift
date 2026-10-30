import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    /// Window within which two consecutive presses of the steering wheel button
    /// count as a "double tap" -> voice note. To be tuned in the car.
    var doubleTapWindow: Double {
        didSet { d.set(doubleTapWindow, forKey: "doubleTapWindow") }
    }
    var skipForwardSeconds: Double {
        didSet { d.set(skipForwardSeconds, forKey: "skipForwardSeconds") }
    }
    var skipBackwardSeconds: Double {
        didSet { d.set(skipBackwardSeconds, forKey: "skipBackwardSeconds") }
    }
    /// Continuous silence after which the note closes by itself.
    var silenceStopSeconds: Double {
        didSet { d.set(silenceStopSeconds, forKey: "silenceStopSeconds") }
    }
    var maxNoteSeconds: Double {
        didSet { d.set(maxNoteSeconds, forKey: "maxNoteSeconds") }
    }
    var transcriptionLocale: String {
        didSet { d.set(transcriptionLocale, forKey: "transcriptionLocale") }
    }
    var playbackRate: Double {
        didSet { d.set(playbackRate, forKey: "playbackRate") }
    }
    /// Speaking rate of the assistant's voice (AVSpeechUtterance: 0.5 = normal).
    var speechRate: Double {
        didSet { d.set(speechRate, forKey: "speechRate") }
    }
    /// After the reply, reopens the microphone by itself: you converse without pressing again.
    var continuousConversation: Bool {
        didSet { d.set(continuousConversation, forKey: "continuousConversation") }
    }
    /// What a double tap on «indietro» ("back") does: "claude" or "nota".
    var backDoubleTapAction: String {
        didSet { d.set(backDoubleTapAction, forKey: "backDoubleTapAction") }
    }
    /// In the keychain, never in UserDefaults.
    var apiKey: String {
        didSet { Keychain.set(apiKey, for: "anthropic") }
    }
    /// The model for the fast loop on the phone. Haiku by default: it's the
    /// piece that runs on every sentence; the expensive work goes to the Mac.
    var model: String {
        didSet { d.set(model, forKey: "model") }
    }
    /// Address of the bridge on the Mac, e.g. http://100.x.y.z:8787 (Tailscale).
    var bridgeURL: String {
        didSet { d.set(bridgeURL, forKey: "bridgeURL") }
    }
    var bridgeToken: String {
        didSet { Keychain.set(bridgeToken, for: "bridge") }
    }
    /// GitHub token: it's what makes the projects reachable even with the Mac off.
    var githubToken: String {
        didSet { Keychain.set(githubToken, for: "github") }
    }
    var githubOwner: String {
        didSet { d.set(githubOwner, forKey: "githubOwner") }
    }
    /// Identifier of the chosen voice. Empty = the best one installed.
    var voiceIdentifier: String {
        didSet { d.set(voiceIdentifier, forKey: "voiceIdentifier") }
    }
    /// Who the user is and what they work on: synced from Claude Code's memory
    /// on the Mac, then it stays here and works offline too.
    var personalContext: String {
        didSet { d.set(personalContext, forKey: "personalContext") }
    }
    /// Only if the API key isn't already bound to a workspace.
    var anthropicWorkspace: String {
        didSet { d.set(anthropicWorkspace, forKey: "anthropicWorkspace") }
    }
    var slackToken: String {
        didSet { Keychain.set(slackToken, for: "slack") }
    }
    var notionToken: String {
        didSet { Keychain.set(notionToken, for: "notion") }
    }
    /// Telegram bot token: it's the only messaging channel iOS lets a
    /// third-party app use in a truly programmatic way.
    var telegramToken: String {
        didSet { Keychain.set(telegramToken, for: "telegram") }
    }
    /// Notion page under which new pages are created. It must be shared with the integration.
    var notionParent: String {
        didSet { d.set(notionParent, forKey: "notionParent") }
    }
    /// How many episodes to keep downloaded. Zero disables automatic downloading.
    var autoDownloadCount: Double {
        didSet { d.set(autoDownloadCount, forKey: "autoDownloadCount") }
    }
    /// Podcast language: needed to transcribe the passage you listened to, which
    /// usually isn't in the same language as your notes.
    var podcastLocale: String {
        didSet { d.set(podcastLocale, forKey: "podcastLocale") }
    }
    /// Driving coach and black box: they use location and sensors, so they can be switched off.
    var tripCoach: Bool {
        didSet { d.set(tripCoach, forKey: "tripCoach") }
    }
    var speakTripSummary: Bool {
        didSet { d.set(speakTripSummary, forKey: "speakTripSummary") }
    }
    /// Voice EQ and limiter. Loudness levelling stays active regardless.
    var voiceBoost: Bool {
        didSet { d.set(voiceBoost, forKey: "voiceBoost") }
    }

    private let d = UserDefaults.standard

    init() {
        let u = UserDefaults.standard
        func dbl(_ k: String, _ fallback: Double) -> Double { u.object(forKey: k) as? Double ?? fallback }
        doubleTapWindow = dbl("doubleTapWindow", 0.45)
        skipForwardSeconds = dbl("skipForwardSeconds", 30)
        skipBackwardSeconds = dbl("skipBackwardSeconds", 15)
        silenceStopSeconds = dbl("silenceStopSeconds", 2.5)
        maxNoteSeconds = dbl("maxNoteSeconds", 120)
        playbackRate = dbl("playbackRate", 1.0)
        speechRate = dbl("speechRate", 0.52)
        continuousConversation = (u.object(forKey: "continuousConversation") as? Bool) ?? true
        backDoubleTapAction = u.string(forKey: "backDoubleTapAction") ?? "claude"
        apiKey = Keychain.get("anthropic")
        model = u.string(forKey: "model") ?? "claude-haiku-4-5"
        bridgeURL = u.string(forKey: "bridgeURL") ?? ""
        bridgeToken = Keychain.get("bridge")
        githubToken = Keychain.get("github")
        githubOwner = u.string(forKey: "githubOwner") ?? ""
        voiceIdentifier = u.string(forKey: "voiceIdentifier") ?? ""
        personalContext = u.string(forKey: "personalContext") ?? ""
        anthropicWorkspace = u.string(forKey: "anthropicWorkspace") ?? ""
        slackToken = Keychain.get("slack")
        notionToken = Keychain.get("notion")
        telegramToken = Keychain.get("telegram")
        notionParent = u.string(forKey: "notionParent") ?? ""
        tripCoach = (u.object(forKey: "tripCoach") as? Bool) ?? true
        speakTripSummary = (u.object(forKey: "speakTripSummary") as? Bool) ?? true
        podcastLocale = u.string(forKey: "podcastLocale") ?? "en-US"
        autoDownloadCount = dbl("autoDownloadCount", 3)
        voiceBoost = (u.object(forKey: "voiceBoost") as? Bool) ?? true
        transcriptionLocale = u.string(forKey: "transcriptionLocale") ?? "it-IT"
    }
}

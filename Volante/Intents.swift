import AppIntents
import Foundation

/// Actions that Siri and Shortcuts can perform on Volante.
///
/// It's the only real hands-free path that doesn't go through the steering
/// wheel: it works with the phone in your pocket, with the app closed, and
/// even on foot. And since every action is also a Shortcuts block, they can be
/// slotted into automations — for example, triggering them when the car's
/// Bluetooth connects.
enum PendingIntent {
    /// Intents have no access to the app's model: they leave a note behind, and
    /// the app reads it as soon as it becomes active again.
    nonisolated(unsafe) static var action: String?

    static func request(_ name: String) {
        action = name
        UserDefaults.standard.set(name, forKey: "pendingIntent")
    }

    @MainActor
    static func consume() -> String? {
        let a = action ?? UserDefaults.standard.string(forKey: "pendingIntent")
        action = nil
        UserDefaults.standard.removeObject(forKey: "pendingIntent")
        return a
    }
}

struct TakeNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Prendi una nota"
    static var description = IntentDescription("Apre il microfono e registra una nota vocale.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        PendingIntent.request("nota")
        return .result()
    }
}

struct AskClaudeIntent: AppIntent {
    static var title: LocalizedStringResource = "Parla con Claude"
    static var description = IntentDescription("Apre il microfono per una domanda a Claude.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        PendingIntent.request("claude")
        return .result()
    }
}

struct DictateIntent: AppIntent {
    static var title: LocalizedStringResource = "Detta a lungo"
    static var description = IntentDescription("Avvia la dettatura lunga: il silenzio non chiude niente.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        PendingIntent.request("dettatura")
        return .result()
    }
}

struct PlayPodcastIntent: AppIntent {
    static var title: LocalizedStringResource = "Riprendi il podcast"
    static var description = IntentDescription("Riprende l'episodio da dove eri.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        PendingIntent.request("play")
        return .result()
    }
}

/// The message dictated while driving, returned to Siri as text.
///
/// It's for the WhatsApp route: iOS doesn't let any app other than WhatsApp
/// send, but a shortcut run by Siri can. This intent passes it the number and
/// text, and the shortcut does the rest — without ever touching the screen.
struct PendingMessageIntent: AppIntent {
    static var title: LocalizedStringResource = "Messaggio da mandare"
    static var description = IntentDescription(
        "Restituisce l'ultimo messaggio dettato, pronto da passare a WhatsApp.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: DraftFile.read())
    }
}

struct PendingMessageNumberIntent: AppIntent {
    static var title: LocalizedStringResource = "Numero del messaggio"
    static var description = IntentDescription("Restituisce il numero del destinatario.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: DraftFile.readNumber())
    }
}

struct VolanteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TakeNoteIntent(),
                    phrases: ["Prendi nota su \(.applicationName)",
                              "Nuova nota su \(.applicationName)"],
                    shortTitle: "Prendi una nota",
                    systemImageName: "mic.fill")
        AppShortcut(intent: AskClaudeIntent(),
                    phrases: ["Chiedi a \(.applicationName)",
                              "Parla con \(.applicationName)"],
                    shortTitle: "Parla con Claude",
                    systemImageName: "bubble.left.and.bubble.right.fill")
        AppShortcut(intent: DictateIntent(),
                    phrases: ["Detta su \(.applicationName)"],
                    shortTitle: "Detta a lungo",
                    systemImageName: "text.bubble")
        AppShortcut(intent: PlayPodcastIntent(),
                    phrases: ["Riprendi \(.applicationName)"],
                    shortTitle: "Riprendi il podcast",
                    systemImageName: "play.fill")
        AppShortcut(intent: PendingMessageIntent(),
                    phrases: ["Messaggio da \(.applicationName)"],
                    shortTitle: "Messaggio da mandare",
                    systemImageName: "paperplane")
    }
}

/// The pending message, also written to a file: shortcuts can read it from
/// the Files app even without going through an intent.
enum DraftFile {
    static var textURL: URL { Paths.documents.appendingPathComponent("messaggio.txt") }
    static var numberURL: URL { Paths.documents.appendingPathComponent("numero.txt") }

    static func write(number: String, text: String) {
        try? text.write(to: textURL, atomically: true, encoding: .utf8)
        try? number.write(to: numberURL, atomically: true, encoding: .utf8)
    }

    static func read() -> String {
        (try? String(contentsOf: textURL, encoding: .utf8)) ?? ""
    }

    static func readNumber() -> String {
        (try? String(contentsOf: numberURL, encoding: .utf8)) ?? ""
    }

    static func clear() {
        try? "".write(to: textURL, atomically: true, encoding: .utf8)
        try? "".write(to: numberURL, atomically: true, encoding: .utf8)
    }
}

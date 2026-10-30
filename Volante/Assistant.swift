import Foundation
import UIKit
import Observation

/// The full loop: transcribed text -> Claude streaming -> voice, with tools
/// executed in between. Every action is read back aloud, because in the car
/// you can't check anything with your eyes.
@MainActor
@Observable
final class Assistant {
    enum State: String { case idle, thinking, speaking }

    struct Line: Identifiable {
        let id = UUID()
        let role: String        // "tu" | "claude" | "azione"  (you | claude | action)
        let text: String
        let at = Date()
    }

    private(set) var state: State = .idle
    private(set) var lines: [Line] = []
    private(set) var lastError: String?

    let client = ClaudeClient()
    let speaker = Speaker()

    var diagnostics: Diagnostics?
    var settings: AppSettings?
    /// What you're listening to, at which minute, the latest notes: the context
    /// that makes the conversation useful instead of generic.
    var contextProvider: (() -> String)?
    var toolContext: AssistantTools.Context?
    var startDictation: (() -> Void)?
    /// Instructions valid only for the current session: roleplay, English,
    /// pitch practice. Empty = normal assistant.
    var persona: String?
    var onFinishedSpeaking: (() -> Void)?

    private var messages: [[String: Any]] = []

    init() {
        client.diagnostics = diagnostics
        speaker.onFinished = { [weak self] in
            guard let self else { return }
            self.state = .idle
            self.onFinishedSpeaking?()
        }
    }

    /// Speaks an announcement (e.g. the Mac has finished) without opening a conversation.
    func announce(_ text: String) {
        state = .speaking
        speaker.rate = settings?.speechRate ?? 0.52
        speaker.say(text)
    }

    func resetConversation() {
        messages = []
        lines = []
        try? FileManager.default.removeItem(at: Self.storeURL)
    }

    // MARK: - Persistence
    //
    // The conversation survives the app being closed, but only for a few
    // hours: picking up a discussion from three days ago would be more
    // disorienting than useful.

    private static var storeURL: URL {
        Paths.support.appendingPathComponent("conversation.json")
    }
    private static let maxAge: TimeInterval = 6 * 3600

    func persist() {
        let payload: [String: Any] = [
            "at": Date().timeIntervalSince1970,
            "messages": messages,
            "lines": lines.map { ["role": $0.role, "text": $0.text] }
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? d.write(to: Self.storeURL)
    }

    func restore() {
        guard let d = try? Data(contentsOf: Self.storeURL),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let at = obj["at"] as? TimeInterval,
              Date().timeIntervalSince1970 - at < Self.maxAge,
              let msgs = obj["messages"] as? [[String: Any]] else { return }
        messages = msgs
        if let saved = obj["lines"] as? [[String: String]] {
            lines = saved.compactMap {
                guard let r = $0["role"], let t = $0["text"] else { return nil }
                return Line(role: r, text: t)
            }
        }
        diagnostics?.log("claude", "conversazione ripresa (\(messages.count) messaggi)")
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        speaker.stop()
        state = .idle
    }

    func clearError() { lastError = nil }

    /// One turn at a time. Previously nobody held on to the `Task`, so
    /// interrupting Claude didn't actually stop the network request: the old
    /// stream kept going underneath while a new one started.
    func ask(_ text: String) {
        currentTask?.cancel()
        currentTask = Task { [weak self] in await self?.run(text) }
    }

    private var currentTask: Task<Void, Never>?

    private func run(_ text: String) async {
        // During the reply the podcast is paused: without this, if the app is
        // in the background (Maps in front) iOS can suspend it mid-call and the
        // reply never arrives.
        let job = UIApplication.shared.beginBackgroundTask(withName: "claude-turn")
        defer { if job != .invalid { UIApplication.shared.endBackgroundTask(job) } }

        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        lastError = nil
        lines.append(Line(role: "tu", text: text))

        client.apiKey = settings?.apiKey ?? ""
        client.model = settings?.model ?? "claude-haiku-4-5"
        client.workspaceID = settings?.anthropicWorkspace ?? ""
        client.diagnostics = diagnostics
        speaker.voiceIdentifier = settings?.voiceIdentifier ?? ""
        speaker.rate = settings?.speechRate ?? 0.52
        GitHubTools.token = settings?.githubToken ?? ""
        GitHubTools.owner = settings?.githubOwner ?? ""
        Integrations.slackToken = settings?.slackToken ?? ""
        Integrations.notionToken = settings?.notionToken ?? ""
        Integrations.notionParent = settings?.notionParent ?? ""
        Messaging.telegramToken = settings?.telegramToken ?? ""
        guard !client.apiKey.isEmpty else {
            fail("Manca la chiave API di Anthropic. Aprila nelle impostazioni dell'app.")
            return
        }

        messages.append(["role": "user", "content": text])
        // Short history: conversations in the car are brief, and every token
        // resent is a token paid for on every turn.
        if messages.count > 12 { messages.removeFirst(messages.count - 12) }
        let userTurn = messages.count - 1
        state = .thinking
        speaker.begin()

        let tools = AssistantTools.specs(
            bridgeConfigured: !(settings?.bridgeURL.isEmpty ?? true),
            githubConfigured: !(settings?.githubToken.isEmpty ?? true),
            slack: !(settings?.slackToken.isEmpty ?? true),
            notion: !(settings?.notionToken.isEmpty ?? true),
            model: client.model)

        var spokenText = ""
        // After five seconds of waiting, in a car, silence reads as «it's dead».
        // A filler word goes into the same voice stream and the real reply queues
        // up behind it naturally.
        let filler = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled, self.state == .thinking else { return }
            self.speaker.feed("Un attimo. ")
        }
        defer { filler.cancel() }

        do {
            for _ in 0..<5 {
                let turn = try await sendWithRetry(
                    system: systemPrompt(),
                    messages: messages,
                    tools: tools
                ) { [weak self] delta in
                    spokenText += delta
                    self?.state = .speaking
                    self?.speaker.feed(delta)
                }

                if turn.stopReason == "refusal" {
                    speaker.feed("Non posso rispondere a questo.")
                    break
                }

                messages.append(["role": "assistant", "content": turn.content])

                // The server-side tool loop (web search) has paused: send everything
                // back as is and it resumes by itself, without adding any user
                // message.
                if turn.stopReason == "pause_turn" { continue }

                guard !turn.toolUses.isEmpty else { break }

                var results: [[String: Any]] = []
                for use in turn.toolUses {
                    diagnostics?.log("claude", "tool \(use.name) \(use.input)")
                    if use.name == "avvia_dettatura" || use.name == "avvia_allenamento" {
                        if use.name == "avvia_allenamento" {
                            let out = await AssistantTools.execute(
                                name: use.name, input: use.input,
                                ctx: toolContext ?? AssistantTools.Context(
                                    saveNote: { _ in }, searchNotes: { _ in "" },
                                    sendToMac: { _, _ in "" }, people: PeopleStore(),
                                    sendMessage: { _, _ in "" }, startTraining: { _ in }))
                            lines.append(Line(role: "azione", text: out))
                            results.append(["type": "tool_result", "tool_use_id": use.id,
                                            "content": out])
                            continue
                        }
                        startDictation?()
                        lines.append(Line(role: "azione", text: "dettatura lunga avviata"))
                        results.append(["type": "tool_result", "tool_use_id": use.id,
                                        "content": "Dettatura avviata. Digli in una frase che stai registrando e che si ferma quando glielo dice."])
                        continue
                    }
                    guard let ctx = toolContext else {
                        results.append(["type": "tool_result", "tool_use_id": use.id,
                                        "content": "Strumenti non disponibili."])
                        continue
                    }
                    let out = await AssistantTools.execute(name: use.name, input: use.input, ctx: ctx)
                    lines.append(Line(role: "azione", text: "\(use.name): \(out)"))
                    results.append([
                        "type": "tool_result",
                        "tool_use_id": use.id,
                        "content": out
                    ])
                }
                messages.append(["role": "user", "content": results])
            }

            if !spokenText.isEmpty { lines.append(Line(role: "claude", text: spokenText)) }
            persist()
            speaker.close()
            if !speaker.isSpeaking { state = .idle; onFinishedSpeaking?() }

        } catch is CancellationError {
            rollback(to: userTurn)
            state = .idle
        } catch {
            // The failed turn must be removed from the history: leaving it there
            // means two user messages in a row, and the next request would be
            // rejected even though it has nothing to do with it.
            rollback(to: userTurn)
            fail(error.localizedDescription)
        }
    }

    /// On mobile networks a timeout happens: a second attempt almost always
    /// recovers it, and it costs less than redoing the whole voice loop.
    private func sendWithRetry(system: String,
                               messages: [[String: Any]],
                               tools: [[String: Any]],
                               onText: @escaping (String) -> Void) async throws -> ClaudeTurn {
        do {
            return try await client.send(system: system, messages: messages,
                                         tools: tools, onText: onText)
        } catch let error as URLError where error.code == .timedOut
                                        || error.code == .networkConnectionLost {
            diagnostics?.log("claude", "timeout, secondo tentativo")
            return try await client.send(system: system, messages: messages,
                                         tools: tools, onText: onText)
        } catch is ClaudeError {
            diagnostics?.log("claude", "scaduto, secondo tentativo")
            return try await client.send(system: system, messages: messages,
                                         tools: tools, onText: onText)
        }
    }

    private func rollback(to index: Int) {
        guard index >= 0, messages.count > index else { return }
        messages.removeSubrange(index...)
    }

    private func fail(_ message: String) {
        lastError = message
        diagnostics?.log("claude", "ERRORE — \(message)")
        lines.append(Line(role: "azione", text: "errore: \(message)"))
        speaker.say("Non ci sono riuscito.")
        state = .speaking
    }

    /// What their Claude on the Mac already knows: open projects, decisions,
    /// how they like to work. Without it the assistant is generic; with it, it
    /// knows «arete-fw» is firmware and doesn't need to ask what it is.
    private var profileBlock: String {
        let ctx = (settings?.personalContext ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ctx.isEmpty else { return "" }
        return """
        Ecco cosa devi sapere di lui e dei suoi progetti. È l'indice di memoria \
        del suo Claude, quindi è denso: usalo per capire i riferimenti al volo, \
        non elencarglielo mai.

        \(ctx.prefix(12_000))
        """
    }

    private func systemPrompt() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        let now = f.string(from: Date())

        return """
        Sei l'assistente di bordo di chi guida, che ti parla mentre sta guidando.

        Tutto quello che scrivi viene letto ad alta voce da una sintesi vocale e \
        ascoltato in macchina. Non c'e' nessuno schermo da guardare e lui non puo' \
        toccare il telefono.

        Regole di stile, non negoziabili:
        - Al massimo due frasi, a meno che non chieda esplicitamente di approfondire.
        - Mai elenchi, mai numerazioni, mai markdown, mai emoji, mai parentesi.
        - Date, ore, numeri e sigle scritti come si pronunciano.
        - Niente preamboli tipo "Certamente" o "Ecco": vai dritto al punto.
        - Se non hai capito, fai una sola domanda, corta.
        - Se serve una scelta, proponi al massimo due opzioni.
        - Dopo aver usato uno strumento, rileggi ad alta voce cosa hai creato, \
        cosi' puo' verificarlo senza guardare.
        - La trascrizione arriva da un microfono in un'auto in movimento: se una \
        parola sembra sbagliata, deducila dal contesto invece di chiedere.

        Hai strumenti veri: calendario, promemoria, note, i suoi repository su \
        GitHub e la ricerca sul web. Le note vocali dei viaggi passati sono la sua \
        memoria: se un riferimento sembra venire da prima, cercale invece di dire \
        che non ricordi. Usa gli strumenti invece di dire che non puoi fare qualcosa. \
        Non chiedere conferma prima di usarli: e' alla guida, e la conferma gliela \
        dai dopo rileggendo cosa hai fatto.

        \(profileBlock)

        \(persona ?? "")

        Adesso e' \(now), fuso orario \(TimeZone.current.identifier).
        Quando passi una data a uno strumento usa il formato \(AssistantTools.dateFormat) \
        in ora locale.

        \(contextProvider?() ?? "")
        """
    }
}

import Foundation

/// Streaming client for Anthropic's Messages API.
///
/// Swift has no official SDK, so we speak HTTP directly. Streaming lets the
/// voice start on the first sentence instead of when the reply is complete:
/// in the car the difference between 800 ms and 4 s is the whole experience.
struct ClaudeTurn {
    /// The blocks exactly as they arrived, to be sent back unchanged
    /// (thinking blocks must be echoed back to the same model).
    var content: [[String: Any]] = []
    var stopReason: String?
    var toolUses: [(id: String, name: String, input: [String: Any])] = []
}

enum ClaudeError: LocalizedError {
    case noKey
    case http(Int, String)
    /// The point at which it stopped: tells you right away whether it's the network or the streaming.
    case timeout(phase: String, seconds: Double)

    var errorDescription: String? {
        switch self {
        case .noKey:
            return "Chiave API mancante"
        case let .http(code, body):
            return "\(Self.readable(body, code: code))"
        case let .timeout(phase, seconds):
            return String(format: "Scaduto dopo %.0f s — %@", seconds, phase)
        }
    }

    /// The error body is JSON: showing it raw on a phone in a car is useless,
    /// so we pull out the message and translate the known cases.
    private static func readable(_ body: String, code: Int) -> String {
        var message = body
        if let data = body.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any],
           let m = err["message"] as? String {
            message = m
        }
        if message.contains("anthropic-workspace-id") {
            return "La chiave non è legata a un workspace. Metti l'id del workspace nelle impostazioni, oppure crea una nuova chiave dentro un workspace su console.anthropic.com."
        }
        if message.contains("credit balance") || message.contains("insufficient") {
            return "Credito esaurito su console.anthropic.com."
        }
        if code == 401 {
            return "Chiave API non valida."
        }
        if code == 429 {
            return "Troppe richieste, riprova fra poco."
        }
        return "Errore \(code): \(message.prefix(160))"
    }
}

final class ClaudeClient {
    var apiKey: String = ""
    /// Only needed if the key is organization-level and not already bound to a
    /// workspace: in that case the API requires it as a header.
    var workspaceID: String = ""
    /// Opus 5: thinking is on by default; low effort keeps latency under
    /// control without turning it off (turning it off on Opus 5 can make tool
    /// calls end up inside the visible text).
    var model = "claude-opus-5"
    var effort = "low"
    var maxTokens = 2000

    /// Haiku has no `effort` parameter and returns 400 if you send it.
    private var supportsEffort: Bool { !model.contains("haiku") }
    /// Server-side fallbacks are on the flagship models.
    private var supportsFallbacks: Bool {
        model.contains("opus-5") || model.contains("fable")
    }

    var diagnostics: Diagnostics?

    /// Dedicated session: what matters when streaming is the time between one
    /// packet and the next, not the total duration, which with a long reply can
    /// easily exceed a minute.
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 40      // maximum silence between two packets
        c.timeoutIntervalForResource = 300    // total duration allowed
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    private var task: Task<Void, Never>?
    private(set) var isStreaming = false

    func cancel() { task?.cancel() }

    func send(system: String,
              messages: [[String: Any]],
              tools: [[String: Any]],
              onText: @escaping (String) -> Void) async throws -> ClaudeTurn {
        guard !apiKey.isEmpty else { throw ClaudeError.noKey }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "system": system,
            "messages": messages
        ]
        // Not all models accept the same parameters: Haiku rejects `effort`, and
        // server-side fallbacks only exist on the flagship models.
        if supportsEffort { body["output_config"] = ["effort": effort] }
        if supportsFallbacks { body["fallbacks"] = "default" }
        if !tools.isEmpty { body["tools"] = tools }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 40
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if supportsFallbacks {
            req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        if !workspaceID.isEmpty {
            req.setValue(workspaceID, forHTTPHeaderField: "anthropic-workspace-id")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let started = Date()
        let size = req.httpBody?.count ?? 0
        await log("invio a \(model): \(messages.count) messaggi, \(tools.count) strumenti, \(size / 1024) kB")

        var phase = "nessuna risposta dal server"
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: req)
        } catch let e as URLError where e.code == .timedOut {
            await log("scaduto: \(phase)")
            throw ClaudeError.timeout(phase: phase, seconds: Date().timeIntervalSince(started))
        }
        phase = "risposta iniziata ma interrotta a metà"
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        await log(String(format: "risposta %d dopo %.1f s", status, Date().timeIntervalSince(started)))

        if status != 200 {
            var text = ""
            for try await line in bytes.lines { text += line }
            throw ClaudeError.http(status, text)
        }
        var firstTokenLogged = false

        var turn = ClaudeTurn()
        var blocks: [Int: [String: Any]] = [:]
        var jsonBuffers: [Int: String] = [:]

        do {
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            guard let data = payload.data(using: .utf8),
                  let ev = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = ev["type"] as? String else { continue }

            switch type {
            case "content_block_start":
                if let i = ev["index"] as? Int, let b = ev["content_block"] as? [String: Any] {
                    blocks[i] = b
                    // Server-side tools (web_search) also stream their input,
                    // but they must NOT be executed here: Anthropic executes them.
                    let t = b["type"] as? String
                    if t == "tool_use" || t == "server_tool_use" { jsonBuffers[i] = "" }
                }

            case "content_block_delta":
                guard let i = ev["index"] as? Int, let d = ev["delta"] as? [String: Any],
                      let dt = d["type"] as? String else { break }
                switch dt {
                case "text_delta":
                    let t = d["text"] as? String ?? ""
                    if !firstTokenLogged {
                        firstTokenLogged = true
                        await log(String(format: "prima parola dopo %.2f s",
                                         Date().timeIntervalSince(started)))
                    }
                    let existing = (blocks[i]?["text"] as? String) ?? ""
                    blocks[i]?["text"] = existing + t
                    onText(t)                       // only text goes to voice, never thinking
                case "thinking_delta":
                    let t = d["thinking"] as? String ?? ""
                    let existing = (blocks[i]?["thinking"] as? String) ?? ""
                    blocks[i]?["thinking"] = existing + t
                case "signature_delta":
                    blocks[i]?["signature"] = d["signature"] as? String ?? ""
                case "input_json_delta":
                    jsonBuffers[i, default: ""] += (d["partial_json"] as? String ?? "")
                default: break
                }

            case "content_block_stop":
                if let i = ev["index"] as? Int, let raw = jsonBuffers[i] {
                    let parsed = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
                    blocks[i]?["input"] = parsed ?? [:]
                }

            case "message_delta":
                if let d = ev["delta"] as? [String: Any] {
                    turn.stopReason = d["stop_reason"] as? String ?? turn.stopReason
                }

            case "error":
                let msg = ((ev["error"] as? [String: Any])?["message"] as? String) ?? "errore sconosciuto"
                throw ClaudeError.http(0, msg)

            default: break
            }
        }
        } catch let e as URLError where e.code == .timedOut {
            await log("scaduto: \(phase)")
            throw ClaudeError.timeout(phase: phase, seconds: Date().timeIntervalSince(started))
        }

        turn.content = blocks.keys.sorted().compactMap { blocks[$0] }
        for b in turn.content where (b["type"] as? String) == "tool_use" {
            if let id = b["id"] as? String, let name = b["name"] as? String {
                turn.toolUses.append((id, name, (b["input"] as? [String: Any]) ?? [:]))
            }
        }
        await log("fine risposta: \(turn.stopReason ?? "?"), \(turn.toolUses.count) strumenti richiesti")
        return turn
    }

    @MainActor
    private func log(_ text: String) { diagnostics?.log("claude", text) }
}

import Foundation

/// Slack and Notion without going through the Mac.
///
/// These were the two integrations that lived only on the laptop, and so
/// disappeared as soon as you left it at home. Neither requires a real OAuth
/// flow: you create the token once, paste it, and they work anywhere there's
/// signal.
enum Integrations {

    static var slackToken = ""
    static var notionToken = ""
    static var notionParent = ""

    static func specs(slack: Bool, notion: Bool) -> [[String: Any]] {
        var out: [[String: Any]] = []
        if slack {
            out.append([
                "name": "slack_messaggio",
                "description": "Manda un messaggio su Slack. Usalo quando dice «scrivi a», «avvisa», «di' al team». Il canale puo' essere un nome come general o un identificativo; per un messaggio diretto serve l'identificativo della persona.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "canale": ["type": "string", "description": "Nome del canale senza cancelletto, o identificativo"],
                        "testo": ["type": "string"]
                    ],
                    "required": ["canale", "testo"],
                    "additionalProperties": false
                ],
                "strict": true
            ])
        }
        if notion {
            out.append([
                "name": "notion_crea",
                "description": "Crea una pagina su Notion sotto la pagina principale configurata. Usalo per appunti lunghi, verbali, documenti dettati.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "titolo": ["type": "string"],
                        "contenuto": ["type": "string", "description": "Il testo, i paragrafi separati da righe vuote"]
                    ],
                    "required": ["titolo", "contenuto"],
                    "additionalProperties": false
                ],
                "strict": true
            ])
            out.append([
                "name": "notion_cerca",
                "description": "Cerca fra le pagine di Notion e restituisce i titoli trovati.",
                "input_schema": [
                    "type": "object",
                    "properties": ["query": ["type": "string"]],
                    "required": ["query"],
                    "additionalProperties": false
                ],
                "strict": true
            ])
        }
        return out
    }

    static func handles(_ name: String) -> Bool {
        name.hasPrefix("slack_") || name.hasPrefix("notion_")
    }

    static func execute(name: String, input: [String: Any]) async -> String {
        switch name {
        case "slack_messaggio":
            return await slackPost(channel: (input["canale"] as? String) ?? "",
                                   text: (input["testo"] as? String) ?? "")
        case "notion_crea":
            return await notionCreate(title: (input["titolo"] as? String) ?? "",
                                      body: (input["contenuto"] as? String) ?? "")
        case "notion_cerca":
            return await notionSearch((input["query"] as? String) ?? "")
        default:
            return "Strumento sconosciuto: \(name)"
        }
    }

    // MARK: - Slack

    private static func slackPost(channel: String, text: String) async -> String {
        guard !slackToken.isEmpty else { return "Manca il token Slack nelle impostazioni." }
        guard !channel.isEmpty, !text.isEmpty else { return "Errore: canale o testo mancante." }

        var r = URLRequest(url: URL(string: "https://slack.com/api/chat.postMessage")!)
        r.httpMethod = "POST"
        r.timeoutInterval = 20
        r.setValue("Bearer \(slackToken)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let name = channel.hasPrefix("#") ? String(channel.dropFirst()) : channel
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["channel": name, "text": text])

        guard let (data, _) = try? await URLSession.shared.data(for: r),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Slack non raggiungibile."
        }
        if (json["ok"] as? Bool) == true {
            return "Messaggio mandato su \(name)."
        }
        let err = (json["error"] as? String) ?? "errore sconosciuto"
        // Slack errors are codes: they need translating, since they'll be read aloud.
        let readable: String
        switch err {
        case "channel_not_found": readable = "il canale \(name) non esiste o il bot non e' stato invitato"
        case "not_in_channel":    readable = "il bot non e' dentro il canale \(name)"
        case "invalid_auth", "not_authed": readable = "il token Slack non e' valido"
        case "missing_scope":     readable = "al token Slack manca il permesso di scrivere"
        default:                  readable = err
        }
        return "Slack ha rifiutato: \(readable)."
    }

    // MARK: - Notion

    private static func notionRequest(_ path: String, method: String,
                                      body: [String: Any]?) -> URLRequest? {
        guard let url = URL(string: "https://api.notion.com/v1" + path) else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = 20
        r.setValue("Bearer \(notionToken)", forHTTPHeaderField: "Authorization")
        r.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { r.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        return r
    }

    private static func notionCreate(title: String, body: String) async -> String {
        guard !notionToken.isEmpty else { return "Manca il token Notion nelle impostazioni." }
        guard !notionParent.isEmpty else {
            return "Manca la pagina principale di Notion nelle impostazioni."
        }
        guard !title.isEmpty else { return "Errore: titolo mancante." }

        // Notion accepts at most 2000 characters per text block.
        let paragraphs = body
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .flatMap { chunk(String($0), 1800) }
            .prefix(90)

        let children: [[String: Any]] = paragraphs.map { text in
            ["object": "block", "type": "paragraph",
             "paragraph": ["rich_text": [["type": "text", "text": ["content": text]]]]]
        }

        let payload: [String: Any] = [
            "parent": ["page_id": notionParent],
            "properties": ["title": ["title": [["type": "text", "text": ["content": title]]]]],
            "children": children
        ]

        guard let req = notionRequest("/pages", method: "POST", body: payload),
              let (data, resp) = try? await URLSession.shared.data(for: req) else {
            return "Notion non raggiungibile."
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let msg = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["message"] as? String
            return "Notion ha risposto \(code): \(msg ?? "pagina non creata"). Ricorda di condividere la pagina principale con l'integrazione."
        }
        return "Pagina Notion creata: «\(title)»."
    }

    private static func notionSearch(_ query: String) async -> String {
        guard !notionToken.isEmpty else { return "Manca il token Notion nelle impostazioni." }
        guard let req = notionRequest("/search", method: "POST",
                                      body: ["query": query, "page_size": 8]),
              let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            return "Ricerca su Notion fallita."
        }
        guard !results.isEmpty else { return "Nessuna pagina trovata per «\(query)»." }

        var titles: [String] = []
        for page in results {
            guard let props = page["properties"] as? [String: Any] else { continue }
            for (_, value) in props {
                guard let v = value as? [String: Any],
                      (v["type"] as? String) == "title",
                      let arr = v["title"] as? [[String: Any]] else { continue }
                let t = arr.compactMap { $0["plain_text"] as? String }.joined()
                if !t.isEmpty { titles.append(t) }
            }
        }
        guard !titles.isEmpty else { return "Trovate \(results.count) pagine senza titolo leggibile." }
        return "Pagine trovate:\n" + titles.prefix(8).map { "- \($0)" }.joined(separator: "\n")
    }

    private static func chunk(_ s: String, _ size: Int) -> [String] {
        guard s.count > size else { return [s] }
        var out: [String] = []
        var rest = Substring(s)
        while !rest.isEmpty {
            let end = rest.index(rest.startIndex, offsetBy: min(size, rest.count))
            out.append(String(rest[..<end]))
            rest = rest[end...]
        }
        return out
    }
}

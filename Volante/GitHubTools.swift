import Foundation

/// Projects without going through the Mac.
///
/// The bridge to the Mac is powerful but fragile: if the laptop sleeps, it's
/// gone. The repositories are also on GitHub, though, and from there they can
/// be read from anywhere with a token in the keychain. It answers the
/// questions you actually ask in the car — «come sta arete-fw» ("how's
/// arete-fw doing"), «cosa ho committato ieri» ("what did I commit
/// yesterday"), «apri una issue» ("open an issue") — without depending on any
/// machine being on.
enum GitHubTools {

    static var token = ""
    static var owner = ""

    static let specs: [[String: Any]] = [
        [
            "name": "github_stato",
            "description": "Ultimi commit e issue aperte di un repository. Usalo per domande tipo «come sta X», «cosa ho fatto ieri su X», «cosa c'e' aperto su X».",
            "input_schema": [
                "type": "object",
                "properties": [
                    "repo": ["type": "string", "description": "Nome del repository, es. arete-fw"]
                ],
                "required": ["repo"],
                "additionalProperties": false
            ],
            "strict": true
        ],
        [
            "name": "github_cerca",
            "description": "Cerca del testo nel codice di un repository e restituisce i file che lo contengono.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "repo": ["type": "string"],
                    "query": ["type": "string", "description": "Testo o simbolo da cercare"]
                ],
                "required": ["repo", "query"],
                "additionalProperties": false
            ],
            "strict": true
        ],
        [
            "name": "github_leggi",
            "description": "Legge un file da un repository. Usalo per README, documenti di progetto, file di configurazione.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "repo": ["type": "string"],
                    "percorso": ["type": "string", "description": "Percorso del file nel repo, es. README.md"]
                ],
                "required": ["repo", "percorso"],
                "additionalProperties": false
            ],
            "strict": true
        ],
        [
            "name": "github_issue",
            "description": "Apre una issue su un repository. Usalo quando l'utente dice «segnati», «apri un task», «non dimenticarti di sistemare» riferito a un progetto.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "repo": ["type": "string"],
                    "titolo": ["type": "string"],
                    "corpo": ["type": "string", "description": "Descrizione, anche breve"]
                ],
                "required": ["repo", "titolo"],
                "additionalProperties": false
            ],
            "strict": true
        ]
    ]

    // MARK: - Execution

    static func execute(name: String, input: [String: Any]) async -> String {
        guard !token.isEmpty else {
            return "Manca il token GitHub nelle impostazioni dell'app."
        }
        let repo = fullName((input["repo"] as? String) ?? "")
        switch name {
        case "github_stato":  return await status(repo)
        case "github_cerca":  return await search(repo, (input["query"] as? String) ?? "")
        case "github_leggi":  return await readFile(repo, (input["percorso"] as? String) ?? "")
        case "github_issue":
            return await createIssue(repo,
                                     title: (input["titolo"] as? String) ?? "",
                                     body: (input["corpo"] as? String) ?? "")
        default: return "Strumento GitHub sconosciuto: \(name)"
        }
    }

    /// In-car transcription gets names wrong: «arete effe vu» -> arete-fw.
    private static func fullName(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.contains("/") { return t }
        let cleaned = t.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
        return "\(owner)/\(cleaned)"
    }

    private static func get(_ path: String) async -> Any? {
        guard let url = URL(string: "https://api.github.com" + path) else { return nil }
        var r = URLRequest(url: url)
        r.timeoutInterval = 20
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        guard let (data, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func status(_ repo: String) async -> String {
        async let commitsTask = get("/repos/\(repo)/commits?per_page=5")
        async let issuesTask = get("/repos/\(repo)/issues?state=open&per_page=5")
        let (commits, issues) = await (commitsTask, issuesTask)

        guard let list = commits as? [[String: Any]] else {
            return "Non riesco a leggere \(repo). Nome sbagliato o token senza accesso?"
        }
        var out = "Repository \(repo).\nUltimi commit:\n"
        let df = ISO8601DateFormatter()
        let human = DateFormatter()
        human.locale = Locale(identifier: "it_IT")
        human.dateFormat = "d MMMM HH:mm"
        for c in list {
            let commit = c["commit"] as? [String: Any]
            let msg = (commit?["message"] as? String)?
                .split(separator: "\n").first.map(String.init) ?? "senza messaggio"
            var when = ""
            if let author = commit?["author"] as? [String: Any],
               let raw = author["date"] as? String, let d = df.date(from: raw) {
                when = human.string(from: d) + " — "
            }
            out += "- \(when)\(msg)\n"
        }
        if let iss = issues as? [[String: Any]] {
            let real = iss.filter { $0["pull_request"] == nil }
            out += real.isEmpty
                ? "Nessuna issue aperta."
                : "Issue aperte (\(real.count)):\n" + real.map {
                    "- #\($0["number"] as? Int ?? 0) \($0["title"] as? String ?? "")"
                  }.joined(separator: "\n")
        }
        return out
    }

    private static func search(_ repo: String, _ query: String) async -> String {
        let q = "\(query) repo:\(repo)"
        guard let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let json = await get("/search/code?q=\(encoded)&per_page=8") as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            return "Ricerca fallita su \(repo). Il token deve avere accesso al repository."
        }
        guard !items.isEmpty else { return "Nessun risultato per «\(query)» in \(repo)." }
        let total = json["total_count"] as? Int ?? items.count
        return "\(total) risultati per «\(query)» in \(repo). Primi file:\n"
            + items.map { "- \($0["path"] as? String ?? "")" }.joined(separator: "\n")
    }

    private static func readFile(_ repo: String, _ path: String) async -> String {
        let clean = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let encoded = clean.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let json = await get("/repos/\(repo)/contents/\(encoded)") as? [String: Any],
              let b64 = (json["content"] as? String)?.replacingOccurrences(of: "\n", with: ""),
              let data = Data(base64Encoded: b64),
              let text = String(data: data, encoding: .utf8) else {
            return "Non riesco a leggere \(clean) da \(repo)."
        }
        // In the car what matters is the content, not the length: truncate and let Claude summarize.
        let limit = 6000
        return text.count > limit
            ? String(text.prefix(limit)) + "\n…(file troncato)"
            : text
    }

    private static func createIssue(_ repo: String, title: String, body: String) async -> String {
        guard !title.isEmpty else { return "Errore: titolo mancante." }
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/issues") else {
            return "Repository non valido."
        }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.timeoutInterval = 20
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: [
            "title": title,
            "body": body.isEmpty ? "Aperta a voce da Volante mentre guidavo." : body
        ])
        guard let (data, resp) = try? await URLSession.shared.data(for: r) else {
            return "Rete non raggiungibile."
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 201,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = json["number"] as? Int else {
            return "GitHub ha risposto \(code): issue non creata."
        }
        return "Issue numero \(number) aperta su \(repo): «\(title)»."
    }
}

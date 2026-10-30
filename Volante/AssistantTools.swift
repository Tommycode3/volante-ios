import Foundation
import EventKit

/// The tools Claude can use while you drive. All local: calendar,
/// reminders and notes. None of them can do irreversible damage, and each
/// returns a sentence that Claude reads back aloud as confirmation —
/// in the car you can't verify anything with your eyes.
enum AssistantTools {

    static let store = EKEventStore()

    /// Time format we ask Claude for: local time, no time zone, no ambiguity.
    static let dateFormat = "yyyy-MM-dd HH:mm"

    static func parseDate(_ raw: String) -> Date? { formatter.date(from: raw) }

    private static var formatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = dateFormat
        f.timeZone = .current
        return f
    }

    /// The Mac is a bonus, not a requirement. It's offered only if configured,
    /// and only for what nothing else can do: editing files, and the
    /// integrations that live there (Slack, mail, Notion, Drive).
    static let macSpec: [String: Any] = [
        "name": "manda_al_mac",
        "description": """
        Manda un lavoro al Claude Code che gira sul Mac dell'utente. Usalo quando serve \
        MODIFICARE file o codice, oppure per Slack, email, Notion e Google Drive, che \
        stanno solo la'. Per sapere come sta un progetto, leggere un file o aprire una \
        issue usa invece gli strumenti github: funzionano sempre, anche a Mac spento. \
        Il risultato NON arriva adesso: il lavoro parte e l'utente viene avvisato a voce \
        quando e' pronto, anche dopo minuti. Scrivi la richiesta autosufficiente, come se \
        la leggesse qualcuno che non ha sentito questa conversazione. Se lo strumento \
        risponde che il Mac non e' raggiungibile, dillo in una frase e proponi l'alternativa.
        """,
        "input_schema": [
            "type": "object",
            "properties": [
                "richiesta": ["type": "string", "description": "Il compito, completo e autosufficiente"],
                "progetto": ["type": "string", "description": "Nome del progetto o repository, se ne ha nominato uno"]
            ],
            "required": ["richiesta"],
            "additionalProperties": false
        ],
        "strict": true
    ]

    /// The tools offered change depending on what's configured: every unused
    /// schema is dead weight in every single request, and with Haiku it matters.
    static func specs(bridgeConfigured: Bool, githubConfigured: Bool,
                      slack: Bool, notion: Bool, model: String) -> [[String: Any]] {
        var out = localSpecs
        out.append(dictationSpec)
        if githubConfigured { out += GitHubTools.specs }
        out += Integrations.specs(slack: slack, notion: notion)
        if let web = webSearchSpec(model: model) { out.append(web) }
        if bridgeConfigured { out.append(macSpec) }
        return out
    }

    /// The only clean way to enter long dictation without inventing a third
    /// gesture on the steering wheel: you ask for it by voice.
    static let dictationSpec: [String: Any] = [
        "name": "avvia_dettatura",
        "description": """
        Avvia la dettatura lunga: il microfono resta aperto e il silenzio non chiude \
        niente, cosi' puo' ragionare ad alta voce per minuti. Usalo quando dice \
        «dettatura», «voglio ragionare», «fammi pensare ad alta voce», «prendi tutto \
        quello che dico». Per un appunto breve NON serve: quello lo fa gia' il doppio \
        tap al volante.
        """,
        "input_schema": ["type": "object", "properties": [:], "required": [],
                         "additionalProperties": false],
        "strict": true
    ]

    /// Web search runs on Anthropic's servers, nothing to configure.
    /// Haiku doesn't have it, though: offering it there makes the whole request
    /// fail, so with that model it goes without — and switches to Sonnet when a
    /// search is needed.
    private static func webSearchSpec(model: String) -> [String: Any]? {
        guard !model.contains("haiku") else { return nil }
        return ["type": "web_search_20260209", "name": "web_search", "max_uses": 4]
    }

    static let localSpecs: [[String: Any]] = [
        [
            "name": "crea_evento",
            "description": "Crea un evento nel calendario dell'utente. Usa l'ora locale nel formato \(dateFormat).",
            "input_schema": [
                "type": "object",
                "properties": [
                    "titolo": ["type": "string", "description": "Titolo dell'evento"],
                    "inizio": ["type": "string", "description": "Inizio, formato \(dateFormat)"],
                    "durata_minuti": ["type": "integer", "description": "Durata in minuti (default 60)"],
                    "note": ["type": "string", "description": "Note opzionali"],
                    "luogo": ["type": "string", "description": "Luogo opzionale"]
                ],
                "required": ["titolo", "inizio"],
                "additionalProperties": false
            ],
            "strict": true
        ],
        [
            "name": "crea_promemoria",
            "description": "Crea un promemoria nell'app Promemoria, con scadenza opzionale.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "testo": ["type": "string", "description": "Cosa ricordare"],
                    "scadenza": ["type": "string", "description": "Scadenza opzionale, formato \(dateFormat)"]
                ],
                "required": ["testo"],
                "additionalProperties": false
            ],
            "strict": true
        ],
        [
            "name": "salva_nota",
            "description": "Salva una nota di testo nel taccuino dell'app, ancorata all'episodio in ascolto.",
            "input_schema": [
                "type": "object",
                "properties": ["testo": ["type": "string"]],
                "required": ["testo"],
                "additionalProperties": false
            ],
            "strict": true
        ],
        [
            "name": "registra_contatto",
            "description": """
            Registra che ha parlato con qualcuno e cosa si sono detti. Usalo ogni volta \
            che nomina una conversazione avuta: «ho sentito», «ho parlato con», «gli ho \
            detto», «mi ha promesso». Se emerge un impegno preso da lui o dall'altro, \
            mettilo in `impegno`.
            """,
            "input_schema": [
                "type": "object",
                "properties": [
                    "persona": ["type": "string"],
                    "cosa": ["type": "string", "description": "Riassunto in una frase"],
                    "impegno": ["type": "string", "description": "Cosa è stato promesso, se c'è"],
                    "impegno_suo": ["type": "boolean", "description": "true se l'impegno è dell'altra persona"],
                    "scadenza": ["type": "string", "description": "Formato \(dateFormat)"]
                ],
                "required": ["persona", "cosa"],
                "additionalProperties": false
            ],
            "strict": true
        ],
        [
            "name": "scheda_persona",
            "description": "Cosa sai di una persona: ultimi contatti, impegni in sospeso, da quanto non la sente. Usalo prima di un incontro o quando la nomina.",
            "input_schema": [
                "type": "object",
                "properties": ["nome": ["type": "string"]],
                "required": ["nome"],
                "additionalProperties": false
            ],
            "strict": true
        ],
        [
            "name": "persone_da_risentire",
            "description": "Chi non sente da più di N giorni. Usalo per «chi mi sto perdendo», «chi devo risentire».",
            "input_schema": [
                "type": "object",
                "properties": ["giorni": ["type": "integer"]],
                "required": ["giorni"],
                "additionalProperties": false
            ],
            "strict": true
        ],
        [
            "name": "manda_messaggio",
            "description": """
            Manda un messaggio a una persona sul suo canale. Usalo per «scrivi a», \
            «avvisa», «digli che». Rileggi sempre il testo ad alta voce prima di usarlo e \
            aspetta che confermi: un messaggio parte una volta sola. \
            Su WhatsApp NON parte da solo — iOS non lo consente a nessuna app che non sia \
            WhatsApp: resta pronto e gli basta un tocco quando è fermo. Dillo in una frase \
            senza scusarti, e ricordagli che per l'invio immediato senza mani può dire \
            «Ehi Siri, manda un messaggio WhatsApp a…».
            """,
            "input_schema": [
                "type": "object",
                "properties": [
                    "persona": ["type": "string"],
                    "testo": ["type": "string"]
                ],
                "required": ["persona", "testo"],
                "additionalProperties": false
            ],
            "strict": true
        ],
        [
            "name": "avvia_allenamento",
            "description": """
            Avvia una sessione di allenamento vocale. Tipi: «pitch» (lui parla, tu misuri \
            e critichi), «roleplay» (tu interpreti qualcuno di scomodo: investitore, \
            cliente, fornitore — specifica `ruolo`), «inglese» (conversazione in inglese \
            per tenerla allenata). Usalo quando dice «provo il pitch», «facciamo un \
            roleplay», «parliamo in inglese», «allenami».
            """,
            "input_schema": [
                "type": "object",
                "properties": [
                    "tipo": ["type": "string", "description": "pitch, roleplay o inglese"],
                    "ruolo": ["type": "string", "description": "Chi devi interpretare, per il roleplay"],
                    "durata_obiettivo": ["type": "integer", "description": "Secondi obiettivo per il pitch"]
                ],
                "required": ["tipo"],
                "additionalProperties": false
            ],
            "strict": true
        ],
        [
            "name": "cerca_note",
            "description": """
            Cerca fra le note vocali che l'utente ha dettato nei viaggi passati. \
            Sono la sua memoria: usale quando dice «cosa avevo detto su», «te ne \
            avevo parlato», «riprendi quella cosa di», o quando un riferimento \
            sembra venire da prima. Lascia la ricerca vuota per avere le ultime note.
            """,
            "input_schema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Parola o tema da cercare; vuoto = le più recenti"]
                ],
                "required": ["query"],
                "additionalProperties": false
            ],
            "strict": true
        ],
        [
            "name": "leggi_agenda",
            "description": "Legge gli eventi del calendario in una finestra di giorni a partire da oggi.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "giorni": ["type": "integer", "description": "Quanti giorni in avanti guardare (1 = solo oggi)"]
                ],
                "required": ["giorni"],
                "additionalProperties": false
            ],
            "strict": true
        ]
    ]

    // MARK: - Execution

    /// Everything the tools can touch, in one place: the parameter list was
    /// becoming unmanageable.
    @MainActor
    struct Context {
        var saveNote: (String) -> Void
        var searchNotes: (String) -> String
        var sendToMac: (String, String?) async -> String
        var people: PeopleStore
        var sendMessage: (String, String) async -> String
        var startTraining: (TrainingMode) -> Void
    }

    @MainActor
    static func execute(name: String, input: [String: Any], ctx: Context) async -> String {
        switch name {
        case "cerca_note":
            return ctx.searchNotes((input["query"] as? String) ?? "")

        // MARK: People
        case "registra_contatto":
            let who = (input["persona"] as? String) ?? ""
            guard !who.isEmpty else { return "Errore: manca il nome." }
            let person = ctx.people.record(
                name: who,
                summary: (input["cosa"] as? String) ?? "",
                promise: input["impegno"] as? String,
                due: (input["scadenza"] as? String).flatMap(parseDate),
                byThem: (input["impegno_suo"] as? Bool) ?? false)
            var out = "Segnato su \(person.name)."
            if let p = person.openPromises.first {
                out += " In sospeso: \(p.text)."
            }
            return out

        case "scheda_persona":
            return ctx.people.summary(for: (input["nome"] as? String) ?? "")

        case "persone_da_risentire":
            return ctx.people.stale(afterDays: (input["giorni"] as? Int) ?? 30)

        case "manda_messaggio":
            return await ctx.sendMessage((input["persona"] as? String) ?? "",
                                         (input["testo"] as? String) ?? "")

        // MARK: Training
        case "avvia_allenamento":
            let kind = ((input["tipo"] as? String) ?? "").lowercased()
            let mode: TrainingMode
            switch kind {
            case "pitch":
                mode = .pitch(target: Double((input["durata_obiettivo"] as? Int) ?? 120))
            case "inglese", "english":
                mode = .english
            default:
                mode = .roleplay(role: (input["ruolo"] as? String) ?? "un investitore scettico")
            }
            ctx.startTraining(mode)
            return "Sessione avviata: \(mode.label). Digli in una frase che può cominciare."
        case "manda_al_mac":
            let richiesta = (input["richiesta"] as? String) ?? ""
            guard !richiesta.isEmpty else { return "Errore: richiesta vuota." }
            return await ctx.sendToMac(richiesta, input["progetto"] as? String)
        case let n where n.hasPrefix("github_"):
            return await GitHubTools.execute(name: n, input: input)
        case let n where Integrations.handles(n):
            return await Integrations.execute(name: n, input: input)
        case "crea_evento":   return await createEvent(input)
        case "crea_promemoria": return await createReminder(input)
        case "leggi_agenda":  return await readAgenda(input)
        case "salva_nota":
            let testo = (input["testo"] as? String) ?? ""
            guard !testo.isEmpty else { return "Errore: nota vuota." }
            ctx.saveNote(testo)
            return "Nota salvata."
        default:
            return "Strumento sconosciuto: \(name)"
        }
    }

    private static func createEvent(_ input: [String: Any]) async -> String {
        guard let titolo = input["titolo"] as? String,
              let inizioRaw = input["inizio"] as? String,
              let inizio = formatter.date(from: inizioRaw) else {
            return "Errore: titolo o data non validi. La data deve essere nel formato \(dateFormat)."
        }
        do {
            guard try await store.requestWriteOnlyAccessToEvents() else {
                return "Accesso al calendario negato dall'utente."
            }
        } catch {
            return "Errore accesso calendario: \(error.localizedDescription)"
        }
        guard let cal = store.defaultCalendarForNewEvents else {
            return "Nessun calendario predefinito disponibile."
        }

        let minuti = (input["durata_minuti"] as? Int) ?? 60
        let e = EKEvent(eventStore: store)
        e.title = titolo
        e.startDate = inizio
        e.endDate = inizio.addingTimeInterval(Double(minuti) * 60)
        e.notes = input["note"] as? String
        e.location = input["luogo"] as? String
        e.calendar = cal
        e.addAlarm(EKAlarm(relativeOffset: -600))

        do {
            try store.save(e, span: .thisEvent)
            let f = DateFormatter()
            f.locale = Locale(identifier: "it_IT")
            f.dateStyle = .full; f.timeStyle = .short
            return "Evento creato: «\(titolo)» — \(f.string(from: inizio)), \(minuti) minuti."
        } catch {
            return "Errore nel salvataggio: \(error.localizedDescription)"
        }
    }

    private static func createReminder(_ input: [String: Any]) async -> String {
        guard let testo = input["testo"] as? String, !testo.isEmpty else {
            return "Errore: testo del promemoria mancante."
        }
        do {
            guard try await store.requestFullAccessToReminders() else {
                return "Accesso ai promemoria negato dall'utente."
            }
        } catch {
            return "Errore accesso promemoria: \(error.localizedDescription)"
        }
        guard let cal = store.defaultCalendarForNewReminders() else {
            return "Nessuna lista promemoria predefinita."
        }

        let r = EKReminder(eventStore: store)
        r.title = testo
        r.calendar = cal
        var quando = ""
        if let raw = input["scadenza"] as? String, let due = formatter.date(from: raw) {
            r.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due)
            r.addAlarm(EKAlarm(absoluteDate: due))
            let f = DateFormatter()
            f.locale = Locale(identifier: "it_IT"); f.dateStyle = .full; f.timeStyle = .short
            quando = " per \(f.string(from: due))"
        }
        do {
            try store.save(r, commit: true)
            return "Promemoria creato\(quando): «\(testo)»."
        } catch {
            return "Errore nel salvataggio: \(error.localizedDescription)"
        }
    }

    private static func readAgenda(_ input: [String: Any]) async -> String {
        do {
            guard try await store.requestFullAccessToEvents() else {
                return "Accesso in lettura al calendario negato."
            }
        } catch {
            return "Errore accesso calendario: \(error.localizedDescription)"
        }
        let giorni = max(1, (input["giorni"] as? Int) ?? 1)
        let start = Date()
        guard let end = Calendar.current.date(byAdding: .day, value: giorni, to: start) else {
            return "Intervallo non valido."
        }
        let pred = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: pred).sorted { $0.startDate < $1.startDate }
        guard !events.isEmpty else { return "Nessun evento nei prossimi \(giorni) giorni." }

        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "EEEE d MMMM, HH:mm"
        return events.prefix(12).map { "\(f.string(from: $0.startDate)) — \($0.title ?? "senza titolo")" }
            .joined(separator: "\n")
    }
}

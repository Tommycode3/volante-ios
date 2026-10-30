import Foundation
import Observation

/// The car as a gym.
///
/// You're alone, nobody can hear you, you have forty minutes: it's the best
/// place to practise the things that are embarrassing to practise at the
/// office. The pitch said aloud twenty times, the difficult conversation
/// rehearsed first with someone who pushes back, English kept warm.
enum TrainingMode: Equatable {
    case pitch(target: Double)      // target duration in seconds
    case roleplay(role: String)
    case english

    var label: String {
        switch self {
        case .pitch: return "Prova del pitch"
        case let .roleplay(role): return "Roleplay — \(role)"
        case .english: return "Inglese"
        }
    }

    /// Conversations happen in turns; the pitch is a single monologue.
    var isConversational: Bool {
        if case .pitch = self { return false }
        return true
    }

    var locale: String {
        if case .english = self { return "en-US" }
        return "it-IT"
    }
}

/// What can be measured without asking anyone anything: speed, filler
/// words, duration. Claude adds the judgement, but numbers are numbers and
/// don't cost a cent.
struct SpeechMetrics {
    var words: Int
    var seconds: Double
    var fillers: [(String, Int)]

    var wordsPerMinute: Double {
        seconds > 0 ? Double(words) / seconds * 60 : 0
    }
    var fillerCount: Int { fillers.reduce(0) { $0 + $1.1 } }
    var fillerRate: Double {
        words > 0 ? Double(fillerCount) / Double(words) * 100 : 0
    }

    /// Meant to be read aloud, not looked at.
    var spoken: String {
        var out = String(format: "%.0f secondi, %d parole, %.0f parole al minuto",
                         seconds, words, wordsPerMinute)
        if fillerCount > 0 {
            let top = fillers.prefix(3).map { "\($0.0) \($0.1) volte" }.joined(separator: ", ")
            out += ". Riempitivi: \(top)"
        } else {
            out += ". Nessun riempitivo"
        }
        return out
    }

    var compact: String {
        String(format: "%.0fs · %.0f ppm · %d riempitivi", seconds, wordsPerMinute, fillerCount)
    }
}

enum TalkMetrics {
    private static let italian = [
        "cioè", "diciamo", "praticamente", "insomma", "ecco", "tipo", "ehm", "mmm",
        "allora", "in pratica", "come dire", "boh", "no?", "capito", "va beh"
    ]
    private static let english = [
        "um", "uh", "like", "you know", "actually", "basically", "i mean",
        "sort of", "kind of", "right?", "so yeah", "literally"
    ]

    static func measure(_ text: String, seconds: Double, locale: String) -> SpeechMetrics {
        let lower = " " + text.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil) + " "
        let list = locale.hasPrefix("en") ? english : italian

        var found: [(String, Int)] = []
        for filler in list {
            let needle = " " + filler.folding(options: .diacriticInsensitive, locale: nil) + " "
            let n = lower.components(separatedBy: needle).count - 1
            if n > 0 { found.append((filler, n)) }
        }
        found.sort { $0.1 > $1.1 }

        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        return SpeechMetrics(words: words, seconds: seconds, fillers: found)
    }
}

/// A saved attempt, to see whether you're improving.
struct TrainingRun: Codable, Identifiable, Hashable {
    var id = UUID()
    var at = Date()
    var mode: String
    var seconds: Double
    var words: Int
    var fillerCount: Int
    var transcript: String
    var feedback: String = ""

    var wordsPerMinute: Double { seconds > 0 ? Double(words) / seconds * 60 : 0 }
}

@MainActor
@Observable
final class TrainingStore {
    private(set) var runs: [TrainingRun] = []

    private var fileURL: URL { Paths.documents.appendingPathComponent("allenamenti.json") }

    init() { load() }

    func load() {
        guard let d = try? Data(contentsOf: fileURL),
              let r = try? JSONDecoder().decode([TrainingRun].self, from: d) else { return }
        runs = r
    }

    func add(_ run: TrainingRun) {
        runs.insert(run, at: 0)
        if runs.count > 200 { runs.removeLast() }
        save()
    }

    func setFeedback(_ text: String, for id: UUID) {
        guard let i = runs.firstIndex(where: { $0.id == id }) else { return }
        runs[i].feedback = text
        save()
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(runs) { try? d.write(to: fileURL) }
    }

    /// «Stai migliorando?» ("Am I improving?") must be answered with the numbers from previous attempts.
    func trend(for mode: String, limit: Int = 5) -> String {
        let past = runs.filter { $0.mode == mode }.prefix(limit)
        guard past.count > 1 else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "d MMM"
        return "Prove precedenti:\n" + past.dropFirst().map {
            String(format: "- %@: %.0fs, %.0f ppm, %d riempitivi",
                   f.string(from: $0.at), $0.seconds, $0.wordsPerMinute, $0.fillerCount)
        }.joined(separator: "\n")
    }
}

// MARK: - Instructions for Claude

extension TrainingMode {
    /// The block appended to the system prompt for the duration of the session.
    var persona: String {
        switch self {
        case let .pitch(target):
            return """
            SESSIONE: prova del pitch. L'utente ti ha appena detto il suo pitch ad alta voce \
            mentre guidava, e la trascrizione può avere errori: giudica il contenuto, non la \
            punteggiatura. Obiettivo di durata: \(Int(target)) secondi.

            Dagli un ritorno onesto e specifico, non incoraggiamenti generici. Al massimo \
            quattro frasi, e in questo ordine: la cosa che funziona meglio; il punto in cui \
            si perde; il numero che conta di più fra quelli misurati; una sola cosa da \
            cambiare al prossimo tentativo. Se un passaggio è confuso, ripetigli come l'hai \
            capito tu — sentirlo restituito male è il modo più veloce per accorgersene.
            """
        case let .roleplay(role):
            return """
            SESSIONE: prova di una conversazione difficile. Da adesso NON sei l'assistente: \
            interpreti \(role) che parla con l'utente. Resta nel personaggio, sii realistico \
            e un po' scomodo — le obiezioni vere, non quelle di cortesia. Una o due frasi \
            per turno, come si parla davvero. Non spiegare mai che stai recitando. \
            Se ti dice «basta» o «fine», esci dal personaggio e in tre frasi digli dov'è \
            stato debole e cosa rifarebbe meglio.
            """
        case .english:
            return """
            SESSION: English practice. Speak only English from now on, at a natural pace, \
            two sentences per turn. Keep the conversation going with real questions about \
            his work and his projects. Do NOT correct him mid-conversation: \
            it breaks the flow and he is driving. Keep note of his mistakes silently. \
            When he says «stop» or «basta», switch to Italian and give him the three \
            corrections that matter most, with the right phrasing.
            """
        }
    }
}

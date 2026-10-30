import Foundation
import Observation

struct VoiceNote: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var audioFileName: String
    var transcript: String = ""
    var duration: Double = 0
    /// Anchoring to the episode: what I was listening to and at which minute.
    var episodeTitle: String?
    var episodeGuid: String?
    var episodePosition: Double?
    var showTitle: String?
    /// The audio URL: feeds rotate and an old episode can drop out of the
    /// library. Keeping it here, «riascolta da qui» ("replay from here") works
    /// forever.
    var episodeAudioURL: URL?
    /// The podcast's words in the seconds before the note: extracted on demand
    /// from the downloaded file, not kept for every episode.
    var episodeQuote: String?

    var audioURL: URL { Paths.notesAudio.appendingPathComponent(audioFileName) }
    var isAnchored: Bool { episodeGuid != nil && episodePosition != nil }

    var positionLabel: String? {
        guard let p = episodePosition else { return nil }
        let s = Int(p)
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

@MainActor
@Observable
final class NoteStore {
    private(set) var notes: [VoiceNote] = []

    private var fileURL: URL { Paths.documents.appendingPathComponent("note.json") }

    init() { load() }

    func load() {
        guard let d = try? Data(contentsOf: fileURL),
              let n = try? JSONDecoder().decode([VoiceNote].self, from: d) else { return }
        notes = n.sorted { $0.createdAt > $1.createdAt }
    }

    func add(_ note: VoiceNote) {
        notes.insert(note, at: 0)
        save()
    }

    func updateTranscript(fileName: String, transcript: String) {
        guard let i = notes.firstIndex(where: { $0.audioFileName == fileName }) else { return }
        notes[i].transcript = transcript
        save()
    }

    func update(_ note: VoiceNote) {
        guard let i = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[i] = note
        save()
    }

    func setQuote(_ quote: String, for id: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].episodeQuote = quote
        save()
    }

    func note(_ id: UUID) -> VoiceNote? { notes.first { $0.id == id } }

    func delete(_ note: VoiceNote) {
        if !note.audioFileName.isEmpty { try? FileManager.default.removeItem(at: note.audioURL) }
        notes.removeAll { $0.id == note.id }
        save()
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(notes) { try? d.write(to: fileURL) }
        writeMarkdown()
    }

    /// Readable copy, exportable from the Files app without going through the JSON.
    private func writeMarkdown() {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var out = "# Note vocali — Volante\n\n"
        for n in notes {
            out += "## \(f.string(from: n.createdAt))\n\n"
            if let t = n.episodeTitle {
                out += "_Mentre ascoltavo: \(t)"
                if let p = n.positionLabel { out += " — \(p)" }
                out += "_\n\n"
            }
            if let q = n.episodeQuote, !q.isEmpty {
                out += "> \(q)\n\n"
            }
            out += (n.transcript.isEmpty ? "*(trascrizione non disponibile)*" : n.transcript) + "\n\n"
            out += "`\(n.audioFileName)`\n\n---\n\n"
        }
        try? out.write(to: Paths.documents.appendingPathComponent("note.md"),
                       atomically: true, encoding: .utf8)
    }

    /// Notes are the memory: what you said while driving last week must be
    /// findable by speaking, not just by scrolling a list.
    func search(_ query: String, limit: Int = 8) -> String {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let pool = q.isEmpty
            ? Array(notes.prefix(limit))
            : notes.filter { $0.transcript.lowercased().contains(q) }.prefix(limit).map { $0 }

        guard !pool.isEmpty else {
            return notes.isEmpty
                ? "Non c'è ancora nessuna nota."
                : "Nessuna nota contiene «\(query)». In archivio ce ne sono \(notes.count)."
        }

        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "d MMMM, HH:mm"
        return pool.map { n in
            var head = f.string(from: n.createdAt)
            if let t = n.episodeTitle {
                head += " — mentre ascoltavo \(t.prefix(60))"
                if let p = n.positionLabel { head += " al \(p)" }
            }
            return "[\(head)]\n\(n.transcript.prefix(600))"
        }.joined(separator: "\n\n")
    }

    var exportText: String {
        (try? String(contentsOf: Paths.documents.appendingPathComponent("note.md"), encoding: .utf8)) ?? ""
    }
}

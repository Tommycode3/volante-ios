import Foundation
import Observation

/// People, captured by voice.
///
/// Anyone doing hardware has to keep suppliers, customers and investors warm
/// all at once, and the memory of «cosa ci eravamo detti» ("what we said to
/// each other") evaporates in two weeks. This isn't a CRM: it's a log that
/// fills up as you talk while driving, and that can tell you who you haven't
/// heard from in too long.
struct Person: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var role: String = ""
    /// How to reach them: fill it in once, then the name is enough.
    var slackChannel: String = ""
    var telegramChatID: String = ""
    var email: String = ""
    /// Number in international format without spaces or symbols, e.g. 393331234567.
    /// Needed for WhatsApp: it can't send on your behalf, but it can prepare the
    /// message and leave you a single tap.
    var phone: String = ""

    var interactions: [Interaction] = []
    var promises: [Promise] = []

    var lastContact: Date? { interactions.first?.at }

    var daysSinceContact: Int? {
        guard let d = lastContact else { return nil }
        return Calendar.current.dateComponents([.day], from: d, to: Date()).day
    }

    var openPromises: [Promise] { promises.filter { !$0.done } }

    var reachable: Bool {
        !slackChannel.isEmpty || !telegramChatID.isEmpty || !email.isEmpty || !phone.isEmpty
    }

    /// Digits only: people write «+39 333 123 4567» and wa.me wants «393331234567».
    var whatsappNumber: String {
        phone.filter(\.isNumber)
    }
}

struct Interaction: Codable, Identifiable, Hashable {
    var id = UUID()
    var at = Date()
    var summary: String
}

struct Promise: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var due: Date?
    var done = false
    var byThem = false          // if they promised it to you
}

@MainActor
@Observable
final class PeopleStore {
    private(set) var people: [Person] = []

    private var fileURL: URL { Paths.documents.appendingPathComponent("persone.json") }

    init() { load() }

    func load() {
        guard let d = try? Data(contentsOf: fileURL),
              let p = try? JSONDecoder().decode([Person].self, from: d) else { return }
        people = p
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(people) { try? d.write(to: fileURL) }
    }

    // MARK: - Fuzzy search
    //
    // Transcription from a moving car gets names wrong: «Stefano» can come
    // through as «Stefan» or «Ste fano». Better a generous match than creating
    // three cards for the same person.

    func find(_ name: String) -> Person? {
        let q = normalize(name)
        guard !q.isEmpty else { return nil }
        if let exact = people.first(where: { normalize($0.name) == q }) { return exact }
        return people.first { normalize($0.name).contains(q) || q.contains(normalize($0.name)) }
    }

    private func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: " ", with: "")
    }

    // MARK: - Writing

    @discardableResult
    func record(name: String, summary: String,
                promise: String?, due: Date?, byThem: Bool) -> Person {
        var person = find(name) ?? Person(name: name.trimmingCharacters(in: .whitespaces))
        if !summary.isEmpty {
            person.interactions.insert(Interaction(summary: summary), at: 0)
            if person.interactions.count > 60 { person.interactions.removeLast() }
        }
        if let promise, !promise.isEmpty {
            person.promises.insert(Promise(text: promise, due: due, byThem: byThem), at: 0)
        }
        upsert(person)
        return person
    }

    func upsert(_ person: Person) {
        if let i = people.firstIndex(where: { $0.id == person.id }) {
            people[i] = person
        } else {
            people.append(person)
        }
        people.sort { ($0.lastContact ?? .distantPast) > ($1.lastContact ?? .distantPast) }
        save()
    }

    func delete(_ person: Person) {
        people.removeAll { $0.id == person.id }
        save()
    }

    func closePromise(_ promise: Promise, of person: Person) {
        guard var p = people.first(where: { $0.id == person.id }),
              let i = p.promises.firstIndex(where: { $0.id == promise.id }) else { return }
        p.promises[i].done = true
        upsert(p)
    }

    // MARK: - Reads for the assistant

    func summary(for name: String) -> String {
        guard let p = find(name) else {
            return "Non ho nessuna scheda per «\(name)»."
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "d MMMM"

        var out = p.name
        if !p.role.isEmpty { out += " — \(p.role)" }
        out += "\n"
        if let d = p.daysSinceContact {
            out += "Ultimo contatto \(d) giorni fa.\n"
        }
        let open = p.openPromises
        if !open.isEmpty {
            out += "In sospeso:\n" + open.map { pr in
                var line = "- \(pr.byThem ? "lui" : "tu"): \(pr.text)"
                if let due = pr.due { line += " (entro \(f.string(from: due)))" }
                return line
            }.joined(separator: "\n") + "\n"
        }
        if !p.interactions.isEmpty {
            out += "Ultime volte:\n" + p.interactions.prefix(5).map {
                "- \(f.string(from: $0.at)): \($0.summary)"
            }.joined(separator: "\n")
        }
        return out
    }

    /// Who you've let slip away.
    func stale(afterDays days: Int) -> String {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let old = people.filter { ($0.lastContact ?? .distantPast) < cutoff }
        guard !old.isEmpty else { return "Nessuno che non senti da più di \(days) giorni." }
        return old.prefix(10).map { p in
            let d = p.daysSinceContact.map { "\($0) giorni" } ?? "mai"
            return "- \(p.name)\(p.role.isEmpty ? "" : " (\(p.role))"): \(d)"
        }.joined(separator: "\n")
    }

    var allOpenPromises: [(Person, Promise)] {
        people.flatMap { p in p.openPromises.map { (p, $0) } }
            .sorted { ($0.1.due ?? .distantFuture) < ($1.1.due ?? .distantFuture) }
    }
}

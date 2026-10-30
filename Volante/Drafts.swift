import Foundation
import UIKit
import Observation

/// Messages written by voice, ready to send with one tap.
///
/// WhatsApp can't be sent from a third-party app: only WhatsApp can do it,
/// which is why Siri manages and nobody else does. What you can do — with
/// the official `wa.me` link — is get one step away from sending: the message
/// dictated while driving, already written and already addressed, and you tap
/// «invia» ("send") at the traffic light or as soon as you park.
struct MessageDraft: Codable, Identifiable, Hashable {
    var id = UUID()
    var at = Date()
    var personName: String
    var phone: String
    var text: String
    var sent = false

    /// Official WhatsApp link, not a private scheme: it works even if the app
    /// isn't installed (opens the web) and requires no permissions.
    var whatsappURL: URL? {
        let digits = phone.filter(\.isNumber)
        guard !digits.isEmpty,
              let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return nil }
        return URL(string: "https://wa.me/\(digits)?text=\(encoded)")
    }
}

@MainActor
@Observable
final class DraftStore {
    private(set) var drafts: [MessageDraft] = []

    private var fileURL: URL { Paths.documents.appendingPathComponent("messaggi.json") }

    var pending: [MessageDraft] { drafts.filter { !$0.sent } }

    init() { load() }

    private func load() {
        guard let d = try? Data(contentsOf: fileURL),
              let m = try? JSONDecoder().decode([MessageDraft].self, from: d) else { return }
        drafts = m
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(drafts) { try? d.write(to: fileURL) }
    }

    func add(_ draft: MessageDraft) {
        drafts.insert(draft, at: 0)
        if drafts.count > 100 { drafts.removeLast() }
        save()
        // Also to a file: that's how a shortcut run by Siri can pick it up and
        // pass it to WhatsApp without you touching anything.
        DraftFile.write(number: draft.phone, text: draft.text)
    }

    /// Opens WhatsApp with the message already written. Sending remains your
    /// gesture: it's an iOS limit, and also the guarantee that nothing goes out
    /// by mistake.
    func open(_ draft: MessageDraft) {
        guard let url = draft.whatsappURL else { return }
        UIApplication.shared.open(url)
        markSent(draft)
    }

    func markSent(_ draft: MessageDraft) {
        guard let i = drafts.firstIndex(where: { $0.id == draft.id }) else { return }
        drafts[i].sent = true
        save()
        if pending.isEmpty { DraftFile.clear() }
    }

    func delete(_ draft: MessageDraft) {
        drafts.removeAll { $0.id == draft.id }
        save()
    }
}

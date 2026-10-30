import Foundation
import Observation

@MainActor
@Observable
final class Diagnostics {
    struct Entry: Identifiable {
        let id = UUID()
        let at = Date()
        let tag: String
        let text: String
    }

    private(set) var entries: [Entry] = []
    var route: String = "—"
    var inputPort: String = "—"

    func log(_ tag: String, _ text: String) {
        entries.insert(Entry(tag: tag, text: text), at: 0)
        if entries.count > 400 { entries.removeLast(entries.count - 400) }
        print("[\(tag)] \(text)")
    }

    var exportText: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return (["ROUTE: \(route)", "INPUT: \(inputPort)", ""] +
                entries.reversed().map { "\(f.string(from: $0.at))  \($0.tag)  \($0.text)" })
            .joined(separator: "\n")
    }
}

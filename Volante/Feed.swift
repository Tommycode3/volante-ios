import Foundation
import CryptoKit

struct Episode: Identifiable, Codable, Hashable {
    var id: String { guid }
    let guid: String
    let title: String
    let audioURL: URL
    let published: Date?
    let duration: Double?
    /// Which show it belongs to: with several subscriptions it's needed to sort
    /// the queue and to tell the assistant what you were listening to.
    var show: String = ""
    var feedID: String = ""

    var shortTitle: String {
        // Feed titles are often "704: Nome - descrizione lunghissima" ("704: Name - very long description")
        if let r = title.range(of: " - ") { return String(title[..<r.lowerBound]) }
        return title
    }
}

struct Podcast: Codable {
    var title: String
    var imageURL: URL?
    var episodes: [Episode]
}

/// A show you're subscribed to.
struct Subscription: Codable, Identifiable, Hashable {
    var id: String              // the feed URL, normalized
    var title: String
    var author: String
    var feedURL: URL
    var imageURL: URL?

    static func make(title: String, author: String, feed: URL, image: URL?) -> Subscription {
        Subscription(id: feed.absoluteString, title: title, author: author,
                     feedURL: feed, imageURL: image)
    }
}

enum FeedLoader {
    /// The first show, ready on first launch.
    static let learningLeader = Subscription.make(
        title: "The Learning Leader Show",
        author: "Ryan Hawk",
        feed: URL(string: "https://rss.libsyn.com/shows/65162/destinations/259291.xml")!,
        image: URL(string: "https://static.libsyn.com/p/assets/1/5/2/e/152e4268d7a65c08e55e3c100dce7605/Untitled_design.png"))

    /// A feed can be long (700 episodes, 9 MB): in the car you need the recent
    /// ones, and keeping fewer means less memory and faster launches.
    static let maxEpisodes = 200

    private static func cacheURL(for feedID: String) -> URL {
        let digest = Insecure.MD5.hash(data: Data(feedID.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return Paths.support.appendingPathComponent("feed-\(name).json")
    }

    static func cached(_ sub: Subscription) -> Podcast? {
        guard let d = try? Data(contentsOf: cacheURL(for: sub.id)) else { return nil }
        return try? JSONDecoder().decode(Podcast.self, from: d)
    }

    static func fetch(_ sub: Subscription) async throws -> Podcast {
        var req = URLRequest(url: sub.feedURL)
        req.timeoutInterval = 30
        let (data, _) = try await URLSession.shared.data(for: req)
        let podcast = try RSSParser(show: sub.title, feedID: sub.id).parse(data)
        if let d = try? JSONEncoder().encode(podcast) {
            try? d.write(to: cacheURL(for: sub.id))
        }
        return podcast
    }

    /// Searches Apple's catalog. No key, no account.
    static func search(_ term: String) async -> [Subscription] {
        let q = term.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2,
              let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?media=podcast&limit=20&term=\(encoded)")
        else { return [] }

        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }

        return results.compactMap { r in
            guard let name = r["collectionName"] as? String,
                  let feedString = r["feedUrl"] as? String,
                  let feed = URL(string: feedString) else { return nil }
            let art = (r["artworkUrl600"] as? String) ?? (r["artworkUrl100"] as? String)
            return Subscription.make(title: name,
                                     author: (r["artistName"] as? String) ?? "",
                                     feed: feed,
                                     image: art.flatMap(URL.init(string:)))
        }
    }
}

private final class RSSParser: NSObject, XMLParserDelegate {
    private let show: String
    private let feedID: String

    init(show: String, feedID: String) {
        self.show = show
        self.feedID = feedID
        super.init()
    }

    private var podcastTitle = ""
    private var podcastImage: URL?
    private var episodes: [Episode] = []

    private var inItem = false
    private var path: [String] = []
    private var buffer = ""
    /// `abortParsing()` makes `parse()` return false: without this flag every
    /// feed with more than 200 episodes would be mistaken for a broken feed.
    private var stoppedOnPurpose = false

    private var itTitle = ""
    private var itGuid = ""
    private var itURL: URL?
    private var itDate: Date?
    private var itDuration: Double?

    private static let rfc822: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()

    func parse(_ data: Data) throws -> Podcast {
        let p = XMLParser(data: data)
        p.delegate = self
        let ok = p.parse()
        if !ok && !stoppedOnPurpose && episodes.isEmpty {
            throw NSError(domain: "RSS", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: p.parserError?.localizedDescription ?? "parse fallito"])
        }
        return Podcast(title: podcastTitle.isEmpty ? show : podcastTitle,
                       imageURL: podcastImage,
                       episodes: episodes)
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attrs: [String: String] = [:]) {
        path.append(element)
        buffer = ""
        switch element {
        case "item":
            inItem = true
            itTitle = ""; itGuid = ""; itURL = nil; itDate = nil; itDuration = nil
        case "enclosure":
            if inItem, let s = attrs["url"] { itURL = URL(string: s) }
        case "image":
            if !inItem, let s = attrs["href"], podcastImage == nil { podcastImage = URL(string: s) }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { buffer += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        buffer += String(data: CDATABlock, encoding: .utf8) ?? ""
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if inItem {
            switch element {
            case "title": if itTitle.isEmpty { itTitle = text }
            case "guid": itGuid = text
            case "pubDate": itDate = Self.rfc822.date(from: text)
            case "duration": itDuration = Self.seconds(text)
            case "item":
                inItem = false
                if let url = itURL, !itTitle.isEmpty, episodes.count < FeedLoader.maxEpisodes {
                    let guid = itGuid.isEmpty ? url.absoluteString : itGuid
                    episodes.append(Episode(guid: guid, title: itTitle, audioURL: url,
                                            published: itDate, duration: itDuration,
                                            show: podcastTitle.isEmpty ? show : podcastTitle,
                                            feedID: feedID))
                }
                if episodes.count >= FeedLoader.maxEpisodes {
                    stoppedOnPurpose = true
                    parser.abortParsing()
                }
            default: break
            }
        } else if element == "title", podcastTitle.isEmpty, path.count <= 3 {
            podcastTitle = text
        }
        buffer = ""
        if !path.isEmpty { path.removeLast() }
    }

    /// "52:37" | "01:04:05" | "3157"
    private static func seconds(_ s: String) -> Double? {
        let parts = s.split(separator: ":").compactMap { Double($0) }
        switch parts.count {
        case 1: return parts[0]
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return nil
        }
    }
}

enum Paths {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    static var support: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var notesAudio: URL {
        let u = documents.appendingPathComponent("NoteVocali", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    /// Outside Documents: downloaded episodes don't belong in the iCloud backup
    /// and make no sense in the Files app.
    static var episodes: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let u = base.appendingPathComponent("Episodi", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        var res = URLResourceValues()
        res.isExcludedFromBackup = true
        var mutable = u
        try? mutable.setResourceValues(res)
        return u
    }
}

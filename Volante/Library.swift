import Foundation
import Observation

/// The shows you're subscribed to and their episodes.
///
/// A single feed hardcoded in the source was fine for the first round; to use
/// it every day you need to be able to add whatever you want. Search goes
/// through Apple's catalog, but then the RSS is read directly: no account, no
/// subscriptions, and it works with any public podcast.
@MainActor
@Observable
final class Library {

    private(set) var subscriptions: [Subscription] = []
    private(set) var episodesByFeed: [String: [Episode]] = [:]
    private(set) var isRefreshing = false
    var status = ""

    /// The show currently displayed on the Listen screen.
    private(set) var selectedID: String

    func select(_ id: String) {
        guard subscriptions.contains(where: { $0.id == id }) else { return }
        selectedID = id
        UserDefaults.standard.set(id, forKey: "selectedFeed")
    }

    var diagnostics: Diagnostics?

    private static let key = "subscriptions"

    init() {
        let d = UserDefaults.standard
        // Everything in local variables: with @Observable you can't read the
        // properties until they're all initialized.
        let stored = d.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([Subscription].self, from: $0) }
        let subs = (stored?.isEmpty == false ? stored! : [FeedLoader.learningLeader])
        let savedID = d.string(forKey: "selectedFeed")

        subscriptions = subs
        selectedID = subs.contains { $0.id == savedID } ? (savedID ?? subs[0].id) : subs[0].id

        for s in subs {
            if let c = FeedLoader.cached(s) { episodesByFeed[s.id] = c.episodes }
        }
    }

    // MARK: - Access

    var selected: Subscription? {
        subscriptions.first { $0.id == selectedID } ?? subscriptions.first
    }

    var episodes: [Episode] {
        episodesByFeed[selectedID] ?? []
    }

    /// The most recent across all shows: this is the queue worth keeping
    /// downloaded, not the last three of a single show.
    func recentAcrossAll(limit: Int) -> [Episode] {
        episodesByFeed.values
            .flatMap { $0.prefix(20) }
            .sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    func episode(withGuid guid: String) -> Episode? {
        for list in episodesByFeed.values {
            if let e = list.first(where: { $0.guid == guid }) { return e }
        }
        return nil
    }

    // MARK: - Subscriptions

    private func persist() {
        if let d = try? JSONEncoder().encode(subscriptions) {
            UserDefaults.standard.set(d, forKey: Self.key)
        }
    }

    func isSubscribed(_ s: Subscription) -> Bool {
        subscriptions.contains { $0.id == s.id }
    }

    func add(_ s: Subscription) async {
        guard !isSubscribed(s) else { return }
        subscriptions.append(s)
        persist()
        diagnostics?.log("feed", "iscritto a \(s.title)")
        await refresh(s)
        select(s.id)
    }

    func remove(_ s: Subscription) {
        guard subscriptions.count > 1 else { return }    // at least one remains
        subscriptions.removeAll { $0.id == s.id }
        episodesByFeed[s.id] = nil
        persist()
        if selectedID == s.id { select(subscriptions[0].id) }
        diagnostics?.log("feed", "rimosso \(s.title)")
    }

    // MARK: - Refresh

    func refresh(_ s: Subscription) async {
        do {
            let p = try await FeedLoader.fetch(s)
            episodesByFeed[s.id] = p.episodes
            // The real title and artwork come from the feed, not from the search.
            if let i = subscriptions.firstIndex(where: { $0.id == s.id }) {
                if !p.title.isEmpty { subscriptions[i].title = p.title }
                if let img = p.imageURL { subscriptions[i].imageURL = img }
                persist()
            }
            diagnostics?.log("feed", "\(p.title): \(p.episodes.count) episodi")
        } catch {
            diagnostics?.log("feed", "\(s.title) non aggiornato: \(error.localizedDescription)")
        }
    }

    /// Refreshes all of them, one at a time: in parallel they'd download several
    /// megabytes at once, and in the car bandwidth is what it is.
    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        status = "aggiorno…"
        for s in subscriptions { await refresh(s) }
        isRefreshing = false
        let total = episodesByFeed.values.reduce(0) { $0 + $1.count }
        status = "\(subscriptions.count) programmi · \(total) episodi"
    }
}

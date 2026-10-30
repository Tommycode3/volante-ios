import SwiftUI

/// The shows: the ones you're subscribed to and the search to add more.
/// Search goes through Apple's catalog but then the RSS is read directly,
/// so it works with any public podcast and without an account.
struct ShowsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var term = ""
    @State private var results: [Subscription] = []
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                if !results.isEmpty || searching {
                    Section(searching ? "cerco…" : "risultati") {
                        ForEach(results) { s in
                            row(s, subscribed: app.library.isSubscribed(s)) {
                                Task { await app.subscribe(s); clearSearch() }
                            }
                        }
                    }
                }

                Section("I tuoi programmi") {
                    ForEach(app.library.subscriptions) { s in
                        Button {
                            app.selectShow(s)
                            dismiss()
                        } label: {
                            row(s, subscribed: false, action: nil,
                                selected: s.id == app.library.selectedID)
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            if app.library.subscriptions.count > 1 {
                                Button("Rimuovi", role: .destructive) { app.library.remove(s) }
                            }
                        }
                    }
                }
            }
            .searchable(text: $term, prompt: "Cerca un podcast")
            .onChange(of: term) { _, new in scheduleSearch(new) }
            .navigationTitle("Podcast")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Fine") { dismiss() } }
        }
    }

    private func row(_ s: Subscription, subscribed: Bool,
                     action: (() -> Void)?, selected: Bool = false) -> some View {
        HStack(spacing: 12) {
            cover(s.imageURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).font(.subheadline.weight(.medium)).lineLimit(2)
                if !s.author.isEmpty {
                    Text(s.author).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                if let n = app.library.episodesByFeed[s.id]?.count, n > 0 {
                    Text("\(n) episodi").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "waveform").foregroundStyle(.tint)
            } else if let action {
                Button(subscribed ? "Già iscritto" : "Aggiungi", action: action)
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .disabled(subscribed)
            }
        }
        .padding(.vertical, 2)
    }

    private func cover(_ url: URL?) -> some View {
        AsyncImage(url: url) { img in
            img.resizable().scaledToFill()
        } placeholder: {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
        }
        .frame(width: 46, height: 46)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Searches after half a second of pause: one request per character would
    /// flood the network with useless calls.
    private func scheduleSearch(_ text: String) {
        searchTask?.cancel()
        guard text.trimmingCharacters(in: .whitespaces).count >= 2 else {
            results = []; searching = false
            return
        }
        searching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let found = await FeedLoader.search(text)
            guard !Task.isCancelled else { return }
            results = found
            searching = false
        }
    }

    private func clearSearch() {
        term = ""; results = []; searching = false
    }
}

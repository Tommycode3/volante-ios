import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            ListenView()
                .tabItem { Label("Ascolta", systemImage: "waveform") }
            ArchiveView()
                .tabItem { Label("Archivio", systemImage: "tray.full.fill") }
            AssistantView()
                .tabItem { Label("Claude", systemImage: "bubble.left.and.bubble.right.fill") }
            DiagnosticsView()
                .tabItem { Label("Impostazioni", systemImage: "gearshape.fill") }
        }
    }
}

// MARK: - Listen

struct ListenView: View {
    @Environment(AppModel.self) private var app
    @State private var search = ""
    @State private var showShows = false
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    private static let rates: [Double] = [0.9, 1.0, 1.2, 1.4, 1.6, 1.8, 2.0]

    private var filtered: [Episode] {
        guard !search.isEmpty else { return app.episodes }
        return app.episodes.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                nowPlaying
                Divider()
                List {
                    ForEach(filtered) { ep in
                        Button { app.play(ep) } label: { row(ep) }
                            .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
                .searchable(text: $search, prompt: "Cerca episodio")
            }
            .navigationTitle(app.library.selected?.title ?? "Volante")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await app.refreshFeed() }
            .toolbar {
                Button { showShows = true } label: { Image(systemName: "square.stack") }
            }
            .sheet(isPresented: $showShows) { ShowsView() }
        }
    }

    // MARK: Now playing

    /// A single accent colour, and only where it's needed: progress and the
    /// main action. Transport controls stay white, as in the system players —
    /// if everything is lit up, nothing stands out.
    private var nowPlaying: some View {
        VStack(spacing: 16) {
            if let w = app.permissionWarning {
                Text(w).font(.caption).foregroundStyle(.orange)
            }

            HStack(spacing: 13) {
                cover
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.player.statusOverride ?? app.player.current?.title ?? "Nessun episodio")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .foregroundStyle(app.player.statusOverride == nil ? .primary : Color.accentColor)
                    Text(statusLine)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            if app.player.duration > 0 { scrubber }

            HStack(spacing: 0) {
                Spacer()
                Button { app.player.seek(by: -app.settings.skipBackwardSeconds) } label: {
                    Image(systemName: "gobackward.15").font(.system(size: 26, weight: .regular))
                }
                Spacer()
                Button { app.player.toggle() } label: {
                    Image(systemName: app.player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 34, weight: .medium))
                        .frame(width: 54, height: 54)
                        .contentTransition(.symbolEffect(.replace))
                }
                Spacer()
                Button { app.player.seek(by: app.settings.skipForwardSeconds) } label: {
                    Image(systemName: "goforward.30").font(.system(size: 26, weight: .regular))
                }
                Spacer()
            }
            .foregroundStyle(.primary)
            .overlay(alignment: .trailing) { speedMenu }

            actions
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 14)
    }

    private var statusLine: String {
        if app.isRecording {
            return app.recorder.longMode
                ? String(format: "dettatura · %.0f s", app.recorder.elapsed)
                : String(format: "registro · %.0f s", app.recorder.elapsed)
        }
        if app.player.isBuffering { return "in caricamento" }
        var parts: [String] = []
        if let s = app.library.selected?.title { parts.append(s) }
        if app.player.backend == .engine {
            parts.append(app.player.appliedGain == 0
                         ? "offline"
                         : String(format: "offline %+.0f dB", app.player.appliedGain))
        } else if app.player.current != nil {
            parts.append("streaming")
        }
        return parts.joined(separator: " · ")
    }

    /// Thin at rest, thicker while you drag it: that's the gesture you need to
    /// seek to a point, and the system bar behaves this way.
    private var scrubber: some View {
        let total = max(1, app.player.duration)
        let value = scrubbing ? scrubValue : min(app.player.currentTime, total)
        return VStack(spacing: 6) {
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.16))
                    Capsule().fill(Color.accentColor)
                        .frame(width: max(0, min(w, w * value / total)))
                }
                .frame(height: scrubbing ? 8 : 4)
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g2 in
                            if !scrubbing { scrubbing = true }
                            scrubValue = max(0, min(total, total * (g2.location.x / w)))
                        }
                        .onEnded { _ in
                            app.player.seek(to: scrubValue)
                            scrubbing = false
                        }
                )
                .animation(.snappy(duration: 0.15), value: scrubbing)
            }
            .frame(height: 22)

            HStack {
                Text(hhmmss(value))
                Spacer()
                Text("-" + hhmmss(max(0, total - value)))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(scrubbing ? .primary : .secondary)
        }
    }

    private var speedMenu: some View {
        Menu {
            ForEach(Self.rates, id: \.self) { r in
                Button {
                    app.settings.playbackRate = r
                    app.player.rate = r
                } label: {
                    if app.settings.playbackRate == r {
                        Label(String(format: "%.1f×", r), systemImage: "checkmark")
                    } else {
                        Text(String(format: "%.1f×", r))
                    }
                }
            }
        } label: {
            Text(String(format: "%.1f×", app.settings.playbackRate))
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
    }

    /// Three actions of the same shape and the same weight: only the voice note
    /// is filled, because it's the one you press a thousand times.
    private var actions: some View {
        HStack(spacing: 10) {
            Button { app.toggleNote() } label: {
                Label(app.isRecording ? "Chiudi" : "Nota", systemImage: app.isRecording ? "stop.fill" : "mic.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 46)
            }
            .buttonStyle(.borderedProminent)
            .tint(app.isRecording ? .red : .accentColor)
            .overlay {
                if app.isRecording {
                    GeometryReader { g in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.white.opacity(0.25))
                            .frame(width: max(3, g.size.width * app.recorder.level))
                            .animation(.linear(duration: 0.1), value: app.recorder.level)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .allowsHitTesting(false)
                }
            }

            Button { app.toggleAssistant() } label: {
                Label("Claude", systemImage: "bubble.left.and.bubble.right")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, minHeight: 46)
            }
            .buttonStyle(.bordered)

            Button { app.startDictation() } label: {
                Label("Detta", systemImage: "text.bubble")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, minHeight: 46)
            }
            .buttonStyle(.bordered)
            .disabled(app.isBusy)
        }
        .labelStyle(.titleAndIcon)
        .animation(.snappy(duration: 0.2), value: app.isRecording)
    }

    private var cover: some View {
        Group {
            if let img = app.player.coverImage {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 9)
                    .fill(.quaternary)
                    .overlay(Image(systemName: "waveform").foregroundStyle(.secondary))
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    // MARK: Rows

    private func row(_ ep: Episode) -> some View {
        let p = app.player.progress(for: ep)
        let current = app.player.current?.guid == ep.guid
        let done = p > 0.95

        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(ep.title)
                    .font(.subheadline)
                    .lineLimit(2)
                    .foregroundStyle(done ? .secondary : .primary)

                HStack(spacing: 9) {
                    if current {
                        Image(systemName: "waveform").foregroundStyle(Color.accentColor)
                    }
                    if let d = ep.published {
                        Text(d.formatted(.dateTime.day().month(.abbreviated)))
                    }
                    if let s = ep.duration {
                        Text(p > 0.02 && !done ? "restano \(hhmmss(s * (1 - p)))" : hhmmss(s))
                    }
                    if done { Text("ascoltato") }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

                if p > 0.02 && !done {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.12))
                            Capsule().fill(Color.accentColor.opacity(0.7))
                                .frame(width: g.size.width * p)
                        }
                    }
                    .frame(height: 2)
                    .padding(.trailing, 40)
                }
            }
            Spacer(minLength: 0)
            downloadControl(ep)
        }
        .padding(.vertical, 4)
    }

    /// A single button for three states, in a minor key: downloading is a
    /// housekeeping matter, it doesn't deserve colour.
    private func downloadControl(_ ep: Episode) -> some View {
        Button { app.toggleDownload(ep) } label: {
            if let p = app.downloads.progress[ep.guid] {
                ProgressView(value: p)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            } else if app.downloads.isDownloaded(ep.guid) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .font(.title3)
        .frame(width: 28, height: 28)
        .padding(.top, 1)
    }
}

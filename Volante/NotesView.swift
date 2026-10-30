import SwiftUI
import AVFoundation

@Observable
final class NotePlayer {
    static let shared = NotePlayer()
    private var player: AVAudioPlayer?
    private(set) var playingFile: String?

    func toggle(_ note: VoiceNote) {
        if playingFile == note.audioFileName { stop(); return }
        stop()
        guard !note.audioFileName.isEmpty,
              let p = try? AVAudioPlayer(contentsOf: note.audioURL) else { return }
        player = p
        p.play()
        playingFile = note.audioFileName
        DispatchQueue.main.asyncAfter(deadline: .now() + p.duration + 0.1) { [weak self] in
            if self?.playingFile == note.audioFileName { self?.stop() }
        }
    }

    func stop() {
        player?.stop(); player = nil; playingFile = nil
    }
}

// MARK: - List

/// Just the list: the frame (title, sharing, picker) is provided by
/// `ArchiveView`, which shows it alongside people and training.
struct NotesList: View {
    @Environment(AppModel.self) private var app

    /// Grouped by day: when scrolling an archive, the date is the only handhold
    /// that really works.
    private var days: [(String, [VoiceNote])] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "EEEE d MMMM"
        let cal = Calendar.current
        var order: [String] = []
        var map: [String: [VoiceNote]] = [:]
        for n in app.notes.notes {
            let key: String
            if cal.isDateInToday(n.createdAt) { key = "Oggi" }
            else if cal.isDateInYesterday(n.createdAt) { key = "Ieri" }
            else { key = f.string(from: n.createdAt).capitalized }
            if map[key] == nil { order.append(key); map[key] = [] }
            map[key]?.append(n)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    var body: some View {
        Group {
            if app.notes.notes.isEmpty {
                ContentUnavailableView(
                    "Nessuna nota",
                    systemImage: "mic.slash",
                    description: Text("Doppio tap su «avanti» al volante, oppure il pulsante nella scheda Ascolta.")
                )
            } else {
                List {
                    ForEach(days, id: \.0) { day, notes in
                        Section(day) {
                            ForEach(notes) { note in
                                NavigationLink {
                                    NoteDetailView(noteID: note.id)
                                } label: {
                                    row(note)
                                }
                                .swipeActions {
                                    Button("Elimina", role: .destructive) { app.notes.delete(note) }
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func row(_ note: VoiceNote) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(note.createdAt, format: .dateTime.hour().minute())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if note.isAnchored, let p = note.positionLabel {
                    Label(p, systemImage: "waveform")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tint)
                }
                if note.episodeQuote != nil {
                    Image(systemName: "text.quote").font(.caption2).foregroundStyle(.tint)
                }
                Spacer()
                if note.duration > 0 {
                    Text("\(Int(note.duration)) s")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Text(note.transcript.isEmpty ? "(trascrizione in corso…)" : note.transcript)
                .font(.subheadline)
                .foregroundStyle(note.transcript.isEmpty ? .secondary : .primary)
                .lineLimit(3)
            if let s = note.showTitle ?? note.episodeTitle {
                Text(s).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Detail

struct NoteDetailView: View {
    let noteID: UUID
    @Environment(AppModel.self) private var app
    @State private var notePlayer = NotePlayer.shared
    @State private var editing = false
    @State private var draft = ""

    private var note: VoiceNote? { app.notes.note(noteID) }

    var body: some View {
        Group {
            if let note {
                List {
                    Section {
                        anchor(note)
                    }

                    Section("Quello che hai detto") {
                        if editing {
                            TextEditor(text: $draft).frame(minHeight: 120)
                            HStack {
                                Button("Annulla") { editing = false }
                                Spacer()
                                Button("Salva") {
                                    var n = note
                                    n.transcript = draft
                                    app.notes.update(n)
                                    editing = false
                                }
                                .fontWeight(.semibold)
                            }
                        } else {
                            Text(note.transcript.isEmpty ? "Nessuna trascrizione — l'audio però c'è." : note.transcript)
                                .font(.body)
                                .textSelection(.enabled)
                                .foregroundStyle(note.transcript.isEmpty ? .secondary : .primary)
                            if !note.audioFileName.isEmpty {
                                Button {
                                    notePlayer.toggle(note)
                                } label: {
                                    Label(notePlayer.playingFile == note.audioFileName
                                          ? "Ferma" : "Riascolta la tua voce",
                                          systemImage: notePlayer.playingFile == note.audioFileName
                                          ? "stop.fill" : "play.fill")
                                }
                            }
                            Button {
                                draft = note.transcript
                                editing = true
                            } label: {
                                Label("Correggi il testo", systemImage: "pencil")
                            }
                        }
                    }

                    if note.isAnchored {
                        Section("Il podcast in quel momento") {
                            if let q = note.episodeQuote, !q.isEmpty {
                                Text(q)
                                    .font(.callout)
                                    .italic()
                                    .textSelection(.enabled)
                            } else if app.transcribingNote == note.id {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("estraggo e trascrivo…").foregroundStyle(.secondary)
                                }
                            } else {
                                Button {
                                    Task { await app.transcribeQuote(for: note) }
                                } label: {
                                    Label("Trascrivi i 45 secondi prima", systemImage: "text.quote")
                                }
                                Text(app.downloads.isDownloaded(note.episodeGuid ?? "")
                                     ? "Legge il file già sul telefono, senza rete."
                                     : "Serve l'episodio scaricato: da Ascolta, tocca la freccia accanto all'episodio.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }

                            Button {
                                app.replay(note)
                            } label: {
                                Label("Riascolta il podcast da 30 secondi prima",
                                      systemImage: "gobackward.30")
                            }
                        }
                    }

                    Section {
                        ShareLink(item: shareText(note)) {
                            Label("Condividi la nota", systemImage: "square.and.arrow.up")
                        }
                        Button(role: .destructive) {
                            app.notes.delete(note)
                        } label: {
                            Label("Elimina", systemImage: "trash")
                        }
                    }
                }
            } else {
                ContentUnavailableView("Nota eliminata", systemImage: "trash")
            }
        }
        .navigationTitle(note.map { $0.createdAt.formatted(date: .abbreviated, time: .shortened) } ?? "Nota")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func anchor(_ note: VoiceNote) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let show = note.showTitle, !show.isEmpty {
                Text(show).font(.caption).foregroundStyle(.tint)
            }
            if let ep = note.episodeTitle {
                Text(ep).font(.subheadline.weight(.medium)).lineLimit(3)
            } else {
                Text("Nota libera, senza episodio").font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                if let p = note.positionLabel {
                    Label(p, systemImage: "clock").font(.caption.monospacedDigit())
                }
                Label(note.createdAt.formatted(date: .omitted, time: .standard),
                      systemImage: "calendar")
                    .font(.caption.monospacedDigit())
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func shareText(_ note: VoiceNote) -> String {
        var out = ""
        if let show = note.showTitle { out += "\(show)\n" }
        if let ep = note.episodeTitle {
            out += ep
            if let p = note.positionLabel { out += " — \(p)" }
            out += "\n\n"
        }
        if let q = note.episodeQuote, !q.isEmpty { out += "« \(q) »\n\n" }
        out += note.transcript
        return out
    }
}

import SwiftUI

/// Everything that piles up while driving, in one place.
///
/// They used to be three separate tabs that didn't deserve three tabs: notes,
/// people and training are the same thing seen from three sides — what you
/// said, to whom, and how much you're improving.
struct ArchiveView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case notes = "Note", people = "Persone", training = "Allena", trips = "Viaggi"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var app
    @State private var tab: Tab = .notes

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

                switch tab {
                case .notes: NotesList()
                case .people: PeopleList()
                case .training: TrainingList()
                case .trips: TripsList()
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
    }

    private var title: String {
        switch tab {
        case .notes: return "\(app.notes.notes.count) note"
        case .people: return "\(app.people.people.count) persone"
        case .training: return "\(app.training.runs.count) prove"
        case .trips: return String(format: "%.0f km questo mese",
                                   app.tripRecorder.kilometers(inLast: 30))
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            switch tab {
            case .notes:
                if !app.notes.notes.isEmpty {
                    ShareLink(item: app.notes.exportText) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            case .people:
                NavigationLink { PersonEditor(person: Person(name: "")) } label: {
                    Image(systemName: "plus")
                }
            case .training, .trips:
                EmptyView()
            }
        }
    }
}

// MARK: - People

struct PeopleList: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if app.people.people.isEmpty {
                ContentUnavailableView {
                    Label("Nessuna persona", systemImage: "person.2")
                } description: {
                    Text("Si riempiono parlando: «ho sentito Stefano, gli ho promesso lo schema per venerdì».")
                }
            } else {
                List {
                    if !app.drafts.pending.isEmpty {
                        Section("Da mandare") {
                            ForEach(app.drafts.pending) { draft in
                                Button { app.drafts.open(draft) } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: "paperplane.fill")
                                            .foregroundStyle(.tint)
                                            .padding(.top, 2)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(draft.personName)
                                                .font(.subheadline.weight(.medium))
                                            Text(draft.text)
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption2).foregroundStyle(.tertiary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .swipeActions {
                                    Button("Scarta", role: .destructive) { app.drafts.delete(draft) }
                                }
                            }
                            Text("WhatsApp si apre già scritto: l'invio resta un tuo tocco, iOS non lo concede a nessuna app che non sia WhatsApp.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    let open = app.people.allOpenPromises
                    if !open.isEmpty {
                        Section("In sospeso") {
                            ForEach(open, id: \.1.id) { person, promise in
                                Button {
                                    app.people.closePromise(promise, of: person)
                                } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: "circle")
                                            .foregroundStyle(.secondary)
                                            .padding(.top, 2)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(promise.text).font(.subheadline)
                                            Text(subtitle(person, promise))
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Section("Tutti") {
                        ForEach(app.people.people) { p in
                            NavigationLink { PersonEditor(person: p) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(p.name).font(.subheadline.weight(.medium))
                                        if !p.role.isEmpty {
                                            Text(p.role).font(.caption2).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if let d = p.daysSinceContact {
                                            Text("\(d) g")
                                                .font(.caption2.monospacedDigit())
                                                .foregroundStyle(d > 45 ? .orange : .secondary)
                                        }
                                    }
                                    if let last = p.interactions.first {
                                        Text(last.summary)
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                            }
                            .swipeActions {
                                Button("Elimina", role: .destructive) { app.people.delete(p) }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func subtitle(_ p: Person, _ promise: Promise) -> String {
        var s = promise.byThem ? "\(p.name) → te" : "te → \(p.name)"
        if let due = promise.due {
            s += " · entro \(due.formatted(.dateTime.day().month(.abbreviated)))"
        }
        return s
    }
}

struct PersonEditor: View {
    @State var person: Person
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Chi è") {
                TextField("Nome", text: $person.name)
                TextField("Ruolo (fornitore PCB, investitore…)", text: $person.role)
            }
            Section("Dove si raggiunge") {
                TextField("Numero WhatsApp (+39 333…)", text: $person.phone)
                    .keyboardType(.phonePad)
                TextField("Telegram chat id", text: $person.telegramChatID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Canale Slack", text: $person.slackChannel)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Email", text: $person.email)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                Text("Basta uno, e a voce dici solo «scrivi a \(person.name.isEmpty ? "…" : person.name)». Con il numero va su WhatsApp e resta in attesa di un tocco; con Telegram o Slack parte da solo.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !person.interactions.isEmpty {
                Section("Ultime volte") {
                    ForEach(person.interactions.prefix(15)) { i in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(i.at.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2).foregroundStyle(.secondary)
                            Text(i.summary).font(.subheadline)
                        }
                    }
                }
            }
        }
        .navigationTitle(person.name.isEmpty ? "Nuova persona" : person.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Salva") {
                guard !person.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                app.people.upsert(person)
                dismiss()
            }
            .fontWeight(.semibold)
        }
    }
}

// MARK: - Trips

struct TripsList: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        List {
            if let t = app.tripRecorder.current {
                Section("In corso") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: "%.0f km · %d min · %.0f km/h",
                                    t.distanceKm, t.minutes, app.tripRecorder.speedKmh))
                            .font(.subheadline.monospacedDigit())
                        Text("\(t.events.count) eventi · punteggio \(t.score)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if app.tripRecorder.trips.isEmpty && app.tripRecorder.current == nil {
                Section {
                    Text(app.tripRecorder.authorized
                         ? "Il primo viaggio comincia da solo quando superi i 15 km/h."
                         : "Serve il permesso di posizione: si chiede alla prima partenza.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            ForEach(app.tripRecorder.trips) { trip in
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(trip.start.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(trip.score)")
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(color(trip.score))
                        }
                        Text(String(format: "%.1f km · %d min · max %.0f km/h",
                                    trip.distanceKm, trip.minutes, trip.maxSpeedKmh))
                            .font(.subheadline.monospacedDigit())

                        HStack(spacing: 14) {
                            badge("frenate", trip.count(.brake))
                            badge("accelerate", trip.count(.accel))
                            badge("curve", trip.count(.turn))
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)

                        if trip.hasBlackBox {
                            Label("Scatola nera: minuto precedente salvato",
                                  systemImage: "exclamationmark.shield.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 2)
                    .swipeActions {
                        Button("Elimina", role: .destructive) { app.tripRecorder.delete(trip) }
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func badge(_ label: String, _ n: Int) -> some View {
        Text("\(n) \(label)").opacity(n == 0 ? 0.45 : 1)
    }

    private func color(_ score: Int) -> Color {
        score >= 90 ? .green : (score >= 70 ? .primary : .orange)
    }
}

// MARK: - Training

struct TrainingList: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        List {
            Section("Comincia") {
                start("Prova del pitch", "mic.and.signal.meter",
                      "Parli, misuro velocità e riempitivi, ti dico dove ti perdi.") {
                    app.startTraining(.pitch(target: 120))
                }
                start("Investitore scettico", "person.crop.square",
                      "Ti fa le domande scomode. Dì «basta» per il verdetto.") {
                    app.startTraining(.roleplay(role: "un investitore scettico che conosce l'hardware"))
                }
                start("Cliente che tratta", "eurosign.circle",
                      "Vuole lo sconto e ha alternative.") {
                    app.startTraining(.roleplay(role: "un cliente che vuole uno sconto e ha alternative"))
                }
                start("Inglese", "globe.europe.africa",
                      "Conversazione in inglese, correzioni alla fine.") {
                    app.startTraining(.english)
                }
            }

            if app.trainingMode != nil {
                Section {
                    Button(role: .destructive) { app.endTraining() } label: {
                        Label("Chiudi la sessione", systemImage: "stop.circle")
                    }
                }
            }

            if !app.training.runs.isEmpty {
                Section("Prove") {
                    ForEach(app.training.runs) { run in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(run.at.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(String(format: "%.0fs · %.0f ppm · %d riemp.",
                                            run.seconds, run.wordsPerMinute, run.fillerCount))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            if !run.feedback.isEmpty {
                                Text(run.feedback).font(.subheadline)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func start(_ title: String, _ icon: String, _ subtitle: String,
                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .frame(width: 30)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .disabled(app.isBusy)
    }
}

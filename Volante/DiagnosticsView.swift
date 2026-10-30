import SwiftUI

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings

        NavigationStack {
            List {
                Section("Rotta audio") {
                    LabeledContent("Uscita", value: app.diagnostics.route)
                    LabeledContent("Ingresso", value: app.diagnostics.inputPort)
                    switch AudioSessionManager.shared.isHighQualityBluetooth {
                    case .some(true):
                        Label("A2DP — stereo, qualità piena", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .some(false):
                        Label("HFP — mono 8 kHz, qualità degradata", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    case .none:
                        Label("Nessun Bluetooth collegato", systemImage: "iphone")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Coach di guida e scatola nera") {
                    Toggle("Registra i viaggi", isOn: Binding(
                        get: { settings.tripCoach },
                        set: {
                            settings.tripCoach = $0
                            app.tripRecorder.enabled = $0
                            $0 ? app.tripRecorder.start() : app.tripRecorder.stop()
                        }))
                    Toggle("Riassunto all'arrivo", isOn: $settings.speakTripSummary)
                        .disabled(!settings.tripCoach)
                    if app.tripRecorder.current != nil {
                        LabeledContent("Adesso",
                                       value: String(format: "%.0f km/h", app.tripRecorder.speedKmh))
                    }
                    if let avg = app.tripRecorder.recentAverage {
                        LabeledContent("Media ultimi viaggi", value: "\(avg)/100")
                    }
                    Text("Usa posizione e sensori. Tutto resta sul telefono: niente viene mandato da nessuna parte.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Messaggi") {
                    SecureField("token bot Telegram", text: $settings.telegramToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Crea un bot con @BotFather, incolla il token qui, poi metti il chat id di ogni persona nella sua scheda in Archivio → Persone. È l'unico modo programmatico di mandare messaggi da iOS.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Banco di prova") {
                    Text("Inietta gli stessi eventi che manda l'autoradio, per tarare i tempi senza salire in macchina.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("◀︎ singolo") { app.simulateWheel("indietro") }
                        Spacer()
                        Button("singolo ▶︎") { app.simulateWheel("avanti") }
                    }
                    .buttonStyle(.bordered)
                    HStack(spacing: 8) {
                        Button("◀︎◀︎ doppio") { app.simulateDoubleTap("indietro") }
                        Spacer()
                        Button("doppio ▶︎▶︎") { app.simulateDoubleTap("avanti") }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Dettatura lunga") { app.startDictation() }
                        .buttonStyle(.bordered)
                }

                Section("Audio") {
                    Toggle("Equalizzazione voce e limiter", isOn: Binding(
                        get: { settings.voiceBoost },
                        set: { settings.voiceBoost = $0; app.player.voiceBoost = $0 }))
                    Text("Il livellamento del volume fra episodi resta comunque attivo: è quello che evita la manopola in mano.")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Riproduzione", value: app.player.backend.rawValue)
                    LabeledContent("Correzione applicata",
                                   value: String(format: "%+.1f dB", app.player.appliedGain))
                    slider("Episodi da tenere offline", value: $settings.autoDownloadCount,
                           range: 0...10, step: 1, unit: "")
                    LabeledContent("Sul telefono",
                                   value: "\(app.downloads.downloaded.count) episodi · \(app.downloads.megabytes) MB")
                }

                Section("Tasti del volante") {
                    Text("Doppio tap su «avanti» o «indietro» avvia una nota vocale. Qualsiasi tasto premuto durante la registrazione la chiude.")
                        .font(.caption).foregroundStyle(.secondary)
                    slider("Finestra doppio tap", value: $settings.doubleTapWindow,
                           range: 0.2...1.0, step: 0.05, unit: "s")
                    slider("Avanti", value: $settings.skipForwardSeconds,
                           range: 5...60, step: 5, unit: "s")
                    slider("Indietro", value: $settings.skipBackwardSeconds,
                           range: 5...60, step: 5, unit: "s")
                    Picker("Doppio tap «indietro»", selection: $settings.backDoubleTapAction) {
                        Text("Parla con Claude").tag("claude")
                        Text("Nota vocale").tag("nota")
                    }
                    Text("Metti «Nota vocale» se la Micra manda solo eventi «indietro»: così il gesto per la nota funziona comunque.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Note vocali") {
                    slider("Silenzio per chiudere", value: $settings.silenceStopSeconds,
                           range: 1...6, step: 0.5, unit: "s")
                    slider("Durata massima", value: $settings.maxNoteSeconds,
                           range: 30...300, step: 30, unit: "s")
                    Picker("Lingua", selection: $settings.transcriptionLocale) {
                        Text("Italiano").tag("it-IT")
                        Text("English (US)").tag("en-US")
                    }
                }

                Section("Registro eventi") {
                    ForEach(app.diagnostics.entries) { e in
                        HStack(alignment: .top, spacing: 8) {
                            Text(e.at, format: .dateTime.hour().minute().second())
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(e.tag)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(color(e.tag))
                                .frame(width: 62, alignment: .leading)
                            Text(e.text).font(.caption2)
                        }
                    }
                }
            }
            .navigationTitle("Diagnostica")
            .toolbar {
                ShareLink(item: app.diagnostics.exportText) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
    }

    private func slider(_ title: String, value: Binding<Double>,
                        range: ClosedRange<Double>, step: Double, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(step < 1 ? String(format: "%.2f %@", value.wrappedValue, unit)
                              : String(format: "%.0f %@", value.wrappedValue, unit))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }

    private func color(_ tag: String) -> Color {
        switch tag {
        case "tasto": return .blue
        case "rotta": return .purple
        case "nota": return .red
        case "interruzione": return .orange
        default: return .secondary
        }
    }
}

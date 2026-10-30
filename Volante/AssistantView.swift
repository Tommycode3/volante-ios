import SwiftUI

/// Used to pick the button style depending on the state without
/// duplicating the view: filled when ready, outlined when busy.
struct AnyButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: PrimitiveButtonStyle>(_ style: S) {
        make = { config in AnyView(Button(config).buttonStyle(style)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

struct AssistantView: View {
    @Environment(AppModel.self) private var app
    @State private var showKey = false

    var body: some View {
        @Bindable var settings = app.settings

        NavigationStack {
            VStack(spacing: 0) {
                if settings.apiKey.isEmpty {
                    keyPrompt(settings: settings)
                } else {
                    conversation
                }
            }
            .navigationTitle("Claude")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !app.assistant.lines.isEmpty {
                    Button("Azzera") { app.assistant.resetConversation() }
                }
                Button { showKey = true } label: { Image(systemName: "key") }
            }
            .sheet(isPresented: $showKey) { keySheet(settings: settings) }
        }
    }

    private func keyPrompt(settings: AppSettings) -> some View {
        ContentUnavailableView {
            Label("Serve la chiave API", systemImage: "key.slash")
        } description: {
            Text("Incolla una chiave Anthropic per parlare con Claude mentre guidi. Resta nel portachiavi del telefono.")
        } actions: {
            Button("Inserisci la chiave") { showKey = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private func keySheet(settings: AppSettings) -> some View {
        @Bindable var s = settings
        return NavigationStack {
            Form {
                Section("Chiave API Anthropic") {
                    SecureField("sk-ant-…", text: $s.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Salvata nel portachiavi, mai in chiaro nei file dell'app.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("id workspace (solo se serve)", text: $s.anthropicWorkspace)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Serve solo se l'API risponde che la chiave non è legata a un workspace. Lo trovi su console.anthropic.com in Settings → Workspaces, inizia per wrkspc_.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Modello sul telefono") {
                    Picker("Modello", selection: $s.model) {
                        Text("Haiku 4.5 — economico").tag("claude-haiku-4-5")
                        Text("Sonnet 5").tag("claude-sonnet-5")
                        Text("Opus 5 — il più bravo").tag("claude-opus-5")
                    }
                    Text("Questo gira a ogni frase, quindi tienilo leggero. Il lavoro pesante va sul Mac, che usa l'abbonamento e non consuma crediti.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("GitHub — funziona sempre") {
                    SecureField("token GitHub (github_pat_…)", text: $s.githubToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("proprietario", text: $s.githubOwner)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Con questo puoi chiedere com'è messo un progetto, farti leggere un file o aprire una issue anche con il Mac spento. Token classico con scope «repo», oppure fine-grained con Contents e Issues in lettura e scrittura.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Slack") {
                    SecureField("bot token (xoxb-…)", text: $s.slackToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Crea un'app Slack, dalle il permesso chat:write, installala nel workspace e invita il bot nei canali che ti servono.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Notion") {
                    SecureField("integration token (ntn_…)", text: $s.notionToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("id della pagina principale", text: $s.notionParent)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("L'id sono le 32 cifre alla fine dell'indirizzo della pagina. Ricordati di condividere quella pagina con l'integrazione, altrimenti Notion risponde che non esiste.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Ponte al Mac — opzionale") {
                    TextField("http://100.x.y.z:8787", text: $s.bridgeURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("token del ponte", text: $s.bridgeToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Button("Prova connessione") {
                            Task { await app.bridge.checkHealth() }
                        }
                        Spacer()
                        switch app.bridge.isReachable {
                        case .some(true):
                            Label("raggiungibile", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green).font(.caption)
                        case .some(false):
                            Label("non raggiunge", systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red).font(.caption)
                        case .none:
                            EmptyView()
                        }
                    }
                    Text("Serve solo per modificare file e per Slack, mail, Notion e Drive. Richiede Tailscale e il Mac sveglio: se non risponde, tutto il resto continua a funzionare.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Contesto — a cosa lavori") {
                    if !s.bridgeURL.isEmpty {
                        Button {
                            Task {
                                if let c = await app.bridge.fetchContext() {
                                    s.personalContext = c
                                }
                            }
                        } label: {
                            Label("Sincronizza dal Mac", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    TextEditor(text: $s.personalContext)
                        .font(.caption.monospaced())
                        .frame(minHeight: 140)
                    Text(s.personalContext.isEmpty
                         ? "Vuoto: l'assistente non sa niente dei tuoi progetti. Sincronizzalo dal Mac, oppure scrivi qui a mano chi sei e su cosa stai lavorando."
                         : "\(s.personalContext.count) caratteri, mandati a ogni domanda. Resta sul telefono e funziona offline.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Voce") {
                    Picker("Voce", selection: $s.voiceIdentifier) {
                        Text("Migliore installata").tag("")
                        ForEach(Speaker.voices(for: s.transcriptionLocale), id: \.identifier) { v in
                            Text("\(v.name) — \(Speaker.qualityLabel(v))").tag(v.identifier)
                        }
                    }
                    Button {
                        let id = s.voiceIdentifier.isEmpty
                            ? (Speaker.voices(for: s.transcriptionLocale).first?.identifier ?? "")
                            : s.voiceIdentifier
                        app.assistant.speaker.rate = s.speechRate
                        app.assistant.speaker.preview(id)
                    } label: {
                        Label("Prova la voce", systemImage: "speaker.wave.2")
                    }
                    Button {
                        Speaker.requestPersonalVoice { ok in
                            app.diagnostics.log("voce", ok
                                ? "voce personale autorizzata: ora è nell'elenco"
                                : "voce personale non disponibile o negata")
                        }
                    } label: {
                        Label("Sblocca la voce personale", systemImage: "person.wave.2")
                    }
                    Text("Le voci di Siri compaiono nell'elenco ma Apple non le concede alle app di terzi: se l'anteprima suona come la voce base, è bloccata. La migliore che puoi davvero usare è una premium — Impostazioni → Accessibilità → Contenuto letto → Voci → Italiano → Federica (Premium).")
                        .font(.caption).foregroundStyle(.secondary)

                    VStack(alignment: .leading) {
                        HStack {
                            Text("Velocità")
                            Spacer()
                            Text(String(format: "%.2f", s.speechRate))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Slider(value: $s.speechRate, in: 0.40...0.70, step: 0.01)
                    }
                    Toggle("Conversazione continua", isOn: $s.continuousConversation)
                    Text("Dopo la risposta riapre il microfono da solo: puoi rispondere senza premere niente.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Impostazioni")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Fine") { showKey = false } }
        }
    }

    private var conversation: some View {
        VStack(spacing: 12) {
            Button { app.toggleAssistant() } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                    Text(label)
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(app.assistant.state == .idle && !app.isRecording
                         ? AnyButtonStyle(.borderedProminent) : AnyButtonStyle(.bordered))
            .tint(tint)
            .padding(.horizontal)
            .padding(.top, 8)

            if app.bridge.pendingCount > 0 {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("\(app.bridge.pendingCount) in lavorazione sul Mac")
                        .font(.caption)
                    Spacer()
                }
                .padding(.horizontal)
            }

            if let e = app.assistant.lastError {
                Text(e).font(.caption).foregroundStyle(.red)
                    .padding(.horizontal)
            }

            if app.assistant.lines.isEmpty {
                Spacer()
                Text("Doppio tap su «indietro» al volante per parlare.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding()
                Spacer()
            } else {
                List {
                    ForEach(app.assistant.lines.reversed()) { line in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(line.role.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(color(line.role))
                            Text(line.text)
                                .font(line.role == "azione" ? .caption : .body)
                                .foregroundStyle(line.role == "azione" ? .secondary : .primary)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private var icon: String {
        if app.isRecording { return "stop.fill" }
        switch app.assistant.state {
        case .thinking: return "ellipsis"
        case .speaking: return "speaker.wave.2.fill"
        case .idle: return "bubble.left.and.bubble.right.fill"
        }
    }

    private var label: String {
        if app.isRecording { return "Ti ascolto — tocca per chiudere" }
        switch app.assistant.state {
        case .thinking: return "Claude sta pensando…"
        case .speaking: return "Sta parlando — tocca per interrompere"
        case .idle: return "Parla con Claude"
        }
    }

    private var tint: Color {
        if app.isRecording { return .red }
        return .accentColor
    }

    private func color(_ role: String) -> Color {
        switch role {
        case "tu": return .blue
        case "claude": return .purple
        default: return .secondary
        }
    }
}

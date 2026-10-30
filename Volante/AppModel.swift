import Foundation
import MediaPlayer
import UIKit
import Observation

@MainActor
@Observable
final class AppModel {
    enum Capture { case none, note, assistant, dictation, pitch }

    let diagnostics = Diagnostics()
    let settings = AppSettings()
    let notes = NoteStore()
    let player = PodcastPlayer()
    let recorder = VoiceNoteRecorder()
    let assistant = Assistant()
    let bridge = MacBridge()
    let downloads = DownloadManager()
    let driving = DrivingContext()
    let people = PeopleStore()
    let training = TrainingStore()
    let drafts = DraftStore()
    let tripRecorder = TripRecorder()

    private(set) var trainingMode: TrainingMode?

    let library = Library()
    var permissionWarning: String?

    var episodes: [Episode] { library.episodes }
    var feedStatus: String { library.status }

    private var capture: Capture = .none
    private var conversationActive = false
    private var wasPlaying = false
    private var episodeAtStart: Episode?
    private var positionAtStart: Double?
    private var lastTap: [String: Date] = [:]
    /// After a double tap has started something, events arriving right after
    /// it must be ignored. A head unit can send several events for a single
    /// press (`previousTrack` and `skipBackward` together), and without this
    /// window the third event closes the recording that was just opened: it
    /// works from the on-screen button, but from the steering wheel it seems to
    /// do nothing.
    private var guardUntil = Date.distantPast
    private var statusResetWork: DispatchWorkItem?
    private var announcing = false
    private var pendingDictation = false
    private var pendingTraining: TrainingMode?
    private var resumePending = false
    private var pitchTarget: Double = 120
    private var lastPitchRun: UUID?
    private var playingBeforeInterruption = false
    private var macQueue: [MacBridge.Job] = []

    var isRecording: Bool { recorder.isRecording }
    var isBusy: Bool { recorder.isRecording || assistant.state != .idle }

    // MARK: - Startup

    func bootstrap() async {
        AudioSessionManager.shared.diagnostics = diagnostics
        recorder.diagnostics = diagnostics
        recorder.settings = settings
        assistant.diagnostics = diagnostics
        assistant.settings = settings
        bridge.diagnostics = diagnostics
        bridge.settings = settings
        downloads.diagnostics = diagnostics
        driving.diagnostics = diagnostics
        driving.start()

        tripRecorder.diagnostics = diagnostics
        tripRecorder.enabled = settings.tripCoach
        tripRecorder.onTripEnded = { [weak self] trip in
            self?.announceTrip(trip)
        }
        if settings.tripCoach { tripRecorder.start() }
        Haptics.warmUp()

        // Siri and automations leave a note behind: it's picked up here and every
        // time the app returns to the foreground.
        handlePendingIntent()
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handlePendingIntent() }
        }
        player.diagnostics = diagnostics
        player.rate = settings.playbackRate
        player.voiceBoost = settings.voiceBoost
        wireDownloads()

        wireAssistant()
        wireRecorder()
        wireRemoteCommands()

        // Maps announcing a turn, or a phone call: resume only if we were
        // actually playing, otherwise the app starts again on its own after you
        // paused it on purpose.
        NotificationCenter.default.addObserver(
            forName: .volanteInterrupted, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.playingBeforeInterruption = self.player.isPlaying
            }
        }
        NotificationCenter.default.addObserver(
            forName: .volanteShouldResume, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.playingBeforeInterruption, !self.isBusy else { return }
                self.playingBeforeInterruption = false
                self.player.play()
            }
        }

        VoiceNoteRecorder.requestPermissions { [weak self] micOK, warning in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.permissionWarning = micOK ? warning : "Microfono negato: l'app non puo' registrare note."
                self.diagnostics.log("permessi", "microfono: \(micOK ? "ok" : "NEGATO"), \(warning ?? "riconoscimento ok")")
            }
        }

        assistant.restore()
        bridge.restore()
        downloads.rescan()
        if !settings.bridgeURL.isEmpty { await bridge.checkHealth() }

        library.diagnostics = diagnostics
        player.loadArtwork(library.selected?.imageURL)
        restoreLastEpisode()          // from the cache, before the network even answers
        await refreshFeed()
        loadFirstIfIdle()
    }

    func refreshFeed() async {
        await library.refreshAll()
        player.loadArtwork(library.selected?.imageURL)
        restoreLastEpisode()
        syncDownloads()
    }

    func subscribe(_ s: Subscription) async {
        await library.add(s)
        player.loadArtwork(library.selected?.imageURL)
        syncDownloads()
    }

    func selectShow(_ s: Subscription) {
        library.select(s.id)
        player.loadArtwork(s.imageURL)
        if library.episodesByFeed[s.id]?.isEmpty ?? true {
            Task {
                await library.refresh(s)
                self.loadFirstIfIdle()
                self.syncDownloads()
            }
        } else {
            loadFirstIfIdle()
        }
    }

    /// If nothing is playing, cue up the first episode of the show just
    /// chosen: otherwise it stays on «Nessun episodio» ("No episode").
    private func loadFirstIfIdle() {
        guard !player.isPlaying, let e = library.episodes.first else { return }
        player.load(e, localFile: downloads.localFile(for: e.guid), autoplay: false)
    }

    private func restoreLastEpisode() {
        guard player.current == nil else { return }
        let guid = UserDefaults.standard.string(forKey: "lastEpisode")
        if let e = (guid.flatMap { library.episode(withGuid: $0) }) ?? episodes.first {
            player.load(e, localFile: downloads.localFile(for: e.guid), autoplay: false)
        }
    }

    func play(_ episode: Episode) {
        UserDefaults.standard.set(episode.guid, forKey: "lastEpisode")
        player.load(episode, localFile: downloads.localFile(for: episode.guid), autoplay: true)
    }

    // MARK: - Downloads and loudness

    private func wireDownloads() {
        downloads.onFinished = { [weak self] guid, url in
            guard let self else { return }
            // Measuring loudness takes a few seconds of computation: off the main thread.
            Task.detached(priority: .utility) {
                let lufs = Loudness.analyze(file: url)
                await MainActor.run {
                    guard let lufs else {
                        self.diagnostics.log("audio", "volume non misurabile")
                        return
                    }
                    Loudness.store(guid, lufs: lufs)
                    self.diagnostics.log("audio", String(
                        format: "misurato %.1f LUFS → correzione %+.1f dB",
                        lufs, Loudness.gain(for: guid)))
                    if self.player.current?.guid == guid {
                        // If it's already playing, the gain takes effect immediately.
                        self.player.refreshGain()
                    }
                }
            }
        }
    }

    /// Keeps the latest N episodes downloaded and throws away the rest. Runs after
    /// every feed refresh, so the night before a trip everything is already ready.
    private func syncDownloads() {
        let n = Int(settings.autoDownloadCount)
        guard n > 0 else { return }
        // The most recent across ALL shows: that's the queue you want in the car.
        let queue = library.recentAcrossAll(limit: n)
        guard !queue.isEmpty else { return }
        for e in queue where !downloads.isDownloaded(e.guid) {
            downloads.download(e)
        }
        downloads.prune(keeping: library.recentAcrossAll(limit: max(n, 8)), limit: max(n, 8))
    }

    func toggleDownload(_ episode: Episode) {
        if downloads.isDownloading(episode.guid) {
            downloads.cancel(episode.guid)
        } else if downloads.isDownloaded(episode.guid) {
            downloads.remove(episode.guid)
        } else {
            downloads.download(episode)
        }
    }

    // MARK: - Capture (note or conversation)

    func toggleNote() {
        if isBusy { stopEverything() } else { startNote() }
    }

    func toggleAssistant() {
        if isBusy { stopEverything() } else { startAssistant() }
    }

    private func stopEverything() {
        if recorder.isRecording { recorder.stop(); return }
        assistant.cancel()
        endConversation()
    }

    func startNote() {
        guard !isBusy else { return }
        capture = .note
        beginCapture(prompt: "● Nota vocale — parla", timeout: 8)
    }

    func startAssistant() {
        guard !isBusy else { return }
        capture = .assistant
        conversationActive = true
        // The conversation isn't reset on every press: within the same trip
        // «e quello di prima?» ("and the earlier one?") has to work. It resets
        // itself after six hours.
        beginCapture(prompt: "● Claude — parla", timeout: 8)
    }

    /// Pauses the podcast, plays the beep and opens the microphone. Pausing
    /// (instead of just ducking) gives the best transcription, and on its own
    /// confirms that it's listening to you.
    func startDictation() {
        guard !isBusy else { return }
        conversationActive = false
        capture = .dictation
        beginCapture(prompt: "● Dettatura — parla liberamente", timeout: 20, long: true)
    }

    private func beginCapture(prompt: String, timeout: Double, long: Bool = false) {
        // Only the FIRST capture in a sequence decides whether the podcast will be
        // resumed: follow-up turns of a conversation start with the podcast already
        // stopped, and reading `isPlaying` there would always give false.
        if !resumePending {
            wasPlaying = player.isPlaying
            resumePending = true
        }
        episodeAtStart = player.current
        positionAtStart = player.currentTime
        player.pause()
        player.statusOverride = prompt
        Tones.play(Tones.start)
        Haptics.listening()
        // We need to know whether it worked with Maps in front: that's where it's used.
        let foreground = UIApplication.shared.applicationState == .active
        diagnostics.log("nota", foreground ? "avvio in primo piano" : "avvio in SECONDO PIANO")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.recorder.start(noVoiceTimeout: timeout, long: long)
                if self.recorder.lastError != nil { self.endConversation() }
            }
        }
    }

    private func wireRecorder() {
        recorder.onCaptured = { [weak self] fileName, transcript, duration in
            guard let self else { return }
            switch self.capture {
            case .note:
                let note = VoiceNote(audioFileName: fileName,
                                     transcript: transcript,
                                     duration: duration,
                                     episodeTitle: self.episodeAtStart?.title,
                                     episodeGuid: self.episodeAtStart?.guid,
                                     episodePosition: self.positionAtStart,
                                     showTitle: self.episodeAtStart?.show,
                                     episodeAudioURL: self.episodeAtStart?.audioURL)
                self.notes.add(note)
                Tones.play(Tones.saved)
                Haptics.saved()
                self.player.statusOverride = "✓ Nota salvata"
                self.capture = .none
                self.resumeAfterDelay()

            case .assistant:
                // The conversation audio isn't needed: only the text is kept.
                try? FileManager.default.removeItem(
                    at: Paths.notesAudio.appendingPathComponent(fileName))
                let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    self.diagnostics.log("claude", "niente da trascrivere, chiudo")
                    self.endConversation()
                    return
                }
                Tones.play(Tones.saved)
                self.player.statusOverride = "◌ Claude…"
                self.assistant.ask(text)

            case .dictation:
                let note = VoiceNote(audioFileName: fileName,
                                     transcript: transcript,
                                     duration: duration,
                                     episodeTitle: self.episodeAtStart?.title,
                                     episodeGuid: self.episodeAtStart?.guid,
                                     episodePosition: self.positionAtStart,
                                     showTitle: self.episodeAtStart?.show,
                                     episodeAudioURL: self.episodeAtStart?.audioURL)
                self.notes.add(note)
                Tones.play(Tones.saved)
                Haptics.saved()
                let minutes = Int(duration / 60)
                self.player.statusOverride = "✓ Dettatura \(minutes) min"
                self.capture = .none
                self.structureDictation(transcript, minutes: minutes)
                self.resumeAfterDelay()

            case .pitch:
                Tones.play(Tones.saved)
                Haptics.saved()
                self.capture = .none
                let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.split(separator: " ").count > 15 else {
                    self.player.statusOverride = "✗ Troppo corto"
                    self.endConversation()
                    return
                }
                self.reviewPitch(text, duration: duration)

            case .none:
                break
            }
        }
        recorder.onTranscriptFinal = { [weak self] fileName, text in
            guard let self, !text.isEmpty else { return }
            self.notes.updateTranscript(fileName: fileName, transcript: text)
        }
    }

    private func wireAssistant() {
        assistant.toolContext = AssistantTools.Context(
            saveNote: { [weak self] text in
                guard let self else { return }
                self.notes.add(VoiceNote(audioFileName: "",
                                         transcript: text,
                                         duration: 0,
                                         episodeTitle: self.episodeAtStart?.title,
                                         episodeGuid: self.episodeAtStart?.guid,
                                         episodePosition: self.positionAtStart,
                                         showTitle: self.episodeAtStart?.show,
                                         episodeAudioURL: self.episodeAtStart?.audioURL))
            },
            searchNotes: { [weak self] q in
                self?.notes.search(q) ?? "Archivio note non disponibile."
            },
            sendToMac: { [weak self] richiesta, progetto in
                guard let self else { return "Ponte non disponibile." }
                return await self.bridge.submit(prompt: richiesta, project: progetto)
            },
            people: people,
            sendMessage: { [weak self] name, text in
                guard let self else { return "Non disponibile." }
                guard let person = self.people.find(name) else {
                    return "Non ho una scheda per «\(name)». Chiedigli su quale canale scrivergli e poi crea la scheda."
                }
                return await Messaging.send(to: person, text: text, drafts: self.drafts) { p, prj in
                    await self.bridge.submit(prompt: p, project: prj)
                }
            },
            startTraining: { [weak self] mode in
                self?.pendingTraining = mode
            })
        assistant.contextProvider = { [weak self] in
            guard let self else { return "" }
            var out = ""
            if let e = self.episodeAtStart {
                out += "Sta ascoltando il podcast The Learning Leader Show, episodio «\(e.title)»"
                if let p = self.positionAtStart { out += ", al minuto \(Int(p / 60))" }
                out += ".\n"
            }
            let recent = self.notes.notes.prefix(3).filter { !$0.transcript.isEmpty }
            if !recent.isEmpty {
                out += "Sue note vocali recenti:\n"
                out += recent.map { "- \($0.transcript.prefix(200))" }.joined(separator: "\n")
            }
            return out
        }
        bridge.onCompleted = { [weak self] job in
            self?.macFinished(job)
        }
        assistant.startDictation = { [weak self] in
            self?.pendingDictation = true
        }
        assistant.onFinishedSpeaking = { [weak self] in
            guard let self else { return }
            if self.pendingDictation {
                // Wait for it to finish speaking, otherwise its own voice ends up in
                // the dictation.
                self.pendingDictation = false
                self.conversationActive = false
                self.startDictation()
                return
            }
            if let mode = self.pendingTraining {
                self.pendingTraining = nil
                self.beginTraining(mode)
                return
            }
            // The verdict on the pitch just delivered is archived with the attempt,
            // so by the tenth time you can reread the trajectory.
            if let id = self.lastPitchRun {
                self.lastPitchRun = nil
                if let last = self.assistant.lines.first(where: { $0.role == "claude" }) {
                    self.training.setFeedback(last.text, for: id)
                }
                self.endTraining()
                return
            }
            if self.announcing {
                self.announcing = false
                self.endConversation()
                return
            }
            // After an error, go straight back to the podcast instead of reopening the
            // microphone for four seconds: silence after a failure is exactly what
            // makes the app look frozen.
            if self.assistant.lastError != nil {
                self.assistant.clearError()
                self.diagnostics.log("claude", "errore: chiudo e torno al podcast")
                self.endConversation()
                return
            }
            if self.conversationActive && self.settings.continuousConversation {
                // Reopens the microphone by itself: you converse without pressing anything again.
                self.beginCapture(prompt: "● Claude ascolta", timeout: 4)
            } else {
                self.endConversation()
            }
        }
    }

    private func endConversation() {
        conversationActive = false
        capture = .none
        resumeAfterDelay()
        drainMacQueue()
    }

    /// «Ehi Siri, prendi nota su Volante» ("Hey Siri, take a note in Volante") ends up here.
    private func handlePendingIntent() {
        guard let action = PendingIntent.consume() else { return }
        diagnostics.log("siri", "richiesta: \(action)")
        // A moment to breathe: the app is just becoming active and the audio
        // session hasn't settled yet.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch action {
                case "nota": self.startNote()
                case "claude": self.startAssistant()
                case "dettatura": self.startDictation()
                case "play": self.player.play()
                default: break
                }
            }
        }
    }

    // MARK: - Trip finished

    /// The summary arrives when you've been stationary for three minutes, i.e.
    /// when you've already got out or are about to: that's when you can actually
    /// listen to it.
    private func announceTrip(_ trip: Trip) {
        var text = trip.spoken
        if let avg = tripRecorder.recentAverage {
            text += trip.score > avg ? " Meglio della tua media."
                                     : (trip.score < avg - 5 ? " Sotto la tua media." : "")
        }
        if trip.hasBlackBox {
            text += " Ho salvato il minuto precedente all'evento violento."
        }
        notes.add(VoiceNote(audioFileName: "", transcript: "[Viaggio] " + text, duration: 0))
        guard !isBusy, driving.canInterrupt, settings.speakTripSummary else { return }
        announcing = true
        player.statusOverride = "✓ Viaggio — \(trip.score)/100"
        assistant.announce(text)
    }

    // MARK: - Training

    /// The pitch is a monologue that then gets measured; roleplay and English
    /// are conversations with Claude playing another character.
    func startTraining(_ mode: TrainingMode) {
        guard !isBusy else { return }
        beginTraining(mode)
    }

    private func beginTraining(_ mode: TrainingMode) {
        trainingMode = mode
        assistant.persona = mode.persona
        assistant.resetConversation()
        diagnostics.log("allena", mode.label)

        if case let .pitch(target) = mode {
            pitchTarget = target
            capture = .pitch
            conversationActive = false
            beginCapture(prompt: "● \(mode.label)", timeout: 20, long: true)
        } else {
            capture = .assistant
            conversationActive = true
            beginCapture(prompt: "● \(mode.label)", timeout: 12)
        }
    }

    func endTraining() {
        trainingMode = nil
        assistant.persona = nil
        assistant.resetConversation()
        conversationActive = false
        if isBusy { stopEverything() } else { endConversation() }
        diagnostics.log("allena", "sessione chiusa")
    }

    /// Measures locally — speed, filler words, duration — and leaves only the
    /// judgement to Claude. Numbers are numbers and cost nothing.
    private func reviewPitch(_ transcript: String, duration: Double) {
        let locale = trainingMode?.locale ?? "it-IT"
        let m = TalkMetrics.measure(transcript, seconds: duration, locale: locale)
        // The trend is read BEFORE adding this attempt, otherwise it gets compared
        // with itself.
        let trend = training.trend(for: "pitch")
        let run = TrainingRun(mode: "pitch", seconds: duration, words: m.words,
                              fillerCount: m.fillerCount, transcript: transcript)
        training.add(run)
        lastPitchRun = run.id

        let prompt = """
        Ecco il pitch che ho appena detto.

        Misure: \(m.spoken). Obiettivo di durata: \(Int(pitchTarget)) secondi.
        \(trend)

        Trascrizione:
        \(transcript)
        """
        player.statusOverride = "◌ Analisi del pitch…"
        assistant.ask(prompt)
    }

    // MARK: - Notes anchored to the episode

    /// Jumps back in the podcast to the exact moment you took the note, a few
    /// seconds earlier: whatever struck you has just gone by.
    func replay(_ note: VoiceNote, secondsBefore: Double = 30) {
        guard let guid = note.episodeGuid, let pos = note.episodePosition else {
            diagnostics.log("nota", "nota senza ancoraggio, niente da riascoltare")
            return
        }
        // Library first; if the episode has dropped out of the feed, it's rebuilt
        // from the data saved in the note.
        let episode: Episode
        if let e = library.episode(withGuid: guid) {
            episode = e
        } else if let url = note.episodeAudioURL {
            episode = Episode(guid: guid,
                              title: note.episodeTitle ?? "Episodio",
                              audioURL: url,
                              published: nil,
                              duration: nil,
                              show: note.showTitle ?? "",
                              feedID: "")
        } else {
            diagnostics.log("nota", "episodio non più disponibile, non posso riascoltare")
            return
        }

        let target = max(0, pos - secondsBefore)
        player.load(episode, localFile: downloads.localFile(for: guid),
                    autoplay: true, startAt: target)
        diagnostics.log("nota", String(format: "riascolto da %.0f s (%@)", target,
                                       downloads.isDownloaded(guid) ? "locale" : "streaming"))
    }

    private(set) var transcribingNote: UUID?

    /// Extracts from the downloaded file the seconds preceding the note and
    /// transcribes them on device: that's how the note carries the actual words
    /// with it.
    func transcribeQuote(for note: VoiceNote) async {
        guard transcribingNote == nil else { return }
        guard let guid = note.episodeGuid, let pos = note.episodePosition else { return }
        guard let file = downloads.localFile(for: guid) else {
            diagnostics.log("nota", "episodio non scaricato: non posso estrarre il passaggio")
            return
        }
        transcribingNote = note.id
        defer { transcribingNote = nil }

        let locale = settings.podcastLocale
        let id = note.id
        let text: String? = await Task.detached(priority: .userInitiated) {
            guard let clip = AudioExcerpt.extract(from: file, endingAt: pos) else { return nil }
            defer { try? FileManager.default.removeItem(at: clip) }
            return await AudioExcerpt.transcribe(clip, locale: locale)
        }.value

        guard let text, !text.isEmpty else {
            diagnostics.log("nota", "passaggio non trascrivibile")
            return
        }
        notes.setQuote(text, for: id)
        diagnostics.log("nota", "passaggio trascritto: \(text.count) caratteri")
    }

    // MARK: - Results from the Mac

    /// The heavy lifting has finished on the Mac. The full text becomes a note;
    /// only the summary line is spoken, because in the car nobody listens to a
    /// whole document.
    private func macFinished(_ job: MacBridge.Job) {
        notes.add(VoiceNote(audioFileName: "",
                            transcript: "[Mac · \(job.project)] \(job.prompt)\n\n\(job.result)",
                            duration: 0,
                            episodeTitle: nil, episodeGuid: nil, episodePosition: nil))
        if isBusy || announcing || !driving.canInterrupt {
            macQueue.append(job)
            drainMacQueue()
        } else {
            speakMac(job)
        }
    }

    /// A ten-minute stream of consciousness isn't a document. If the Mac is
    /// available it gets structured there, for free; otherwise it's left raw in
    /// the notes instead of spending credits on a very long text.
    private func structureDictation(_ text: String, minutes: Int) {
        let words = text.split(separator: " ").count
        guard words > 40 else { return }
        guard !settings.bridgeURL.isEmpty else {
            diagnostics.log("nota", "dettatura grezza salvata (\(words) parole), nessun ponte per strutturarla")
            return
        }
        let prompt = """
        Questa e' una dettatura vocale di circa \(minutes) minuti, registrata in \
        macchina mentre guidavo e trascritta automaticamente: la punteggiatura e \
        qualche parola saranno sbagliate, deducile dal contesto.

        Trasformala in un documento ordinato: un titolo, i temi separati, le \
        decisioni prese e le cose da fare come elenco alla fine. Non aggiungere \
        niente che non ho detto. Salvalo come file markdown nella cartella corrente \
        con un nome che inizia per dettatura seguito dalla data.

        ---
        \(text)
        """
        Task { _ = await bridge.submit(prompt: prompt, project: "home") }
    }

    private func drainMacQueue() {
        guard !macQueue.isEmpty, !isBusy, !announcing else { return }
        // If you're in the middle of a manoeuvre, wait: talking now is exactly
        // how to get yourself switched off.
        guard driving.canInterrupt else {
            diagnostics.log("guida", "annuncio rimandato, manovra in corso")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                MainActor.assumeIsolated { self?.drainMacQueue() }
            }
            return
        }
        speakMac(macQueue.removeFirst())
    }

    private func speakMac(_ job: MacBridge.Job) {
        announcing = true
        wasPlaying = player.isPlaying || wasPlaying
        player.pause()
        player.statusOverride = "✓ Mac — \(job.project)"
        Tones.play(Tones.saved)
        let head = job.status == "error" ? "Il Mac ha avuto un problema." : "Il Mac ha finito."
        assistant.announce("\(head) \(job.voice)")
    }

    private func resumeAfterDelay() {
        statusResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.player.statusOverride = nil }
        }
        statusResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)

        let shouldResume = wasPlaying
        wasPlaying = false
        resumePending = false
        diagnostics.log("audio", shouldResume
                        ? "riprendo il podcast"
                        : "non riprendo: non stava suonando")
        guard shouldResume else { return }
        // Half a second to let the audio route settle after the microphone
        // closes: resuming immediately catches the engine while it reconfigures.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isBusy else { return }
                self.player.play()
            }
        }
    }

    // MARK: - Steering wheel buttons

    /// If the assistant is speaking or thinking, the first press silences it and
    /// reopens the microphone: that's barge-in, the thing that makes the
    /// difference between "voice command" and "conversation".
    /// True if this event should be discarded because it arrives in the wake of
    /// an action that has just started.
    private func withinGuard(_ kind: String) -> Bool {
        guard Date() < guardUntil else { return false }
        diagnostics.log("tasto", "\(kind) ignorato: eco del doppio tap")
        return true
    }

    private func armGuard(_ seconds: Double = 1.5) {
        guardUntil = Date().addingTimeInterval(seconds)
        lastTap.removeAll()
    }

    private func interruptIfBusy() -> Bool {
        if recorder.isRecording {
            recorder.stop()
            return true
        }
        if assistant.state != .idle {
            let wasConversation = conversationActive
            assistant.cancel()
            diagnostics.log("claude", "interrotto dall'utente")
            if wasConversation {
                beginCapture(prompt: "● Claude ascolta", timeout: 4)
            } else {
                endConversation()
            }
            return true
        }
        return false
    }

    private func handleWheel(_ kind: String) -> MPRemoteCommandHandlerStatus {
        let now = Date()
        let delta = lastTap[kind].map { String(format: " (+%.0f ms)", now.timeIntervalSince($0) * 1000) } ?? ""
        diagnostics.log("tasto", kind + delta)

        if withinGuard(kind) { return .success }
        if interruptIfBusy() { return .success }

        let forward = (kind == "avanti")
        let step = forward ? settings.skipForwardSeconds : -settings.skipBackwardSeconds

        if let prev = lastTap[kind], now.timeIntervalSince(prev) < settings.doubleTapWindow {
            player.seek(by: -step)          // undo the skip from the first tap
            armGuard()                      // before starting, not after
            Haptics.recognized()
            if forward {
                diagnostics.log("tasto", "DOPPIO avanti -> nota vocale")
                startNote()
            } else if settings.backDoubleTapAction == "claude" {
                diagnostics.log("tasto", "DOPPIO indietro -> Claude")
                startAssistant()
            } else {
                diagnostics.log("tasto", "DOPPIO indietro -> nota vocale")
                startNote()
            }
        } else {
            lastTap[kind] = now
            player.seek(by: step)
        }
        return .success
    }

    /// Half the bugs in this app only reproduce at 130 km/h. The other half
    /// reproduce at the desk, if you build yourself the tool: these inject the
    /// same events the car stereo sends.
    func simulateWheel(_ kind: String) {
        diagnostics.log("test", "evento simulato: \(kind)")
        _ = handleWheel(kind)
    }

    func simulateDoubleTap(_ kind: String) {
        diagnostics.log("test", "doppio tap simulato: \(kind)")
        _ = handleWheel(kind)
        let gap = max(0.08, settings.doubleTapWindow * 0.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + gap) { [weak self] in
            MainActor.assumeIsolated { _ = self?.handleWheel(kind) }
        }
    }

    private func wireRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()

        c.playCommand.isEnabled = true
        c.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.diagnostics.log("tasto", "play")
            if self.withinGuard("play/pausa") { return .success }
            if self.interruptIfBusy() { return .success }
            self.player.play(); return .success
        }

        c.pauseCommand.isEnabled = true
        c.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.diagnostics.log("tasto", "pausa")
            if self.withinGuard("play/pausa") { return .success }
            if self.interruptIfBusy() { return .success }
            self.player.pause(); return .success
        }

        c.togglePlayPauseCommand.isEnabled = true
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.diagnostics.log("tasto", "play/pausa")
            if self.withinGuard("play/pausa") { return .success }
            if self.interruptIfBusy() { return .success }
            self.player.toggle(); return .success
        }

        c.nextTrackCommand.isEnabled = true
        c.nextTrackCommand.addTarget { [weak self] _ in
            self?.handleWheel("avanti") ?? .commandFailed
        }
        c.previousTrackCommand.isEnabled = true
        c.previousTrackCommand.addTarget { [weak self] _ in
            self?.handleWheel("indietro") ?? .commandFailed
        }

        // Some head units send skip instead of next/prev: both are covered.
        c.skipForwardCommand.isEnabled = true
        c.skipForwardCommand.preferredIntervals = [NSNumber(value: settings.skipForwardSeconds)]
        c.skipForwardCommand.addTarget { [weak self] _ in
            self?.handleWheel("avanti") ?? .commandFailed
        }
        c.skipBackwardCommand.isEnabled = true
        c.skipBackwardCommand.preferredIntervals = [NSNumber(value: settings.skipBackwardSeconds)]
        c.skipBackwardCommand.addTarget { [weak self] _ in
            self?.handleWheel("indietro") ?? .commandFailed
        }

        c.changePlaybackPositionCommand.isEnabled = true
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.player.seek(to: e.positionTime)
            return .success
        }

        c.seekForwardCommand.isEnabled = false
        c.seekBackwardCommand.isEnabled = false
        c.changeShuffleModeCommand.isEnabled = false
        c.changeRepeatModeCommand.isEnabled = false
    }
}

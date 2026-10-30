import AVFoundation
import Speech
import Observation

/// Level meter running on the microphone's real-time thread.
/// Doesn't touch actor-isolated state: only lock-protected scalars.
final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var rms: Double = 0
    private var lastVoiceAt = Date()
    private var hasSpoken = false
    private var noiseFloor: Double = 0.004
    private var calibration: [Double] = []

    func reset() {
        lock.lock()
        rms = 0; lastVoiceAt = Date(); hasSpoken = false
        noiseFloor = 0.004; calibration = []
        lock.unlock()
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        let value = Double((sum / Float(n)).squareRoot())

        lock.lock()
        rms = value
        if calibration.count < 12 {
            // The first ~1.5 s estimate the cabin's background noise.
            calibration.append(value)
            if calibration.count == 12 { noiseFloor = max(0.002, calibration.sorted()[3]) }
        } else if value > max(noiseFloor * 3.0, 0.010) {
            hasSpoken = true
            lastVoiceAt = Date()
        }
        lock.unlock()
    }

    var snapshot: (rms: Double, spoken: Bool, silence: Double, floor: Double) {
        lock.lock(); defer { lock.unlock() }
        return (rms, hasSpoken, Date().timeIntervalSince(lastVoiceAt), noiseFloor)
    }
}

/// Container for the recognition request, shared with the audio thread.
/// Needed for long dictation: there's only ever one tap while underneath the
/// recognition segment is swapped every fifty seconds.
final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ r: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); request = r; lock.unlock()
    }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); request?.append(buffer); lock.unlock()
    }
    func endAudio() {
        lock.lock(); request?.endAudio(); lock.unlock()
    }
}

/// Records from the iPhone's BUILT-IN microphone while audio keeps going out
/// over A2DP to the car stereo, transcribes on device, and — in normal
/// mode — closes by itself when you stop talking.
@MainActor
@Observable
final class VoiceNoteRecorder {

    private(set) var isRecording = false
    private(set) var level: Double = 0
    private(set) var elapsed: Double = 0
    private(set) var partialTranscript = ""
    private(set) var lastError: String?
    /// Long dictation: silence closes nothing and recognition renews itself.
    /// It's for thinking aloud for ten minutes — which is the real use of a long
    /// trip — instead of taking half-minute notes.
    private(set) var longMode = false

    /// Called right at stop: the audio is already on disk.
    var onCaptured: ((_ fileName: String, _ transcript: String, _ duration: Double) -> Void)?
    /// Called when the final transcription arrives.
    var onTranscriptFinal: ((_ fileName: String, _ transcript: String) -> Void)?
    var diagnostics: Diagnostics?
    var settings: AppSettings?

    private let engine = AVAudioEngine()
    private let meter = LevelMeter()
    private let box = RequestBox()
    private var file: AVAudioFile?
    private var fileName = ""
    private var task: SFSpeechRecognitionTask?
    private var uiTimer: Timer?
    private var startedAt = Date()
    private var noVoiceTimeout: Double = 8

    // Long dictation: recognition is split into segments and these join them back together.
    private var committed = ""
    private var segmentText = ""
    private var segmentStartedAt = Date()
    private static let segmentSeconds: Double = 50
    private static let longMaxSeconds: Double = 1_200

    // MARK: - Permissions

    static func requestPermissions(_ done: @escaping @Sendable (Bool, String?) -> Void) {
        AVAudioApplication.requestRecordPermission { micOK in
            guard micOK else { DispatchQueue.main.async { done(false, "microfono negato") }; return }
            SFSpeechRecognizer.requestAuthorization { st in
                let ok = (st == .authorized)
                DispatchQueue.main.async {
                    done(true, ok ? nil : "riconoscimento vocale negato — l'audio viene comunque salvato")
                }
            }
        }
    }

    // MARK: - Start and stop

    func start(noVoiceTimeout: Double = 8, long: Bool = false) {
        guard !isRecording else { return }
        self.noVoiceTimeout = long ? 20 : noVoiceTimeout
        longMode = long
        lastError = nil
        partialTranscript = ""
        committed = ""
        segmentText = ""
        segmentStartedAt = Date()
        elapsed = 0

        AudioSessionManager.shared.forceBuiltInMic()

        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
            fail("formato microfono non valido (\(fmt.sampleRate) Hz)")
            return
        }

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        fileName = (long ? "dettatura-" : "nota-") + stamp + ".m4a"
        let url = Paths.notesAudio.appendingPathComponent(fileName)

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: fmt.sampleRate,
                AVNumberOfChannelsKey: Int(fmt.channelCount),
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ])
        } catch {
            fail("impossibile creare il file: \(error.localizedDescription)")
            return
        }
        file = audioFile

        startSegment()
        meter.reset()

        // The tap runs in real time: capture only local references, never self.
        let meter = self.meter
        let box = self.box
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buffer, _ in
            box.append(buffer)
            try? audioFile.write(from: buffer)
            meter.feed(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            file = nil
            fail("avvio motore audio fallito: \(error.localizedDescription)")
            return
        }

        startedAt = Date()
        isRecording = true
        diagnostics?.log("nota", "\(long ? "dettatura lunga" : "nota") — \(Int(fmt.sampleRate)) Hz, ingresso: \(AudioSessionManager.shared.inputDescription)")

        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        uiTimer?.invalidate(); uiTimer = nil

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
        box.endAudio()

        let duration = Date().timeIntervalSince(startedAt)
        let text = joined(committed, segmentText)
        partialTranscript = text
        let s = meter.snapshot
        diagnostics?.log("nota", String(format: "chiusa — %.0f s, %d caratteri, rumore di fondo %.4f",
                                        duration, text.count, s.floor))
        onCaptured?(fileName, text, duration)

        let name = fileName
        // The final transcription of the last stretch may arrive later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.task?.cancel(); self.task = nil
                self.box.set(nil)
                let final = self.joined(self.committed, self.segmentText)
                if final.count > text.count { self.onTranscriptFinal?(name, final) }
            }
        }
    }

    // MARK: - Segmented recognition

    private func joined(_ a: String, _ b: String) -> String {
        let x = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let y = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if x.isEmpty { return y }
        if y.isEmpty { return x }
        return x + " " + y
    }

    private func startSegment() {
        let id = settings?.transcriptionLocale ?? "it-IT"
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: id)), rec.isAvailable else {
            diagnostics?.log("nota", "riconoscitore \(id) non disponibile: salvo solo l'audio")
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if rec.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        } else {
            diagnostics?.log("nota", "on-device non disponibile per \(id): uso la rete")
        }
        box.set(req)
        segmentText = ""
        segmentStartedAt = Date()

        let name = fileName
        task = rec.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let err = error as NSError?
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let text {
                        self.segmentText = text
                        self.partialTranscript = self.joined(self.committed, text)
                        if final, !self.isRecording {
                            self.onTranscriptFinal?(name, self.partialTranscript)
                        }
                    }
                    if let err, err.code != 216, err.code != 1110 {
                        self.diagnostics?.log("nota", "trascrizione: \(err.localizedDescription)")
                    }
                }
            }
        }
    }

    /// Closes the current segment and opens a new one, without touching the tap:
    /// recognition on iOS can't handle long sessions, audio can.
    private func rotateSegment() {
        committed = joined(committed, segmentText)
        box.endAudio()
        task?.cancel()
        task = nil
        startSegment()
        diagnostics?.log("nota", "segmento rinnovato (\(committed.count) caratteri finora)")
    }

    // MARK: - Heartbeat

    private func tick() {
        let s = meter.snapshot
        level = min(1, s.rms / 0.15)
        elapsed = Date().timeIntervalSince(startedAt)

        if longMode {
            if Date().timeIntervalSince(segmentStartedAt) >= Self.segmentSeconds {
                rotateSegment()
            }
            if elapsed >= Self.longMaxSeconds {
                diagnostics?.log("nota", "stop: venti minuti")
                stop()
            }
            return                                  // silence closes nothing
        }

        let maxLen = settings?.maxNoteSeconds ?? 120
        let maxSilence = settings?.silenceStopSeconds ?? 2.5

        if elapsed >= maxLen {
            diagnostics?.log("nota", "stop: durata massima")
            stop()
        } else if s.spoken && s.silence >= maxSilence {
            diagnostics?.log("nota", String(format: "stop: %.1f s di silenzio", s.silence))
            stop()
        } else if !s.spoken && elapsed >= noVoiceTimeout {
            diagnostics?.log("nota", "stop: nessuna voce in \(Int(noVoiceTimeout)) s")
            stop()
        }
    }

    private func fail(_ message: String) {
        lastError = message
        diagnostics?.log("nota", "ERRORE — \(message)")
        Tones.play(Tones.error)
    }
}

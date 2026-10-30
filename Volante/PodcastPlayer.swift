import AVFoundation
import MediaPlayer
import UIKit
import Observation

/// Two ways of playing, chosen automatically.
///
/// If the episode has been downloaded it goes through the audio engine, and in
/// there is the chain that's actually needed in the car: gain to bring all
/// episodes to the same loudness, EQ on the voice band, a limiter so it
/// doesn't distort after the gain. If it isn't downloaded it falls back to
/// streaming AVPlayer, which works but without processing — and that's also
/// why episodes should be downloaded the night before.
@MainActor
@Observable
final class PodcastPlayer {

    enum Backend: String { case engine, stream, none }

    private(set) var current: Episode?
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isBuffering = false
    private(set) var backend: Backend = .none
    /// Gain currently applied, in dB. Zero if the episode hasn't been measured.
    private(set) var appliedGain: Double = 0

    /// Text shown in place of the title on the car display (via AVRCP) and on
    /// the lock screen: without CarPlay it's the only visual feedback.
    var statusOverride: String? { didSet { updateNowPlaying() } }

    var rate: Double = 1.0 {
        didSet {
            timePitch.rate = Float(max(0.5, min(2.0, rate)))
            avPlayer.defaultRate = Float(rate)
            if isPlaying, backend == .stream { avPlayer.rate = Float(rate) }
            updateNowPlaying()
        }
    }

    /// EQ and limiter. The normalization gain always stays on: it's what keeps
    /// your hand off the volume knob.
    var voiceBoost = true { didSet { applyEQ() } }

    var diagnostics: Diagnostics?

    // Engine for local files
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let eq = AVAudioUnitEQ(numberOfBands: 3)
    private var limiter: AVAudioUnitEffect?
    private var file: AVAudioFile?
    private var seekFrame: AVAudioFramePosition = 0
    private var fileRate: Double = 44_100
    private var engineReady = false

    // Streaming fallback
    private let avPlayer = AVPlayer()

    /// The artwork, for the app screen as well as the lock screen.
    private(set) var coverImage: UIImage?

    private var pendingSeek: Double?
    private var ticker: Timer?
    private var artwork: MPMediaItemArtwork?
    private let showTitle = "The Learning Leader Show"

    init() {
        avPlayer.automaticallyWaitsToMinimizeStalling = true
        timePitch.overlap = 8            // fewer artifacts on fast speech
        buildChain()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }

        // Opening the microphone for a note changes the audio route, and at that
        // point iOS stops this engine and disconnects everything: without this
        // recovery, the podcast never resumes after a note.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recoverEngine() }
        }
    }

    /// Rebuilds the chain and resumes from where it was.
    private func recoverEngine() {
        guard backend == .engine, let f = file else { return }
        let position = currentTime
        let resume = isPlaying
        diagnostics?.log("audio", String(format: "motore riconfigurato, riprendo da %.0f s", position))

        node.stop()
        connectChain(format: f.processingFormat)
        applyEQ()
        guard startEngine() else {
            isPlaying = false
            return
        }
        seekFrame = frame(for: position)
        schedule(from: seekFrame)
        if resume { node.play() } else { isPlaying = false }
        updateNowPlaying()
    }

    // MARK: - Audio chain

    private func buildChain() {
        engine.attach(node)
        engine.attach(timePitch)
        engine.attach(eq)

        var desc = AudioComponentDescription()
        desc.componentType = kAudioUnitType_Effect
        desc.componentSubType = kAudioUnitSubType_PeakLimiter
        desc.componentManufacturer = kAudioUnitManufacturer_Apple
        let lim = AVAudioUnitEffect(audioComponentDescription: desc)
        engine.attach(lim)
        limiter = lim

        applyEQ()
    }

    private func applyEQ() {
        // High-pass: below 80 Hz in a car there's only rumble, and removing it
        // keeps the following gain from amplifying it.
        let hp = eq.bands[0]
        hp.filterType = .highPass
        hp.frequency = 80
        hp.bypass = !voiceBoost

        // Mud cut, where rolling noise masks the voice.
        let mud = eq.bands[1]
        mud.filterType = .parametric
        mud.frequency = 220
        mud.bandwidth = 1.0
        mud.gain = -2.0
        mud.bypass = !voiceBoost

        // Presence: it's the intelligibility band above 100 km/h.
        let presence = eq.bands[2]
        presence.filterType = .parametric
        presence.frequency = 2_600
        presence.bandwidth = 1.2
        presence.gain = 3.0
        presence.bypass = !voiceBoost

        limiter?.bypass = !voiceBoost
        eq.globalGain = Float(max(-12, min(15, appliedGain)))
    }

    private func connectChain(format: AVAudioFormat) {
        engine.disconnectNodeOutput(node)
        engine.disconnectNodeOutput(timePitch)
        engine.disconnectNodeOutput(eq)
        if let limiter { engine.disconnectNodeOutput(limiter) }

        engine.connect(node, to: timePitch, format: format)
        engine.connect(timePitch, to: eq, format: format)
        if let limiter {
            engine.connect(eq, to: limiter, format: format)
            engine.connect(limiter, to: engine.mainMixerNode, format: format)
        } else {
            engine.connect(eq, to: engine.mainMixerNode, format: format)
        }
    }

    private func startEngine() -> Bool {
        guard !engine.isRunning else { return true }
        engine.prepare()
        do {
            try engine.start()
            engineReady = true
            return true
        } catch {
            diagnostics?.log("audio", "motore non parte: \(error.localizedDescription)")
            engineReady = false
            return false
        }
    }

    // MARK: - Loading

    /// `startAt` forces the start position instead of resuming from where you
    /// were: used to go back to a note's moment.
    func load(_ episode: Episode, localFile: URL?, autoplay: Bool = true, startAt: Double? = nil) {
        savePosition()
        stopBoth()
        pendingSeek = nil
        current = episode
        duration = episode.duration ?? 0
        appliedGain = Loudness.gain(for: episode.guid)

        let resume = startAt ?? savedPosition(episode.guid)

        if let localFile, let f = try? AVAudioFile(forReading: localFile) {
            file = f
            fileRate = f.processingFormat.sampleRate
            duration = Double(f.length) / max(1, fileRate)
            backend = .engine
            connectChain(format: f.processingFormat)
            applyEQ()
            if startEngine() {
                seekFrame = frame(for: resume)
                schedule(from: seekFrame)
                currentTime = resume
                diagnostics?.log("audio", String(format: "motore — %@ · guadagno %+.1f dB",
                                                 episode.shortTitle, appliedGain))
                if autoplay { play() } else { updateNowPlaying() }
                return
            }
            // If the engine doesn't start, fall back to streaming.
            backend = .none
        }

        file = nil
        backend = .stream
        appliedGain = 0
        let item = AVPlayerItem(url: localFile ?? episode.audioURL)
        item.audioTimePitchAlgorithm = .timeDomain
        avPlayer.replaceCurrentItem(with: item)
        // When streaming, a seek requested right after `replaceCurrentItem` is
        // ignored: the item isn't ready yet. It's held pending and applied as soon
        // as it is, otherwise playback restarts from the beginning.
        if resume > 1 { pendingSeek = resume }
        currentTime = resume
        diagnostics?.log("audio", "streaming — \(episode.shortTitle)")
        if autoplay { play() } else { updateNowPlaying() }
    }

    private func frame(for seconds: Double) -> AVAudioFramePosition {
        guard let file else { return 0 }
        return max(0, min(file.length - 1, AVAudioFramePosition(seconds * fileRate)))
    }

    private func schedule(from start: AVAudioFramePosition) {
        guard let file else { return }
        let remaining = AVAudioFrameCount(max(0, file.length - start))
        guard remaining > 0 else { return }
        node.scheduleSegment(file, startingFrame: start, frameCount: remaining,
                             at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.reachedEnd() }
        }
    }

    private func reachedEnd() {
        guard backend == .engine, isPlaying else { return }
        isPlaying = false
        node.stop()
        diagnostics?.log("audio", "episodio finito")
        updateNowPlaying()
    }

    // MARK: - Commands

    func play() {
        guard current != nil else { return }
        switch backend {
        case .engine:
            // If the engine had stopped (route change, interruption), the file
            // scheduling is lost: it must be redone before playing.
            if !engine.isRunning {
                if let f = file { connectChain(format: f.processingFormat) }
                guard startEngine() else { return }
                node.stop()
                seekFrame = frame(for: currentTime)
                schedule(from: seekFrame)
                diagnostics?.log("audio", "motore riavviato prima della riproduzione")
            }
            node.play()
        case .stream:
            avPlayer.defaultRate = Float(rate)
            avPlayer.play()
            avPlayer.rate = Float(rate)
        case .none:
            return
        }
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        switch backend {
        case .engine: node.pause()
        case .stream: avPlayer.pause()
        case .none: break
        }
        isPlaying = false
        savePosition()
        updateNowPlaying()
    }

    func toggle() { isPlaying ? pause() : play() }

    func seek(by delta: Double) {
        guard current != nil else { return }
        seek(to: max(0, currentTime + delta))
    }

    func seek(to seconds: Double) {
        guard current != nil else { return }
        let target = max(0, duration > 0 ? min(seconds, duration - 1) : seconds)
        switch backend {
        case .engine:
            let wasPlaying = isPlaying
            node.stop()
            seekFrame = frame(for: target)
            schedule(from: seekFrame)
            if wasPlaying { node.play() }
        case .stream:
            if avPlayer.currentItem?.status == .readyToPlay {
                pendingSeek = nil
                avPlayer.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                              toleranceBefore: .zero, toleranceAfter: .zero)
            } else {
                pendingSeek = target
            }
        case .none:
            break
        }
        currentTime = target
        updateNowPlaying()
    }

    private func stopBoth() {
        node.stop()
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        isPlaying = false
    }

    /// Re-measures and reapplies the gain: called when the analysis finishes
    /// while the episode is already playing.
    func refreshGain() {
        guard let guid = current?.guid else { return }
        appliedGain = Loudness.gain(for: guid)
        applyEQ()
    }

    // MARK: - Time

    private func tick() {
        switch backend {
        case .engine:
            if let t = node.lastRenderTime, let p = node.playerTime(forNodeTime: t) {
                currentTime = Double(seekFrame + p.sampleTime) / max(1, fileRate)
            }
            isBuffering = false
        case .stream:
            if let target = pendingSeek, avPlayer.currentItem?.status == .readyToPlay {
                pendingSeek = nil
                avPlayer.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                              toleranceBefore: .zero, toleranceAfter: .zero)
                diagnostics?.log("audio", String(format: "seek differito a %.0f s", target))
                return
            }
            if pendingSeek != nil { return }        // don't overwrite the pending one
            let t = avPlayer.currentTime().seconds
            if t.isFinite { currentTime = t }
            if let d = avPlayer.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }
            isBuffering = avPlayer.currentItem?.isPlaybackLikelyToKeepUp == false
        case .none:
            return
        }
        savePosition()
        updateNowPlaying()
    }

    // MARK: - Saved position

    private func savedPosition(_ guid: String) -> Double {
        (UserDefaults.standard.dictionary(forKey: "positions") as? [String: Double])?[guid] ?? 0
    }

    private func savePosition() {
        guard let g = current?.guid, currentTime > 0 else { return }
        var all = (UserDefaults.standard.dictionary(forKey: "positions") as? [String: Double]) ?? [:]
        all[g] = currentTime
        UserDefaults.standard.set(all, forKey: "positions")
    }

    func progress(for episode: Episode) -> Double {
        let pos = savedPosition(episode.guid)
        guard let d = episode.duration, d > 0 else { return 0 }
        return min(1, pos / d)
    }

    // MARK: - Now Playing

    private var artworkURL: URL?

    func loadArtwork(_ url: URL?) {
        // Must be reloaded when you change show, not just once.
        guard let url, url != artworkURL else { return }
        artworkURL = url
        coverImage = nil
        Task.detached {
            guard let d = try? Data(contentsOf: url), let img = UIImage(data: d) else { return }
            let art = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
            await MainActor.run {
                self.artwork = art
                self.coverImage = img
                self.updateNowPlaying()
            }
        }
    }

    func updateNowPlaying() {
        guard let e = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: statusOverride ?? e.title,
            MPMediaItemPropertyArtist: statusOverride == nil ? showTitle : "Volante",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0,
            MPNowPlayingInfoPropertyIsLiveStream: false
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

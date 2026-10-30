import AVFoundation

/// Configures the audio session once and never changes it again.
///
/// The key point: `.playAndRecord` category active RIGHT FROM THE START, with
/// A2DP allowed and HFP NOT allowed, and input forced to the iPhone's built-in
/// microphone. That way opening the microphone for a note doesn't make the
/// Bluetooth link renegotiate, and the audio to the car stereo stays A2DP
/// stereo instead of collapsing to 8 kHz mono.
final class AudioSessionManager {
    static let shared = AudioSessionManager()
    private init() {}

    weak var diagnostics: Diagnostics?
    /// Called when the route changes (e.g. getting into or out of the car).
    var onRouteChange: ((String) -> Void)?

    func configure() {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playAndRecord,
                              mode: .default,
                              options: [.allowBluetoothA2DP, .allowAirPlay, .defaultToSpeaker])
            try s.setActive(true)
        } catch {
            log("session", "setCategory/setActive FALLITO: \(error.localizedDescription)")
        }
        forceBuiltInMic()

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(routeChanged(_:)),
                       name: AVAudioSession.routeChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(interruption(_:)),
                       name: AVAudioSession.interruptionNotification, object: nil)
        reportRoute(reason: "avvio")
    }

    /// To be reapplied on every route change: iOS tends to move the input back
    /// to the hands-free kit's microphone as soon as the car connects.
    func forceBuiltInMic() {
        let s = AVAudioSession.sharedInstance()
        // If it's already the built-in microphone, touch nothing: changing route
        // for no reason stops the playback audio engine.
        if s.currentRoute.inputs.contains(where: { $0.portType == .builtInMic }) { return }
        guard let inputs = s.availableInputs else { return }
        if let builtIn = inputs.first(where: { $0.portType == .builtInMic }) {
            do { try s.setPreferredInput(builtIn) }
            catch { log("session", "setPreferredInput fallito: \(error.localizedDescription)") }
        }
    }

    // MARK: - Route description

    var routeDescription: String {
        let r = AVAudioSession.sharedInstance().currentRoute
        let out = r.outputs.map { "\($0.portName) [\($0.portType.rawValue)]" }.joined(separator: ", ")
        return out.isEmpty ? "nessuna uscita" : out
    }

    var inputDescription: String {
        let r = AVAudioSession.sharedInstance().currentRoute
        let inp = r.inputs.map { "\($0.portName) [\($0.portType.rawValue)]" }.joined(separator: ", ")
        return inp.isEmpty ? "nessun ingresso" : inp
    }

    /// True if output is on a high-quality Bluetooth link (A2DP), false if it
    /// has dropped to HFP (the case to avoid).
    var isHighQualityBluetooth: Bool? {
        let outs = AVAudioSession.sharedInstance().currentRoute.outputs
        if outs.contains(where: { $0.portType == .bluetoothA2DP }) { return true }
        if outs.contains(where: { $0.portType == .bluetoothHFP }) { return false }
        return nil
    }

    private func reportRoute(reason: String) {
        let out = routeDescription
        let inp = inputDescription
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.diagnostics?.route = out
            self.diagnostics?.inputPort = inp
            self.diagnostics?.log("rotta", "\(reason) -> OUT: \(out) | IN: \(inp)")
            self.onRouteChange?(out)
        }
    }

    // MARK: - Notifications

    @objc private func routeChanged(_ n: Notification) {
        let raw = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
        let reason = AVAudioSession.RouteChangeReason(rawValue: raw) ?? .unknown
        forceBuiltInMic()
        reportRoute(reason: "cambio(\(reason.label))")
    }

    @objc private func interruption(_ n: Notification) {
        let raw = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
        let type = AVAudioSession.InterruptionType(rawValue: raw)
        if type == .began {
            // Happens when Maps announces a turn with «metti in pausa l'audio
            // parlato» ("pause spoken audio"), or when a phone call comes in.
            log("interruzione", "iniziata")
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .volanteInterrupted, object: nil)
            }
        } else {
            let opts = (n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map {
                AVAudioSession.InterruptionOptions(rawValue: $0)
            }
            let shouldResume = opts?.contains(.shouldResume) ?? false
            try? AVAudioSession.sharedInstance().setActive(true)
            forceBuiltInMic()
            log("interruzione", "finita (riprendi: \(shouldResume))")
            if shouldResume {
                DispatchQueue.main.async { NotificationCenter.default.post(name: .volanteShouldResume, object: nil) }
            }
        }
    }

    private func log(_ tag: String, _ text: String) {
        DispatchQueue.main.async { [weak self] in self?.diagnostics?.log(tag, text) }
    }
}

extension Notification.Name {
    static let volanteShouldResume = Notification.Name("volanteShouldResume")
    static let volanteInterrupted = Notification.Name("volanteInterrupted")
}

private extension AVAudioSession.RouteChangeReason {
    var label: String {
        switch self {
        case .newDeviceAvailable: return "nuovo dispositivo"
        case .oldDeviceUnavailable: return "dispositivo rimosso"
        case .categoryChange: return "categoria"
        case .override: return "override"
        case .routeConfigurationChange: return "riconfigurazione"
        case .wakeFromSleep: return "risveglio"
        case .noSuitableRouteForCategory: return "nessuna rotta adatta"
        default: return "altro"
        }
    }
}

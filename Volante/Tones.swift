import AVFoundation

/// Beeps generated in memory: no assets, and they go through the same audio
/// session, so they come out of the car speakers just like the podcast.
enum Tones {
    private static var players: [AVAudioPlayer] = []

    static let start = wav([(660, 0.07), (990, 0.09)])       // rising: I'm listening
    static let saved = wav([(990, 0.07), (660, 0.10)])       // falling: saved
    static let error = wav([(220, 0.18), (0, 0.05), (220, 0.18)])

    static func play(_ data: Data, volume: Float = 0.9) {
        guard let p = try? AVAudioPlayer(data: data) else { return }
        p.volume = volume
        p.prepareToPlay()
        p.play()
        players.append(p)
        if players.count > 6 { players.removeFirst(players.count - 6) }
    }

    static func wav(_ segments: [(freq: Double, dur: Double)],
                    sampleRate: Double = 44100,
                    amplitude: Double = 0.4) -> Data {
        var samples: [Int16] = []
        for seg in segments {
            let n = max(1, Int(seg.dur * sampleRate))
            let fade = sampleRate * 0.006
            for i in 0..<n {
                guard seg.freq > 0 else { samples.append(0); continue }
                let t = Double(i) / sampleRate
                let env = min(1.0, min(Double(i), Double(n - i)) / fade)
                let v = sin(2 * .pi * seg.freq * t) * amplitude * env
                samples.append(Int16(max(-1, min(1, v)) * 32767))
            }
        }
        return riff(samples: samples, sampleRate: Int(sampleRate))
    }

    private static func riff(samples: [Int16], sampleRate: Int) -> Data {
        var d = Data()
        let dataBytes = samples.count * 2
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(36 + dataBytes)
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
        u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(dataBytes)
        for s in samples { var x = s.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        return d
    }
}

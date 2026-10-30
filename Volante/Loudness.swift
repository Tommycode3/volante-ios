import AVFoundation
import Foundation

/// Measures how loud an episode is, and how much it needs correcting.
///
/// Podcasts come out at very different levels, and in a Micra at 130 km/h the
/// difference is paid for with your hand on the volume knob — that is, with
/// your hands off the wheel. Overcast normalizes everything to −14 LUFS
/// because that's the level Siri and navigation voices speak at:
/// interruptions don't make you jump. The same target is used here, and the
/// assistant's voice is brought to it too, otherwise Claude lands like a slap
/// in the middle of the episode.
///
/// The computation follows ITU-R BS.1770: shelving pre-filter, RLB filter,
/// 400 ms blocks and double gating. The whole file isn't analyzed — windows
/// are sampled across the full duration, which for an integrated level is
/// more than enough.
enum Loudness {

    static let target: Double = -14.0        // LUFS
    static let maxBoost: Double = 15.0       // dB, beyond this you hear pumping
    static let maxCut: Double = -12.0

    // MARK: - Stored values

    private static let key = "loudnessLUFS"

    static func stored(_ guid: String) -> Double? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Double])?[guid]
    }

    static func store(_ guid: String, lufs: Double) {
        var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:]
        all[guid] = lufs
        UserDefaults.standard.set(all, forKey: key)
    }

    static func forget(_ guid: String) {
        var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:]
        all[guid] = nil
        UserDefaults.standard.set(all, forKey: key)
    }

    /// Gain in dB to apply to this episode. Zero if I haven't measured it:
    /// better to touch nothing than to guess.
    static func gain(for guid: String) -> Double {
        guard let lufs = stored(guid), lufs.isFinite, lufs > -70 else { return 0 }
        return min(maxBoost, max(maxCut, target - lufs))
    }

    // MARK: - Analysis

    /// Runs off the main thread: it's a few seconds of computation.
    static func analyze(file url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let rate = format.sampleRate
        guard rate > 0, file.length > 0 else { return nil }

        let shelf = Biquad.highShelf(f0: 1681.97, gainDB: 3.9997, q: 0.7071, rate: rate)
        let rlb = Biquad.highPass(f0: 38.135, q: 0.5, rate: rate)

        let blockFrames = AVAudioFrameCount(rate * 0.4)          // 400 ms blocks
        let windowFrames = AVAudioFrameCount(rate * 30)          // 30 s windows
        let windows = max(1, min(20, Int(Double(file.length) / Double(windowFrames))))
        let stride = max(Int64(windowFrames), file.length / Int64(windows))

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: blockFrames) else { return nil }

        var blockLoudness: [Double] = []
        var blockPower: [Double] = []

        for w in 0..<windows {
            let start = Int64(w) * stride
            guard start < file.length else { break }
            file.framePosition = start
            var consumed: AVAudioFrameCount = 0

            while consumed < windowFrames, file.framePosition < file.length {
                buffer.frameLength = 0
                guard (try? file.read(into: buffer, frameCount: blockFrames)) != nil,
                      buffer.frameLength > 0 else { break }
                consumed += buffer.frameLength

                let n = Int(buffer.frameLength)
                guard let channels = buffer.floatChannelData else { break }
                let channelCount = Int(format.channelCount)

                // Sum of channels after K-filtering: for mono and stereo the standard's
                // channel weight is 1, so summing is enough.
                var power = 0.0
                for c in 0..<min(channelCount, 2) {
                    var s1 = shelf, s2 = rlb
                    let data = channels[c]
                    var sum = 0.0
                    for i in 0..<n {
                        let x = Double(data[i])
                        let y = s2.process(s1.process(x))
                        sum += y * y
                    }
                    power += sum / Double(n)
                }
                guard power > 0 else { continue }
                blockPower.append(power)
                blockLoudness.append(-0.691 + 10 * log10(power))
            }
        }

        guard !blockPower.isEmpty else { return nil }

        // Absolute gating at −70 LUFS.
        var keptPower: [Double] = []
        for (i, l) in blockLoudness.enumerated() where l > -70 {
            keptPower.append(blockPower[i])
        }
        guard !keptPower.isEmpty else { return nil }

        // Relative gating: 10 LU below the mean of what's left.
        let meanKept = keptPower.reduce(0, +) / Double(keptPower.count)
        let relative = -0.691 + 10 * log10(meanKept) - 10
        var finalPower: [Double] = []
        for (i, l) in blockLoudness.enumerated() where l > -70 && l > relative {
            finalPower.append(blockPower[i])
        }
        let pool = finalPower.isEmpty ? keptPower : finalPower
        let mean = pool.reduce(0, +) / Double(pool.count)
        let lufs = -0.691 + 10 * log10(mean)
        return lufs.isFinite ? lufs : nil
    }
}

/// Biquad in transposed direct form II, RBJ coefficients.
struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var z1 = 0.0, z2 = 0.0

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    static func highShelf(f0: Double, gainDB: Double, q: Double, rate: Double) -> Biquad {
        let A = pow(10, gainDB / 40)
        let w = 2 * Double.pi * f0 / rate
        let cw = cos(w), sw = sin(w)
        let alpha = sw / (2 * q)
        let sqA = sqrt(A)
        let a0 = (A + 1) - (A - 1) * cw + 2 * sqA * alpha
        var f = Biquad()
        f.b0 = A * ((A + 1) + (A - 1) * cw + 2 * sqA * alpha) / a0
        f.b1 = -2 * A * ((A - 1) + (A + 1) * cw) / a0
        f.b2 = A * ((A + 1) + (A - 1) * cw - 2 * sqA * alpha) / a0
        f.a1 = 2 * ((A - 1) - (A + 1) * cw) / a0
        f.a2 = ((A + 1) - (A - 1) * cw - 2 * sqA * alpha) / a0
        return f
    }

    static func highPass(f0: Double, q: Double, rate: Double) -> Biquad {
        let w = 2 * Double.pi * f0 / rate
        let cw = cos(w), sw = sin(w)
        let alpha = sw / (2 * q)
        let a0 = 1 + alpha
        var f = Biquad()
        f.b0 = (1 + cw) / 2 / a0
        f.b1 = -(1 + cw) / a0
        f.b2 = (1 + cw) / 2 / a0
        f.a1 = -2 * cw / a0
        f.a2 = (1 - alpha) / a0
        return f
    }
}

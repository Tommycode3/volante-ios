import AVFoundation
import Speech

/// Clips and transcribes the piece of podcast you were listening to when you
/// took the note.
///
/// It's the reason it's worth downloading episodes instead of streaming
/// them: with the file on the phone you can go back thirty seconds and read
/// *the actual words* that made you press the button. The note stops being
/// «a thought at 34:07» and becomes the thought next to the sentence that
/// triggered it.
enum AudioExcerpt {

    /// Clips the `seconds` preceding `endingAt`: a note is always taken *after*
    /// hearing something, so the interesting part is the one before.
    static func extract(from file: URL, endingAt: Double, seconds: Double = 45) -> URL? {
        guard let src = try? AVAudioFile(forReading: file) else { return nil }
        let format = src.processingFormat
        let rate = format.sampleRate
        guard rate > 0, src.length > 0 else { return nil }

        let total = Double(src.length) / rate
        let end = min(total, max(1, endingAt))
        let start = max(0, end - seconds)
        let frames = AVAudioFrameCount((end - start) * rate)
        guard frames > 0 else { return nil }

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("estratto-\(UUID().uuidString.prefix(8)).m4a")

        guard let dst = try? AVAudioFile(forWriting: out, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: Int(min(format.channelCount, 2)),
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]) else { return nil }

        src.framePosition = AVAudioFramePosition(start * rate)
        let chunk = AVAudioFrameCount(rate)          // one second at a time
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return nil }

        var written: AVAudioFrameCount = 0
        while written < frames, src.framePosition < src.length {
            buffer.frameLength = 0
            let want = min(chunk, frames - written)
            guard (try? src.read(into: buffer, frameCount: want)) != nil,
                  buffer.frameLength > 0 else { break }
            guard (try? dst.write(from: buffer)) != nil else { break }
            written += buffer.frameLength
        }
        return written > 0 ? out : nil
    }

    /// Transcribes on device. No network, no cost, works in a tunnel.
    static func transcribe(_ url: URL, locale id: String = "en-US") async -> String? {
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: id)), rec.isAvailable else {
            return nil
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        if rec.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        return await withCheckedContinuation { continuation in
            var resumed = false
            rec.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let result, result.isFinal {
                    resumed = true
                    let text = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: text.isEmpty ? nil : text)
                } else if error != nil {
                    resumed = true
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

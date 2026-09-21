import AVFoundation
import Foundation

/// Decodes an audio file into the one format the native ASR runtimes accept:
/// mono float32 at 16 kHz, in [-1, 1].
///
/// `Transcriber` already hands local engines a 16 kHz mono WAV, so this is
/// usually a straight read — but it goes through AVAudioConverter anyway, so a
/// file that arrives in some other shape (a user-picked recording, a future
/// change to the merge pipeline) is resampled instead of silently transcribed
/// at the wrong speed.
/// подход из amanu (MIT, gsamat/amanu): Transcription/WhisperEngine.swift (WhisperPCMReader)
enum AudioPCM {
    static let sampleRate: Double = 16_000

    enum Failure: LocalizedError {
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): return "не удалось прочитать аудио \(name)"
            }
        }
    }

    /// Read the whole file as 16 kHz mono float samples.
    ///
    /// Read whole rather than streamed on purpose: `Transcriber` never hands an
    /// engine more than a 10-minute segment, which is ~38 MB of float32 — small
    /// enough that a streaming converter would only buy complexity.
    static func monoFloatSamples(of url: URL) throws -> [Float] {
        var samples = [Float]()
        try decodeBlocks(of: url,
                         estimate: { samples.reserveCapacity($0 + Int(sampleRate)) },
                         block: { samples.append(contentsOf: $0) })
        guard !samples.isEmpty else { throw Failure.unreadable(url.lastPathComponent) }
        return samples
    }

    /// The decode itself, handing each converted block to `block` instead of
    /// collecting it. A caller that only needs a summary of the audio (how loud
    /// it is minute by minute, say) can then read a two-hour file without ever
    /// holding two hours of float32 — which is half a gigabyte.
    ///
    /// `estimate` is called once, before the first block, with the number of
    /// samples the file is expected to produce.
    private static func decodeBlocks(of url: URL,
                                     estimate: (Int) -> Void = { _ in },
                                     block: (UnsafeBufferPointer<Float>) -> Void) throws {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw Failure.unreadable(url.lastPathComponent)
        }
        guard file.length > 0, file.processingFormat.sampleRate > 0 else {
            throw Failure.unreadable(url.lastPathComponent)
        }

        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: sampleRate,
                                            channels: 1,
                                            interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: outFormat),
              let inBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                              frameCapacity: 32_768)
        else { throw Failure.unreadable(url.lastPathComponent) }

        estimate(Int((Double(file.length) * sampleRate / file.processingFormat.sampleRate).rounded()))

        // 10 s of output per conversion pass — big enough to keep the
        // per-call overhead irrelevant, small enough not to spike memory.
        let outCapacity = AVAudioFrameCount(sampleRate * 10)
        var readError: Error?

        while true {
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else { break }
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, state in
                // AVAudioFile throws an unhelpful `nilError` when asked to read
                // once more at exact EOF; its frame position is the reliable
                // end-of-file signal, so that last read is never made.
                if file.framePosition >= file.length {
                    state.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: inBuffer)
                    if inBuffer.frameLength == 0 {
                        state.pointee = .endOfStream
                        return nil
                    }
                    state.pointee = .haveData
                    return inBuffer
                } catch {
                    readError = error
                    state.pointee = .endOfStream
                    return nil
                }
            }
            if readError != nil || conversionError != nil {
                throw Failure.unreadable(url.lastPathComponent)
            }
            if outBuffer.frameLength > 0, let channel = outBuffer.floatChannelData?[0] {
                block(UnsafeBufferPointer(start: channel, count: Int(outBuffer.frameLength)))
            }
            if status == .endOfStream || status == .error { break }
        }
    }

    // MARK: - Cutting long audio

    /// A fixed-length cut lands mid-word roughly as often as not, and a word
    /// cut in half is either invented or dropped by whatever decodes it — the
    /// damage shows up at every boundary of a long call ("…пойдём другим юм." /
    /// "..ц Мы будем делать новое юрлицо…"). Snapping the cut to the quietest
    /// moment nearby puts it in a pause instead, for the cost of one linear
    /// scan over the audio. Two callers need it: an engine slicing samples it
    /// has in memory, and `Transcriber` cutting a long recording into segments
    /// with ffmpeg — so the rule itself lives in `cutWindows`, and both come to
    /// it through a loudness envelope.

    /// Resolution of that envelope, and so of every cut: 100 ms.
    private static let cutWindow = Int(sampleRate / 10)

    /// Split samples into pieces no longer than `maxSeconds`, cutting at the
    /// quietest moment inside the last `searchSeconds` of each piece.
    static func chunks(_ samples: [Float], maxSeconds: Double, searchSeconds: Double = 5) -> [ArraySlice<Float>] {
        let maxLen = Int(maxSeconds * sampleRate)
        guard maxLen > cutWindow, samples.count > maxLen else { return [samples[...]] }

        var envelope: [Float] = []
        envelope.reserveCapacity(samples.count / cutWindow + 1)
        var i = 0
        while i < samples.count {
            let end = min(i + cutWindow, samples.count)
            envelope.append(loudness(of: samples[i..<end]))
            i = end
        }

        var result: [ArraySlice<Float>] = []
        var start = 0
        for cut in cutWindows(envelope, maxSeconds: maxSeconds, searchSeconds: searchSeconds) {
            let end = min(cut * cutWindow + cutWindow / 2, samples.count)
            guard end > start else { continue }
            result.append(samples[start..<end])
            start = end
        }
        if start < samples.count { result.append(samples[start...]) }
        return result
    }

    /// The same cuts, as offsets in seconds, for a file that is going to be cut
    /// by something else (ffmpeg) rather than sliced in memory. Streams the
    /// decode and keeps only the envelope, so the length of the recording does
    /// not decide how much memory this costs.
    ///
    /// Returns the interior cut points only — never 0 or the end of the file.
    static func cutPoints(of url: URL, maxSeconds: Double, searchSeconds: Double = 5) throws -> [TimeInterval] {
        var envelope: [Float] = []
        var sum: Float = 0
        var filled = 0
        try decodeBlocks(of: url) { samples in
            for sample in samples {
                sum += abs(sample)
                filled += 1
                if filled == cutWindow {
                    envelope.append(sum / Float(cutWindow))
                    sum = 0
                    filled = 0
                }
            }
        }
        // A short last window would look quiet just for being short.
        if filled > 0 { envelope.append(sum / Float(filled)) }
        guard !envelope.isEmpty else { throw Failure.unreadable(url.lastPathComponent) }

        return cutWindows(envelope, maxSeconds: maxSeconds, searchSeconds: searchSeconds)
            .map { Double($0 * cutWindow + cutWindow / 2) / sampleRate }
    }

    /// Mean |sample| — how loud this stretch is, in one number.
    private static func loudness(of samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += abs(sample) }
        return sum / Float(samples.count)
    }

    /// The cut rule, on an envelope of 100 ms loudness values: walk forward at
    /// most `maxSeconds` at a time, and put each cut in the quietest window of
    /// the `searchSeconds` before that limit. Returns window indices.
    private static func cutWindows(_ envelope: [Float],
                                   maxSeconds: Double,
                                   searchSeconds: Double) -> [Int] {
        let maxWindows = max(1, Int(maxSeconds * sampleRate) / cutWindow)
        let searchWindows = min(Int(searchSeconds * sampleRate) / cutWindow, maxWindows / 2)

        var cuts: [Int] = []
        var start = 0
        while start + maxWindows < envelope.count {
            let hardEnd = start + maxWindows
            var best = hardEnd
            var bestLoudness = Float.greatestFiniteMagnitude
            var i = max(start + 1, hardEnd - searchWindows)
            while i < hardEnd {
                if envelope[i] < bestLoudness {
                    bestLoudness = envelope[i]
                    best = i
                }
                i += 1
            }
            if best <= start { best = hardEnd }  // degenerate audio — take the hard cut
            cuts.append(best)
            start = best
        }
        return cuts
    }
}

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

        let estimated = Int((Double(file.length) * sampleRate / file.processingFormat.sampleRate).rounded())
        var samples = [Float]()
        samples.reserveCapacity(estimated + Int(sampleRate))

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
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(outBuffer.frameLength)))
            }
            if status == .endOfStream || status == .error { break }
        }

        guard !samples.isEmpty else { throw Failure.unreadable(url.lastPathComponent) }
        return samples
    }

    /// Split samples into pieces no longer than `maxSeconds`, cutting at the
    /// quietest moment inside the last `searchSeconds` of each piece.
    ///
    /// A fixed-length cut lands mid-word roughly as often as not, and an ASR
    /// model asked to decode half a word either invents one or drops it — the
    /// damage shows up at every chunk boundary of a long call. Snapping the cut
    /// to a local energy minimum puts it in a pause instead, for the cost of one
    /// linear scan over a few seconds of audio.
    static func chunks(_ samples: [Float], maxSeconds: Double, searchSeconds: Double = 5) -> [ArraySlice<Float>] {
        let maxLen = Int(maxSeconds * sampleRate)
        guard maxLen > 0 else { return [samples[...]] }
        let searchLen = min(Int(searchSeconds * sampleRate), maxLen / 2)

        var result: [ArraySlice<Float>] = []
        var start = 0
        while start < samples.count {
            let hardEnd = min(start + maxLen, samples.count)
            var end = hardEnd
            if hardEnd < samples.count, searchLen > 0 {
                end = quietestCut(samples, from: hardEnd - searchLen, to: hardEnd)
            }
            if end <= start { end = hardEnd }  // degenerate audio — fall back to the hard cut
            result.append(samples[start..<end])
            start = end
        }
        return result
    }

    /// Index of the centre of the lowest-energy 100 ms window in `from..<to`.
    private static func quietestCut(_ samples: [Float], from: Int, to: Int) -> Int {
        let window = Int(sampleRate / 10)  // 100 ms
        guard to - from > window else { return to }
        var bestIndex = to
        var bestEnergy = Float.greatestFiniteMagnitude
        var i = from
        while i + window <= to {
            var energy: Float = 0
            for s in samples[i..<(i + window)] { energy += abs(s) }
            if energy < bestEnergy {
                bestEnergy = energy
                bestIndex = i + window / 2
            }
            i += window
        }
        return bestIndex
    }
}

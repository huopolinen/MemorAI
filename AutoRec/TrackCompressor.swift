import AVFoundation
import Foundation

/// Turns a finished session's uncompressed PCM tracks into AAC — but only once
/// the transcript exists.
///
/// Recording writes PCM because that is the only format that survives a hard
/// kill (see `AudioFormats`), at about a gigabyte an hour across both tracks.
/// That is a reasonable price for the duration of a call and an absurd one for
/// an archive, so the PCM is traded for AAC as soon as it has done its job.
///
/// The order is the whole safety argument and is not negotiable: transcript
/// first, then compression. A session that failed to transcribe — engine not
/// configured, network down, the call too quiet — never reaches this code, and
/// keeps its .caf files forever. That recording is the only copy of the call,
/// and a later retry is all it has.
///
/// подход из amanu (MIT, gsamat/amanu): Audio/TrackCompressor.swift
enum TrackCompressor {
    /// Archive a session's tracks if — and only if — it has a transcript.
    ///
    /// Safe to call more than once: a session that is already archived has no
    /// .caf files left to compress and falls straight through.
    static func settleAfterTranscript(tag: String, in directory: URL) {
        guard SessionMeta.hasTranscript(tag: tag, in: directory) else {
            let pcm = pcmTracks(tag: tag, in: directory)
            if !pcm.isEmpty {
                log("[TrackCompressor] \(tag): транскрипта нет — оставляю \(pcm.count) несжатую дорожку(и). Это единственная копия звонка.")
            }
            return
        }

        var archived: [String: String] = [:]
        var freed: Int64 = 0
        for (role, source) in pcmTracks(tag: tag, in: directory) {
            let before = size(of: source)
            do {
                let destination = try compress(track: source)
                archived[role] = destination.lastPathComponent
                freed += before - size(of: destination)
            } catch {
                // One track failing must not cost the other its archive, and
                // must never cost either its original.
                log("[TrackCompressor] ⚠️ \(tag)/\(role): сжатие не удалось (\(error.localizedDescription)) — оставляю \(source.lastPathComponent)")
            }
        }

        guard !archived.isEmpty else { return }

        // meta.json is repointed at the .m4a files *before* the .caf files go,
        // so an interruption at any moment leaves a session whose marker names
        // files that actually exist.
        var files = (SessionMeta.read(tag: tag, in: directory)?["files"] as? [String: String]) ?? [:]
        for (role, name) in archived { files[role] = name }
        SessionMeta.update(tag: tag, in: directory, with: [
            "files": files,
            "compressed": true,
            "status": SessionMeta.Status.done.rawValue,
        ])

        for (role, _) in archived {
            let pcm = directory.appendingPathComponent("\(tag)_\(role).\(AudioFormats.trackExtension)")
            try? FileManager.default.removeItem(at: pcm)
        }
        log("[TrackCompressor] ✅ \(tag): дорожки сжаты в m4a, освобождено \(mb(freed))")
    }

    // MARK: -

    enum CompressionError: Error, LocalizedError {
        case unreadable(String)
        case encoderUnavailable
        case tooShort(source: Double, encoded: Double)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): return "не читается: \(name)"
            case .encoderUnavailable: return "AAC-кодировщик недоступен для этого формата"
            case .tooShort(let source, let encoded):
                return String(format: "закодировано %.1f с из %.1f с", encoded, source)
            }
        }
    }

    /// Encode one PCM track to AAC beside itself and return the new file.
    ///
    /// The encode goes to a `.tmp.m4a` and is verified against the source's
    /// duration before it is moved into place; the caller deletes the original
    /// only after that. A crash anywhere in here leaves at worst a stray temp
    /// file and an untouched original.
    static func compress(track source: URL) throws -> URL {
        guard let input = try? AVAudioFile(forReading: source), input.length > 0 else {
            throw CompressionError.unreadable(source.lastPathComponent)
        }
        let format = input.processingFormat
        let sourceSeconds = Double(input.length) / format.sampleRate

        let destination = source.deletingPathExtension()
            .appendingPathExtension(AudioFormats.archiveExtension)
        let temporary = source.deletingPathExtension()
            .appendingPathExtension("tmp.\(AudioFormats.archiveExtension)")
        try? FileManager.default.removeItem(at: temporary)

        // HE-AAC is what the system-audio track has always been encoded with
        // (48 kbit/s stereo), and 24 kbit/s per channel keeps that exact
        // bitrate while giving the mono mic track a sensible one. HE-AAC is
        // picky about rates and channel layouts though, so a refusal falls back
        // to plain AAC rather than leaving the track uncompressed forever.
        let channels = Int(format.channelCount)
        let attempts: [(id: AudioFormatID, bitrate: Int, label: String)] = [
            (kAudioFormatMPEG4AAC_HE, 24_000 * channels, "HE-AAC"),
            (kAudioFormatMPEG4AAC, 32_000 * channels, "AAC-LC"),
        ]

        var lastError: Error = CompressionError.encoderUnavailable
        for attempt in attempts {
            do {
                try encode(input, to: temporary, format: format,
                           formatID: attempt.id, bitrate: attempt.bitrate)
            } catch {
                lastError = error
                try? FileManager.default.removeItem(at: temporary)
                // Rewind: the failed attempt consumed part of the source.
                input.framePosition = 0
                continue
            }

            // Trusting the encoder's exit status is not enough — a truncated
            // encode reports success. Compare durations before anything is
            // deleted; 1% covers AAC's encoder priming/padding.
            guard let encoded = try? AVAudioFile(forReading: temporary), encoded.length > 0 else {
                lastError = CompressionError.unreadable(temporary.lastPathComponent)
                try? FileManager.default.removeItem(at: temporary)
                input.framePosition = 0
                continue
            }
            let encodedSeconds = Double(encoded.length) / encoded.processingFormat.sampleRate
            guard encodedSeconds >= sourceSeconds * 0.99 else {
                lastError = CompressionError.tooShort(source: sourceSeconds, encoded: encodedSeconds)
                try? FileManager.default.removeItem(at: temporary)
                input.framePosition = 0
                continue
            }

            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            log("[TrackCompressor] \(source.lastPathComponent) → \(destination.lastPathComponent)"
                + " (\(attempt.label), \(mb(size(of: source))) → \(mb(size(of: destination))))")
            return destination
        }

        throw lastError
    }

    /// Stream the source through the encoder a second at a time, so a two-hour
    /// call never costs more than a second of audio in memory.
    private static func encode(
        _ input: AVAudioFile,
        to destination: URL,
        format: AVAudioFormat,
        formatID: AudioFormatID,
        bitrate: Int
    ) throws {
        let output = try AVAudioFile(
            forWriting: destination,
            settings: [
                AVFormatIDKey: formatID,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderBitRateKey: bitrate,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let blockFrames = AVAudioFrameCount(format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames) else {
            throw CompressionError.encoderUnavailable
        }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
        }
    }

    /// The session's still-uncompressed tracks, by role.
    private static func pcmTracks(tag: String, in directory: URL) -> [(role: String, url: URL)] {
        ["mic", "system"].compactMap { role in
            let url = directory.appendingPathComponent(
                "\(tag)_\(role).\(AudioFormats.trackExtension)")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return (role: role, url: url)
        }
    }

    private static func size(of url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0
    }

    private static func mb(_ bytes: Int64) -> String {
        String(format: "%.1f МБ", Double(bytes) / 1_048_576)
    }
}

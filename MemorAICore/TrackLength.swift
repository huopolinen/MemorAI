import Foundation

/// How long a recorded track is — and, just as important, whether we know.
///
/// Why this exists: on 18.11 a 49-minute call (`call_2026-11-18_18-06-19`)
/// was never transcribed. Right after the call the transcriber asked ffmpeg
/// for the length of two uncompressed tracks (280 MB and 570 MB) while the
/// video mux was reading the very same files; both probes hit their 15 s
/// timeout, the failure came back as "0 seconds", and 0 seconds is "too short
/// to transcribe". The session marker already held the real lengths
/// (`track_seconds`: 2956.8 / 2957.9) — nobody asked it.
///
/// Two rules follow, and both live here so they can be tested without audio:
///
/// - A length we failed to measure is `unknown`, never zero. Only a length we
///   actually measured can make a recording "too short".
/// - Ask the cheap, certain sources first: the number already written into
///   `meta.json` at stop, then the CAF header (pure arithmetic on a few
///   bytes), and only then anything that spawns a process.
public enum TrackLength: Equatable, Sendable {
    /// There is no file for this track.
    case missing
    /// The track is this many seconds long.
    case measured(Double)
    /// The file exists, but nothing could tell how long it is.
    case unknown

    /// First source that answers wins; each one is asked only if every source
    /// before it had nothing to say, so a slow fallback never runs when a
    /// fast one already knows.
    public static func resolve(fileExists: Bool, sources: [() -> Double?]) -> TrackLength {
        guard fileExists else { return .missing }
        for source in sources {
            if let seconds = source(), seconds.isFinite, seconds >= 0 {
                return .measured(seconds)
            }
        }
        return .unknown
    }

    /// Measured length, or nil for missing and unknown.
    public var seconds: Double? {
        if case .measured(let s) = self { return s }
        return nil
    }

    /// Long enough to be worth transcribing. Unknown is not long enough —
    /// but it is not short either; see `TranscriptionGate`.
    public func isUsable(minSeconds: Double) -> Bool {
        (seconds ?? 0) >= minSeconds
    }
}

/// Whether a session can be transcribed now, given what is known about its
/// tracks.
public enum TranscriptionGate: Equatable, Sendable {
    /// Go ahead with these tracks.
    case proceed(mic: Bool, system: Bool)
    /// Every track was measured and none is long enough. The one case where
    /// skipping is the right answer.
    case tooShort
    /// At least one track exists but its length could not be determined.
    /// Try again later; never treat it as an empty recording.
    case undetermined

    /// - Parameter finalAttempt: on the last try a track that is still unknown
    ///   no longer holds up one that was measured — half a transcript beats
    ///   none. With nothing measured at all it stays `undetermined`.
    public static func decide(
        mic: TrackLength, system: TrackLength, minSeconds: Double, finalAttempt: Bool
    ) -> TranscriptionGate {
        let micOK = mic.isUsable(minSeconds: minSeconds)
        let sysOK = system.isUsable(minSeconds: minSeconds)
        let anyUnknown = mic == .unknown || system == .unknown

        if anyUnknown && !(finalAttempt && (micOK || sysOK)) {
            return .undetermined
        }
        if micOK || sysOK { return .proceed(mic: micOK, system: sysOK) }
        return .tooShort
    }

    /// Pauses before each retry when a length is undetermined. The first try
    /// happens right after the call, when the video mux is still reading the
    /// same tracks; by the later ones the disk is quiet again.
    public static let retryDelays: [TimeInterval] = [60, 180, 600]
}

/// Length of a CAF file straight from its header — no AVFoundation, no ffmpeg,
/// no process to time out.
///
/// Only constant-bitrate linear PCM is answered (that is what MemorAI records,
/// see `AudioFormats` in the app); anything else returns nil and the caller
/// falls through to a slower source. A data chunk whose size is -1 (the file
/// is still open, or the writer was killed) extends to the end of the file,
/// and a torn final frame is not counted.
public enum CAFHeader {
    /// How many leading bytes to read: CoreAudio puts `desc`, the channel
    /// layout, a `free` padding chunk and the `data` header well inside this.
    public static let headerBytes = 64 * 1024

    /// - Parameters:
    ///   - header: the first bytes of the file (`headerBytes` is plenty).
    ///   - fileSize: the whole file's size, needed when the data chunk is open.
    public static func duration(header: Data, fileSize: Int64) -> Double? {
        let bytes = [UInt8](header)
        guard bytes.count >= 8, Array(bytes[0..<4]) == Array("caff".utf8) else { return nil }

        var offset = 8
        var sampleRate: Double = 0
        var bytesPerFrame: Int64 = 0

        while offset + 12 <= bytes.count {
            let type = Array(bytes[offset..<offset + 4])
            let size = Int64(bitPattern: beUInt64(bytes, offset + 4))
            let payload = offset + 12

            if type == Array("desc".utf8) {
                guard payload + 32 <= bytes.count else { return nil }
                // CAFAudioFormat: mSampleRate(8) mFormatID(4) mFormatFlags(4)
                // mBytesPerPacket(4) mFramesPerPacket(4) mChannelsPerFrame(4)
                // mBitsPerChannel(4), all big-endian.
                sampleRate = Double(bitPattern: beUInt64(bytes, payload))
                let bytesPerPacket = Int64(beUInt32(bytes, payload + 16))
                let framesPerPacket = Int64(beUInt32(bytes, payload + 20))
                guard framesPerPacket == 1, bytesPerPacket > 0,
                      sampleRate.isFinite, sampleRate > 0 else { return nil }
                bytesPerFrame = bytesPerPacket
            }

            if type == Array("data".utf8) {
                guard bytesPerFrame > 0 else { return nil }
                // The payload starts with a 4-byte mEditCount, then audio.
                let audioBytes: Int64
                if size == -1 {
                    audioBytes = fileSize - Int64(payload) - 4
                } else {
                    guard size >= 4 else { return size == 0 ? 0 : nil }
                    // A closed header that claims more than the file holds is
                    // a truncated file: only what is on disk is playable.
                    audioBytes = min(size, fileSize - Int64(payload)) - 4
                }
                guard audioBytes >= 0 else { return nil }
                return Double(audioBytes / bytesPerFrame) / sampleRate
            }

            guard size >= 0 else { return nil }
            offset = payload + Int(clamping: size)
        }
        return nil
    }

    /// Read the header of `url` and answer from it.
    public static func duration(of url: URL) -> Double? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64,
              let header = try? handle.read(upToCount: headerBytes)
        else { return nil }
        return duration(header: header, fileSize: size)
    }

    private static func beUInt32(_ b: [UInt8], _ i: Int) -> UInt32 {
        b[i..<i + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func beUInt64(_ b: [UInt8], _ i: Int) -> UInt64 {
        b[i..<i + 8].reduce(0) { $0 << 8 | UInt64($1) }
    }
}

/// What to do with a finished session's uncompressed tracks.
///
/// The compact .m4a copy no longer waits for the transcript: a session whose
/// transcription failed or is still pending gets one anyway, so there is
/// always a small, playable copy of the call. What still waits for the
/// transcript is deleting the .caf — it stays the lossless source a later
/// transcription retry reads from. A gap marker holds everything, as before.
public enum ArchivePlan: Equatable, Sendable {
    /// Leave the tracks exactly as they are.
    case hold
    /// Make the .m4a beside each .caf and keep the .caf.
    case copyKeepOriginal
    /// Make (or reuse) the .m4a and delete the .caf.
    case archive

    public static func decide(hasPCM: Bool, hasTranscript: Bool, hasGaps: Bool) -> ArchivePlan {
        guard hasPCM, !hasGaps else { return .hold }
        return hasTranscript ? .archive : .copyKeepOriginal
    }
}

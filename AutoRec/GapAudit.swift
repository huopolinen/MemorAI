import AVFoundation
import Foundation
import MemorAICore

/// After the call: does either track have a hole in it — a stretch where it
/// was dead while the other side kept talking?
///
/// The live watchdog (`RecordingManager`) tries to keep that from happening;
/// this is what makes sure that when it happens anyway, nothing that could
/// still recover the call is thrown away. A session with a hole gets a
/// `<tag>_gaps.json` beside its files, and that marker is a hold: the
/// uncompressed originals are not archived (`TrackCompressor`), and the disk
/// janitor keeps the screen video (factory `mac-disk-janitor.sh`,
/// class call-videos). On 16.11 the originals were compressed and the video
/// removed before anyone looked — the marker exists so that is no longer the
/// default.
///
/// The verdict is written into meta.json (`gap_audit`) so it is computed once
/// per session, whichever path — clean stop, crash recovery, batch
/// transcription — reaches it first.
enum GapAudit {
    static func markerURL(tag: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(tag)_gaps.json")
    }

    static func hasGaps(tag: String, in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: markerURL(tag: tag, in: directory).path)
    }

    /// Audit the session unless that has already been done. Returns the gaps
    /// (empty when the tracks are whole), or nil when there was nothing to
    /// read. Always scans the tracks as they are on disk now.
    @discardableResult
    static func ensureAudited(tag: String, in directory: URL) -> [TrackGap]? {
        if let done = SessionMeta.read(tag: tag, in: directory)?["gap_audit"] as? String {
            return done == "ok" ? [] : nil
        }
        return audit(tag: tag, in: directory, write: true)
    }

    /// Scan the session's tracks and, with `write`, record the verdict.
    static func audit(tag: String, in directory: URL, write: Bool) -> [TrackGap]? {
        let micURL = SessionMeta.trackURL(tag: tag, role: "mic", in: directory)
        let systemURL = SessionMeta.trackURL(tag: tag, role: "system", in: directory)
        let mic = micURL.flatMap { levels(of: $0) }
        let system = systemURL.flatMap { levels(of: $0) }
        // One track alone cannot be judged by this rule: there is no "other
        // side talking" to hold its silence against.
        guard let mic, let system else {
            if write, micURL != nil || systemURL != nil {
                SessionMeta.update(tag: tag, in: directory, with: ["gap_audit": "single-track"])
            }
            return nil
        }

        let gaps = TrackDropoutDetector.scan(mic: mic, system: system)
        guard write else { return gaps }

        if gaps.isEmpty {
            SessionMeta.update(tag: tag, in: directory, with: ["gap_audit": "ok"])
            return gaps
        }

        let entries: [[String: Any]] = gaps.map { gap in
            [
                "track": gap.role.rawValue,
                "start_s": round(gap.start * 10) / 10,
                "end_s": round(gap.end * 10) / 10,
                "seconds": round(gap.seconds * 10) / 10,
                "start": clock(gap.start),
                "end": clock(gap.end),
                "other_track_speech_s": round(gap.otherVoiced),
            ]
        }
        let marker: [String: Any] = [
            "tag": tag,
            "audited": SessionMeta.iso.string(from: Date()),
            "gaps": entries,
            "note": "Дорожка молчала, пока другая говорила. Исходные .caf и видео звонка сохранены; "
                + "MemorAI их не сжимает, уборщик диска видео не трогает, пока этот файл лежит рядом. "
                + "Разобрались — удалите этот файл, и при следующем запуске MemorAI сожмёт дорожки как обычно.",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: marker, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: markerURL(tag: tag, in: directory), options: .atomic)
        }
        SessionMeta.update(tag: tag, in: directory, with: ["gap_audit": "gaps", "gaps": entries])
        for gap in gaps {
            log("[GapAudit] ⚠️⚠️ \(tag): дорожка «\(gap.role.rawValue)» молчала \(clock(gap.start))–\(clock(gap.end)) "
                + "(\(Int(gap.seconds)) с), пока другая говорила \(Int(gap.otherVoiced)) с. "
                + "Исходники и видео оставляю: \(markerURL(tag: tag, in: directory).lastPathComponent)")
        }
        return gaps
    }

    /// Human summary of the gaps for a notification.
    static func summary(_ gaps: [TrackGap]) -> String {
        gaps.map { gap in
            let who = gap.role == .system ? "собеседника" : "вашего микрофона"
            return "нет звука \(who) \(clock(gap.start))–\(clock(gap.end))"
        }.joined(separator: "; ")
    }

    /// RMS per second of a whole track, across all channels. Reads a second
    /// at a time, so an hour of PCM costs a second of memory.
    static func levels(of url: URL, step: Double = 1) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        let format = file.processingFormat
        let frames = AVAudioFrameCount(max(1, format.sampleRate * step))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        var out: [Float] = []
        out.reserveCapacity(Int(Double(file.length) / format.sampleRate / step) + 1)
        while file.framePosition < file.length {
            do { try file.read(into: buffer, frameCount: frames) } catch { break }
            let n = Int(buffer.frameLength)
            guard n > 0, let data = buffer.floatChannelData else { break }
            let channels = Int(format.channelCount)
            var sum: Float = 0
            for ch in 0..<channels {
                let samples = data[ch]
                for i in 0..<n { sum += samples[i] * samples[i] }
            }
            out.append(sqrtf(sum / Float(n * channels)))
        }
        return out
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// `MemorAI --audit-gaps [--dir <folder>] [--tag call_…] [--since yyyy-MM-dd] [--write]`
    ///
    /// Reports holes in recorded calls without touching anything unless
    /// `--write` is given. Exists for checking the detector against the real
    /// archive, and for re-auditing an old call by hand.
    static func runCLI(_ args: [String]) -> Never {
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let dir = URL(fileURLWithPath: value(after: "--dir") ?? SettingsManager.shared.outputPath)
        let write = args.contains("--write")
        let since = value(after: "--since")
        var tags: [String]
        if let tag = value(after: "--tag") {
            tags = [tag]
        } else {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            tags = Set(names.compactMap { name -> String? in
                guard name.hasPrefix("call_"), name.hasSuffix("_mic.m4a") || name.hasSuffix("_mic.caf")
                else { return nil }
                return String(name.dropLast("_mic.m4a".count))
            }).sorted()
            if let since { tags = tags.filter { $0 >= "call_\(since)" } }
        }
        var flagged = 0
        for tag in tags {
            guard let gaps = audit(tag: tag, in: dir, write: write) else {
                print("\(tag)\tнет пары дорожек")
                continue
            }
            if gaps.isEmpty {
                print("\(tag)\tok")
            } else {
                flagged += 1
                print("\(tag)\tДЫРА\t\(summary(gaps))")
            }
        }
        print("всего \(tags.count), с дырами \(flagged)")
        exit(0)
    }
}

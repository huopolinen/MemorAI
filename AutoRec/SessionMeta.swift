import Darwin
import Foundation

/// `call_<ts>.meta.json` — the session's account of itself, and the only thing
/// on disk that can say "a recording is happening right now".
///
/// Audio files alone can't answer that: a .caf that is still being appended to
/// looks exactly like one whose owner died ten minutes ago. So each session
/// drops a marker beside its tracks naming the process that owns it, and the
/// marker is what the next launch reads to decide whether to adopt the session
/// or keep its hands off.
///
/// The marker lives beside the tracks rather than in a per-session folder
/// because the recordings folder is flat (call_<ts>_mic.caf, call_<ts>_system.caf,
/// call_<ts>_screen.mp4) and everything downstream — the CLI, BatchTranscriber,
/// the user's own Finder window — assumes that layout.
///
/// подход из amanu (MIT, gsamat/amanu): SessionState.swift + RecordingSession.swift
enum SessionMeta {
    /// Where a session is in its life. Only `recording` is a claim about a live
    /// process; the rest describe a session that has already finished.
    enum Status: String {
        /// Tracks are being written right now by the process named in `pid`.
        case recording
        /// Stopped cleanly. Post-processing (mux / transcription) may still run.
        case stopped
        /// The owning process died mid-call and we adopted what it left behind.
        case interrupted
        /// Transcript exists and the PCM has been archived to AAC.
        case done
    }

    /// Current schema. Bumped only if a field's meaning changes, so an older
    /// app reading a newer file can tell it doesn't understand it.
    static let version = 1

    static func url(tag: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(tag).meta.json")
    }

    // MARK: - Reading

    static func read(tag: String, in directory: URL) -> [String: Any]? {
        read(at: url(tag: tag, in: directory))
    }

    static func read(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    /// Every session marker in `directory`, oldest first (the tag sorts
    /// chronologically because it is a zero-padded timestamp).
    static func all(in directory: URL) -> [(tag: String, url: URL, json: [String: Any])] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasPrefix("call_") && $0.hasSuffix(".meta.json") }
            .sorted()
            .compactMap { name in
                let fileURL = directory.appendingPathComponent(name)
                guard let json = read(at: fileURL) else { return nil }
                let tag = String(name.dropLast(".meta.json".count))
                return (tag: tag, url: fileURL, json: json)
            }
    }

    // MARK: - Writing

    /// Claim a session: write the marker that makes a crash recoverable.
    /// Called before the recorders start, so even a crash during startup leaves
    /// something that points at the (possibly empty) track files.
    static func begin(
        tag: String,
        in directory: URL,
        trigger: String,
        files: [String: String]
    ) {
        let pid = ProcessInfo.processInfo.processIdentifier
        var json: [String: Any] = [
            "version": version,
            "tag": tag,
            "status": Status.recording.rawValue,
            "trigger": trigger,
            "started": iso.string(from: Date()),
            "pid": Int(pid),
            "files": files,
        ]
        // The pid alone is not proof of ownership: pids get recycled, and a
        // stranger wearing our old number would make a dead session look alive
        // forever. The owner's start time pins it down — see `ownerIsAlive`.
        if let started = processStartTime(of: pid) {
            json["pid_started"] = started
        }
        write(json, to: url(tag: tag, in: directory))
    }

    /// Merge fields into an existing marker, leaving everything else alone.
    /// A `nil` value removes its key — that is how a claim that no longer holds
    /// (the pid of a finished session) is cleared rather than left to mislead.
    static func update(tag: String, in directory: URL, with fields: [String: Any?]) {
        update(at: url(tag: tag, in: directory), with: fields)
    }

    static func update(at url: URL, with fields: [String: Any?]) {
        guard var json = read(at: url) else { return }
        for (key, value) in fields {
            if let value { json[key] = value } else { json.removeValue(forKey: key) }
        }
        write(json, to: url)
    }

    private static func write(_ json: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: json, options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Ownership

    /// Is the process that claimed this session still running?
    ///
    /// `kill(pid, 0)` alone answers "is *something* running under that number",
    /// which is not the same question — macOS recycles pids, and a wrong "yes"
    /// here means a crashed call is never recovered, on this launch or any
    /// later one. So when the marker recorded the owner's start time we compare
    /// it too: a live pid with a different start time is a stranger, and the
    /// real owner is gone.
    ///
    /// When the start time is missing (marker from an older build) or
    /// unreadable, we answer "alive" and leave the session alone. Deferring
    /// recovery costs a launch; adopting a session someone is still writing to
    /// costs the call.
    static func ownerIsAlive(_ json: [String: Any]) -> Bool {
        guard let pid = (json["pid"] as? NSNumber)?.int32Value else { return false }
        guard kill(pid, 0) == 0 else { return false }
        guard let claimed = json["pid_started"] as? Double else { return true }
        guard let actual = processStartTime(of: pid) else { return true }
        // Sub-second equality would be brittle across a JSON round-trip; a
        // recycled pid is always seconds newer, never microseconds.
        return abs(actual - claimed) < 1.0
    }

    /// Unix time at which `pid` started, or nil if there is no such process.
    private static func processStartTime(of pid: Int32) -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let rc = mib.withUnsafeMutableBufferPointer { buffer in
            sysctl(buffer.baseAddress, UInt32(buffer.count), &info, &size, nil, 0)
        }
        guard rc == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        return Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
    }

    // MARK: - Track files

    /// The track file to actually use for `role` ("mic" / "system"), whatever
    /// state the session is in.
    ///
    /// A session can legitimately have a .caf (recorded, not yet archived), an
    /// .m4a (archived), or — for the moment between encoding and deleting —
    /// both. The .caf wins in that overlap: it is the complete original, while
    /// the .m4a beside it may be a half-written encode from a run that died.
    static func trackURL(tag: String, role: String, in directory: URL) -> URL? {
        let candidates = [
            directory.appendingPathComponent("\(tag)_\(role).\(AudioFormats.trackExtension)"),
            directory.appendingPathComponent("\(tag)_\(role).\(AudioFormats.archiveExtension)"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Where this session's transcript lives (whether or not it exists yet).
    static func transcriptURL(tag: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(tag)_transcript.txt")
    }

    static func hasTranscript(tag: String, in directory: URL) -> Bool {
        let url = transcriptURL(tag: tag, in: directory)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64
        else { return false }
        return size > 0
    }

    static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        return formatter
    }()
}

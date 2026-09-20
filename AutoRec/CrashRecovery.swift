import Foundation

/// Picks up recordings that a crash, a kill or a flat battery left behind.
///
/// The tracks survive on their own — that is what PCM in a CAF buys us (see
/// `AudioFormats`). What a crash destroys is everything that *points* at them:
/// nothing stops, nothing transcribes, and the session sits in the folder as
/// two orphaned files nobody will ever look at. This pass puts the pointers
/// back, so an interrupted call comes out the other end looking like one that
/// ended politely.
///
/// подход из amanu (MIT, gsamat/amanu): RecordingSession.swift (recoverInterrupted)
enum CrashRecovery {
    /// How many times a session may be sent through the engine before we stop
    /// retrying it on every launch. A recording of a genuinely silent call
    /// never produces a transcript, and retrying it forever would mean its PCM
    /// is never archived and the log fills with the same failure daily.
    private static let maxTranscriptionAttempts = 3

    /// Everything the recordings folder is owed on startup: sessions a crash
    /// interrupted, plus sessions that ended cleanly but never finished being
    /// processed (the app was quit or killed during transcription).
    static func recoverPending(in directory: URL, queueTranscription: Bool) {
        let adopted = adoptInterrupted(in: directory, queueTranscription: queueTranscription)
        if queueTranscription {
            // Transcription is asynchronous, so a session just queued by the
            // first pass still has no transcript on disk — without this the
            // second pass would queue it all over again.
            resumeUnfinished(in: directory, skipping: Set(adopted))
        }
    }

    /// Adopt every session in `directory` whose marker still claims to be
    /// recording but whose owner is gone. Returns the adopted session tags.
    ///
    /// `queueTranscription` is false for callers that transcribe on their own
    /// afterwards (the batch CLI), so a session is never sent through the
    /// engine twice.
    @discardableResult
    static func adoptInterrupted(in directory: URL, queueTranscription: Bool) -> [String] {
        var adopted: [String] = []

        for session in SessionMeta.all(in: directory) {
            guard (session.json["status"] as? String) == SessionMeta.Status.recording.rawValue
            else { continue }

            // A live owner means MemorAI is recording into these files right
            // now — a second instance, or (before this build) ourselves. Leave
            // it strictly alone. `ownerIsAlive` also rules out a stranger who
            // inherited the pid, so "alive" here really does mean alive.
            if SessionMeta.ownerIsAlive(session.json) {
                log("[CrashRecovery] \(session.tag): запись ведёт живой процесс — не трогаю")
                continue
            }

            let files = (session.json["files"] as? [String: String]) ?? [:]
            var repairedTracks: [String] = []
            var lastWrite: Date?
            var audioBytes: Int64 = 0

            for role in ["mic", "system"] {
                guard let name = files[role] else { continue }
                let url = directory.appendingPathComponent(name)
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                else { continue }
                let bytes = (attrs[.size] as? Int64) ?? 0
                audioBytes += bytes
                if let modified = attrs[.modificationDate] as? Date {
                    lastWrite = max(lastWrite ?? modified, modified)
                }
                guard bytes > 0, url.pathExtension == AudioFormats.trackExtension else { continue }

                switch AudioFormats.repairInterruptedCAF(at: url) {
                case .repaired(let frames, let dropped):
                    repairedTracks.append(role)
                    log("[CrashRecovery] \(name): заголовок починен, \(frames) кадров"
                        + (dropped > 0 ? ", отброшен обрывок \(dropped) Б" : ""))
                case .alreadyClosed:
                    break
                case .unrecognised(let why):
                    log("[CrashRecovery] ⚠️ \(name): починить не смог (\(why)) — оставляю как есть")
                }
            }

            // The last byte written to either track is when the recording
            // really ended; the process died without telling anyone.
            let ended = lastWrite ?? Date()
            let started = (session.json["started"] as? String)
                .flatMap { SessionMeta.iso.date(from: $0) } ?? ended
            let minutes = Int(ended.timeIntervalSince(started) / 60)

            SessionMeta.update(at: session.url, with: [
                "status": SessionMeta.Status.interrupted.rawValue,
                "ended": SessionMeta.iso.string(from: ended),
                "duration_seconds": Int(ended.timeIntervalSince(started)),
                "recovered": true,
                "stop_reason": "recovered-after-crash",
                // The claim is void: whoever held this pid is gone, and leaving
                // the number behind would only mislead the next launch.
                "pid": nil,
                "pid_started": nil,
            ])

            guard audioBytes > 0 else {
                log("[CrashRecovery] \(session.tag): запись прервалась, но звука на диске нет — пропускаю")
                continue
            }

            adopted.append(session.tag)
            log("[CrashRecovery] 🛟 Подхвачена прерванная запись \(session.tag)"
                + " (\(minutes) мин, \(mb(audioBytes)) звука"
                + (repairedTracks.isEmpty ? "" : ", починено: \(repairedTracks.joined(separator: "+"))")
                + ")")

            // Screen video is the one thing PCM can't save: AVAssetWriter's
            // .mp4 has no moov atom until finishWriting, so a killed process
            // leaves a file no player will open. Say so plainly instead of
            // letting the user find out later.
            if let screen = files["screen"] {
                let url = directory.appendingPathComponent(screen)
                if FileManager.default.fileExists(atPath: url.path) {
                    log("[CrashRecovery] ⚠️ \(screen): видео экрана не было закрыто при падении и, скорее всего, не откроется. Звук цел.")
                }
            }

            guard queueTranscription else { continue }
            transcribe(tag: session.tag, in: directory)
        }

        if adopted.isEmpty {
            return adopted
        }
        log("[CrashRecovery] Всего подхвачено прерванных записей: \(adopted.count)")
        return adopted
    }

    /// Sessions that stopped cleanly but never made it through post-processing.
    ///
    /// Quitting the app (or `memorai stop`) during transcription is a normal
    /// thing to do and is deliberately not held up — the audio is already safe
    /// on disk. What makes that safe rather than merely survivable is this
    /// pass: on the next launch the session is picked up exactly where it was
    /// left, instead of sitting in the folder as a .caf nobody will transcribe.
    private static func resumeUnfinished(in directory: URL, skipping: Set<String>) {
        let pending: Set<String> = [
            SessionMeta.Status.stopped.rawValue,
            SessionMeta.Status.interrupted.rawValue,
        ]
        for session in SessionMeta.all(in: directory) {
            guard !skipping.contains(session.tag) else { continue }
            guard let status = session.json["status"] as? String, pending.contains(status)
            else { continue }

            if SessionMeta.hasTranscript(tag: session.tag, in: directory) {
                // Transcribed but never archived — killed between the two.
                TrackCompressor.settleAfterTranscript(tag: session.tag, in: directory)
                continue
            }
            // Nothing to transcribe if the audio is gone (archived and the
            // transcript deleted by hand, or the user cleaned up).
            guard SessionMeta.trackURL(tag: session.tag, role: "mic", in: directory) != nil
                || SessionMeta.trackURL(tag: session.tag, role: "system", in: directory) != nil
            else { continue }

            log("[CrashRecovery] \(session.tag): осталась без расшифровки — доделываю")
            transcribe(tag: session.tag, in: directory)
        }
    }

    /// Send a session through the normal transcription path, then archive its
    /// audio — exactly what a clean stop would have done.
    private static func transcribe(tag: String, in directory: URL) {
        guard SettingsManager.shared.autoTranscribe else {
            log("[CrashRecovery] \(tag): автотранскрипция выключена — запись лежит несжатой и ждёт")
            return
        }
        guard !SessionMeta.hasTranscript(tag: tag, in: directory) else {
            TrackCompressor.settleAfterTranscript(tag: tag, in: directory)
            return
        }
        // An unconfigured engine is not a failed attempt: it will work as soon
        // as the user sets one up, so it must not burn through the retry budget.
        guard Transcriber.shared.isAvailable else {
            log("[CrashRecovery] \(tag): движок расшифровки недоступен — запись сохранена, расшифруйте позже")
            return
        }
        let attempts = (SessionMeta.read(tag: tag, in: directory)?["transcription_attempts"] as? Int) ?? 0
        guard attempts < maxTranscriptionAttempts else {
            log("[CrashRecovery] \(tag): расшифровка не удалась \(attempts) раз(а) — больше не пробую. Запись цела, запустите `memorai` вручную при желании.")
            return
        }
        SessionMeta.update(tag: tag, in: directory, with: ["transcription_attempts": attempts + 1])

        let mic = SessionMeta.trackURL(tag: tag, role: "mic", in: directory)
        let system = SessionMeta.trackURL(tag: tag, role: "system", in: directory)
        log("[CrashRecovery] \(tag): ставлю в очередь на расшифровку")
        Transcriber.shared.transcribeSession(micURL: mic, systemURL: system) {
            if SessionMeta.hasTranscript(tag: tag, in: directory) {
                SessionMeta.update(tag: tag, in: directory, with: ["transcription_failed": nil])
                TrackCompressor.settleAfterTranscript(tag: tag, in: directory)
            } else {
                // No transcript means the audio stays exactly where it is.
                SessionMeta.update(tag: tag, in: directory, with: ["transcription_failed": true])
                log("[CrashRecovery] \(tag): расшифровка ничего не дала — звук оставлен несжатым")
            }
        }
    }

    private static func mb(_ bytes: Int64) -> String {
        String(format: "%.0f МБ", Double(bytes) / 1_048_576)
    }
}

import Foundation

/// Orchestrates system audio, mic, and screen recording.
class RecordingManager {
    private(set) var state: RecordingState = .idle
    var onStateChange: ((RecordingState) -> Void)?
    var onRecordingActiveChanged: ((Bool) -> Void)?
    /// Fired when system audio silence state changes during recording.
    var onSilenceChanged: ((Bool) -> Void)?
    /// Fired when mic silence state changes during recording.
    var onMicSilenceChanged: ((Bool) -> Void)?
    /// Fired once if the session produced no system audio within the warmup window
    /// (mic-only voice memo or headphones-only call).
    var onSystemAudioUnavailable: (() -> Void)?
    /// Fired when transcription completes after a recording
    var onTranscriptionDone: (() -> Void)?

    private var systemAudioRecorder: SystemAudioRecorder?
    /// Core Audio tap, when that path is selected. Boxed as `Any?` because the
    /// tap API needs macOS 14.4 while this class is compiled for 14.0 — every
    /// use goes through the availability-checked accessor below.
    private var tapRecorderBox: Any?
    private var micRecorder: MicRecorder?
    private let settings = SettingsManager.shared

    // Track current session file URLs for transcription
    private var currentMicURL: URL?
    private var currentSystemURL: URL?
    private var currentScreenURL: URL?
    /// "call_<timestamp>" — names every file of the session and its meta.json.
    private var currentTag: String?
    private var currentDir: URL?
    /// Real time the session spent paused, and when the open pause began.
    /// A pause removes wall-clock time from both tracks by design, so the
    /// end-of-session length check (`TrackSkew`) has to subtract it or it
    /// would accuse every paused call of being damaged.
    private var pausedSeconds: TimeInterval = 0
    private var pausedSince: Date?

    @available(macOS 14.4, *)
    private var tapRecorder: CoreAudioTapRecorder? {
        get { tapRecorderBox as? CoreAudioTapRecorder }
        set { tapRecorderBox = newValue }
    }

    private(set) var isTranscribing = false

    func startRecording(source: String = "manual") {
        guard state == .idle else {
            log("[RecordingManager] Cannot start — state is \(state)")
            return
        }
        log("[RecordingManager] Recording started (source: \(source))")
        setState(.starting)
        onRecordingActiveChanged?(true)

        settings.ensureOutputDirectory()

        let timestamp = Self.timestamp()
        let baseDir = URL(fileURLWithPath: settings.outputPath)
        let tag = "call_\(timestamp)"

        // Tracks are uncompressed until the transcript exists (~1 GB/hour for
        // the pair), so a tight disk is worth saying out loud before the call
        // rather than discovering it halfway through.
        AudioFormats.warnIfLowDiskSpace(at: baseDir)

        let sysURL = baseDir.appendingPathComponent("\(tag)_system.\(AudioFormats.trackExtension)")
        let micURL = baseDir.appendingPathComponent("\(tag)_mic.\(AudioFormats.trackExtension)")
        let vidURL: URL? = settings.recordScreen
            ? baseDir.appendingPathComponent("\(tag)_screen.mp4")
            : nil

        self.currentTag = tag
        self.currentDir = baseDir
        self.pausedSeconds = 0
        self.pausedSince = nil
        self.currentMicURL = micURL
        self.currentSystemURL = sysURL
        self.currentScreenURL = vidURL

        // Claim the session before a single byte is written. If the app dies
        // between here and the first buffer, the next launch still finds a
        // marker naming these files and knows nobody owns them any more.
        var files = ["mic": micURL.lastPathComponent, "system": sysURL.lastPathComponent]
        if let vidURL { files["screen"] = vidURL.lastPathComponent }
        SessionMeta.begin(tag: tag, in: baseDir, trigger: source, files: files)

        // Two ways to capture the far end (SettingsManager.systemAudioSource):
        //
        //  • .screenCapture — one SCStream writes both the system track and
        //    the video, as it always has.
        //  • .coreAudioTap  — a Core Audio tap writes the system track, and
        //    SCStream, if screen recording is on at all, is created with no
        //    audio URL (and therefore `capturesAudio = false`).
        //
        // So exactly one writer ever opens `_system.caf`, and the far end is
        // never captured twice. The muxer downstream doesn't care which path
        // produced the track — it reads the same file name either way.
        let wantsTap = settings.systemAudioSource == .coreAudioTap

        Task {
            do {
                var tapStarted = false
                if wantsTap {
                    if #available(macOS 14.4, *) {
                        let tap = CoreAudioTapRecorder(
                            audioURL: sysURL, callAppOnly: settings.tapCallAppOnly)
                        tap.onSilenceChanged = { [weak self] silent in
                            self?.onSilenceChanged?(silent)
                        }
                        tap.onSystemAudioUnavailable = { [weak self] in
                            self?.onSystemAudioUnavailable?()
                        }
                        tap.onStreamError = { [weak self] error in
                            guard let self = self, self.state == .recording || self.state == .starting else { return }
                            log("[RecordingManager] Core Audio tap error — stopping session: \(error.localizedDescription)")
                            self.stopRecording(source: "stream-error")
                        }
                        do {
                            try tap.start()
                            self.tapRecorder = tap
                            tapStarted = true
                        } catch {
                            // A tap that won't start must not cost the call:
                            // fall back to the path that has always worked.
                            log("[RecordingManager] ⚠️ Core Audio tap не стартовал (\(error.localizedDescription)) — пишу системный звук через запись экрана")
                        }
                    } else {
                        log("[RecordingManager] ⚠️ Core Audio tap требует macOS 14.4 — пишу системный звук через запись экрана")
                    }
                }

                // SCStream is still needed for the video, and for the system
                // track whenever the tap is not the one writing it.
                if !tapStarted || vidURL != nil {
                    let sysRec = SystemAudioRecorder(
                        audioURL: tapStarted ? nil : sysURL, videoURL: vidURL)
                    if tapStarted {
                        // Video-only stream: its death must not take the
                        // (separate, still healthy) audio capture with it. The
                        // call keeps running as one session; only the screen
                        // half is shut down — right here rather than at the end
                        // of the call, so the frames taken before the crash are
                        // closed into a playable mp4 within seconds instead of
                        // sitting unfinalized for the next hour.
                        sysRec.onStreamError = { [weak sysRec] error in
                            log("[RecordingManager] ⚠️ Видео экрана остановилось: \(error.localizedDescription) — звук продолжает писаться, закрываю видеофайл")
                            guard let sysRec else { return }
                            Task { await sysRec.stop() }
                        }
                    } else {
                        // Wire up silence / availability / error signals
                        sysRec.onSilenceChanged = { [weak self] silent in
                            self?.onSilenceChanged?(silent)
                        }
                        sysRec.onSystemAudioUnavailable = { [weak self] in
                            self?.onSystemAudioUnavailable?()
                        }
                        sysRec.onStreamError = { [weak self] error in
                            guard let self = self, self.state == .recording || self.state == .starting else { return }
                            log("[RecordingManager] SCStream error — stopping session: \(error.localizedDescription)")
                            self.stopRecording(source: "stream-error")
                        }
                    }
                    self.systemAudioRecorder = sysRec
                    do {
                        try await sysRec.start()
                    } catch {
                        // Only reachable with the tap already running, because
                        // otherwise this throw is the session failing to start.
                        guard tapStarted else { throw error }
                        log("[RecordingManager] ⚠️ Видео экрана не стартовало — продолжаю без него: \(error.localizedDescription)")
                        self.systemAudioRecorder = nil
                        self.currentScreenURL = nil
                        var remaining = files
                        remaining.removeValue(forKey: "screen")
                        SessionMeta.update(tag: tag, in: baseDir, with: ["files": remaining])
                    }
                }

                let micRec = MicRecorder(outputURL: micURL)
                micRec.onSilenceChanged = { [weak self] silent in
                    self?.onMicSilenceChanged?(silent)
                }
                self.micRecorder = micRec
                // A mic failure must not tear down the (already running) system-audio
                // recording — degrade to a system-only session instead.
                do {
                    try micRec.start()
                } catch {
                    log("[RecordingManager] ⚠️ Mic failed to start — continuing system-only: \(error.localizedDescription)")
                    self.micRecorder = nil
                    self.currentMicURL = nil
                    // The marker must not promise a mic track nothing will write.
                    var remaining = files
                    remaining.removeValue(forKey: "mic")
                    SessionMeta.update(tag: tag, in: baseDir, with: ["files": remaining])
                }

                setState(.recording)
                log("[RecordingManager] All recorders running")
            } catch {
                log("[RecordingManager] ❌ Failed to start: \(error)")
                await systemAudioRecorder?.stop()
                if #available(macOS 14.4, *) { tapRecorder?.stop(); tapRecorder = nil }
                micRecorder?.stop()
                systemAudioRecorder = nil
                micRecorder = nil
                // Nothing was recorded, so the marker would only be a claim on
                // files that don't exist — and would be "recovered" on every
                // future launch.
                try? FileManager.default.removeItem(at: SessionMeta.url(tag: tag, in: baseDir))
                currentTag = nil
                currentDir = nil
                setState(.idle)
                onRecordingActiveChanged?(false)
            }
        }
    }

    func pauseRecording() {
        guard state == .recording else { return }
        systemAudioRecorder?.isPaused = true
        if #available(macOS 14.4, *) { tapRecorder?.isPaused = true }
        micRecorder?.isPaused = true
        pausedSince = Date()
        setState(.paused)
        log("[RecordingManager] Paused")
    }

    func resumeRecording() {
        guard state == .paused else { return }
        systemAudioRecorder?.isPaused = false
        if #available(macOS 14.4, *) { tapRecorder?.isPaused = false }
        micRecorder?.isPaused = false
        closeOpenPause()
        setState(.recording)
        log("[RecordingManager] Resumed")
    }

    /// True while a session owns the recorders — anything other than fully
    /// idle. Quitting in this state would leave tracks unclosed.
    var isRecordingInProgress: Bool { state != .idle }

    func stopRecording(source: String = "manual") {
        guard state == .recording || state == .starting || state == .paused else { return }
        log("[RecordingManager] Recording stopped (source: \(source))")
        setState(.stopping)

        Task {
            let session = await finalizeTracks(source: source)
            postProcess(session)
        }
    }

    /// Stop recording for an app that is on its way out.
    ///
    /// Only the part that cannot be redone later is performed here: closing the
    /// track files and clearing the session's claim on this process. Muxing and
    /// transcription are deliberately skipped — they take minutes, and the next
    /// launch picks the session up from its marker anyway (`CrashRecovery`).
    /// The completion fires once the audio on disk is complete and readable.
    func finishForTermination(completion: @escaping () -> Void) {
        guard isRecordingInProgress else {
            completion()
            return
        }
        log("[RecordingManager] Завершение приложения во время записи — дописываю дорожки")
        setState(.stopping)
        Task {
            let session = await finalizeTracks(source: "app-quit")
            if let tag = session.tag {
                log("[RecordingManager] \(tag): дорожки дописаны, расшифровка продолжится при следующем запуске")
            }
            DispatchQueue.main.async { completion() }
        }
    }

    /// What a stopped session consists of, once its files are closed.
    private struct FinishedSession {
        let tag: String?
        let dir: URL?
        let mic: URL?
        let system: URL?
        let screen: URL?
    }

    /// Shut the recorders down and close the tracks, then release the session's
    /// claim on this process. After this returns, the audio on disk is complete
    /// and needs no header repair — which is exactly the difference between
    /// quitting and being killed.
    private func finalizeTracks(source: String) async -> FinishedSession {
        let session = FinishedSession(
            tag: currentTag, dir: currentDir,
            mic: currentMicURL, system: currentSystemURL, screen: currentScreenURL)
        currentTag = nil
        currentDir = nil

        micRecorder?.stop()
        await systemAudioRecorder?.stop()
        // Stopping the tap destroys its private aggregate device: leaving one
        // behind would sit in the user's audio stack until the next reboot.
        if #available(macOS 14.4, *) { tapRecorder?.stop(); tapRecorder = nil }
        micRecorder = nil
        systemAudioRecorder = nil
        setState(.idle)
        onRecordingActiveChanged?(false)
        log("[RecordingManager] All recorders stopped")

        if let tag = session.tag, let dir = session.dir {
            // The tracks are closed and nobody owns them any more. Dropping the
            // process claim is what stops the next launch from treating a
            // finished session as one that was interrupted mid-call; the
            // `stopped` status is what tells it there may still be work to do.
            var fields: [String: Any?] = [
                "status": SessionMeta.Status.stopped.rawValue,
                "ended": SessionMeta.iso.string(from: Date()),
                "stop_reason": source,
                "pid": nil,
                "pid_started": nil,
            ]
            // Now that the files are closed and their lengths are final, ask
            // whether they are as long as the call was.
            for (key, value) in trackAudit(tag: tag, in: dir, session: session) {
                fields[key] = value
            }
            SessionMeta.update(tag: tag, in: dir, with: fields)
        }
        return session
    }

    /// Length of every track against the length of the session — see
    /// `TrackSkew` for why this is worth doing at all.
    ///
    /// The session's start comes from its own marker rather than a field kept
    /// here: the marker is what survives a crash, so recovery and a clean stop
    /// answer this question from the same number.
    private func trackAudit(
        tag: String, in dir: URL, session: FinishedSession
    ) -> [String: Any] {
        closeOpenPause()
        let paused = pausedSeconds
        pausedSeconds = 0
        guard let started = (SessionMeta.read(tag: tag, in: dir)?["started"] as? String)
            .flatMap({ SessionMeta.iso.date(from: $0) })
        else { return [:] }

        var tracks: [String: URL] = [:]
        if let mic = session.mic { tracks["mic"] = mic }
        if let system = session.system { tracks["system"] = system }
        return TrackSkew.audit(
            tag: tag,
            sessionSeconds: Date().timeIntervalSince(started) - paused,
            tracks: tracks)
    }

    /// Add an in-progress pause to the running total. Idempotent, because a
    /// session can be stopped straight out of the paused state.
    private func closeOpenPause() {
        guard let since = pausedSince else { return }
        pausedSeconds += Date().timeIntervalSince(since)
        pausedSince = nil
    }

    /// Mux, transcribe, and — only if a transcript came out of it — archive.
    private func postProcess(_ session: FinishedSession) {
        // Both steps read the PCM tracks, and archiving deletes them, so it has
        // to wait for both — otherwise the compressor pulls a .caf out from
        // under ffmpeg mid-mux.
        let postProcessing = DispatchGroup()

        // Mux mic + system audio into screen.mp4 in-place so the video file is
        // self-contained for downstream playback. Runs in parallel with transcription.
        if let screenURL = session.screen {
            postProcessing.enter()
            AudioMuxer.shared.muxScreenWithAudio(
                screenURL: screenURL, micURL: session.mic, systemURL: session.system
            ) { postProcessing.leave() }
        }

        // Auto-transcribe if enabled and the engine is available
        if settings.autoTranscribe {
            if Transcriber.shared.isAvailable {
                isTranscribing = true
                onStateChange?(state) // trigger UI update
                log("[RecordingManager] Starting transcription…")
                postProcessing.enter()
                Transcriber.shared.transcribeSession(
                    micURL: session.mic, systemURL: session.system
                ) { [weak self] in
                    self?.isTranscribing = false
                    self?.onTranscriptionDone?()
                    self?.onStateChange?(self?.state ?? .idle)
                    log("[RecordingManager] Transcription complete")
                    postProcessing.leave()
                }
            } else {
                log("[RecordingManager] Auto-transcribe on but whisper/model missing — skipping")
            }
        }

        if let tag = session.tag, let dir = session.dir {
            postProcessing.notify(queue: DispatchQueue.global(qos: .utility)) {
                TrackCompressor.settleAfterTranscript(tag: tag, in: dir)
            }
        }
    }

    private func setState(_ newState: RecordingState) {
        state = newState
        onStateChange?(newState)
    }

    private static func timestamp() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return fmt.string(from: Date())
    }
}

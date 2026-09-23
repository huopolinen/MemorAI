import Foundation
import ScreenCaptureKit

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

    // --- Keeping the call whole when macOS stops the capture stream ---
    // macOS stops a running SCStream on its own (-3821 "Stream was stopped by
    // the system") — on this machine every time CacheDelete asks replayd to
    // free space on a nearly full disk. Until 1.6.1 that ended the session,
    // and the call detector, seeing the call still going, started a new one
    // seconds later: one call came out as five sets of files. Now the stream
    // is started again into the same files and the session only ends when
    // the call does.
    /// The running restart loop, if the stream is currently down.
    private var streamRecovery: Task<Void, Never>?
    /// Fast attempts, in seconds after the stream died. After the last one the
    /// call goes on without the stream (mic, and the tap if it is on), and —
    /// when the stream carries the far end — keeps trying every
    /// `streamSlowRetry` seconds for as long as the call lasts.
    private static let streamRetryDelays: [Double] = [0.5, 1, 2, 4, 8]
    private static let streamSlowRetry: Double = 30
    /// A restarted stream that dies again sooner than this continues the
    /// previous streak of attempts instead of starting a new one — otherwise
    /// a stream that dies right after every start would be restarted every
    /// half second forever.
    private static let streamHealthySeconds: Double = 30
    private var lastStreamRestart: Date?
    private var streamAttempt = 0
    private var streamRestarts = 0

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
        self.streamRecovery?.cancel()
        self.streamRecovery = nil
        self.lastStreamRestart = nil
        self.streamAttempt = 0
        self.streamRestarts = 0
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
                        sysRec.onStreamError = { [weak self, weak sysRec] error in
                            guard let self, let sysRec else { return }
                            self.handleStreamStopped(sysRec, error: error, carriesSystemAudio: false)
                        }
                    } else {
                        // Wire up silence / availability / error signals
                        sysRec.onSilenceChanged = { [weak self] silent in
                            self?.onSilenceChanged?(silent)
                        }
                        sysRec.onSystemAudioUnavailable = { [weak self] in
                            self?.onSystemAudioUnavailable?()
                        }
                        sysRec.onStreamError = { [weak self, weak sysRec] error in
                            guard let self, let sysRec else { return }
                            self.handleStreamStopped(sysRec, error: error, carriesSystemAudio: true)
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
        streamRecovery?.cancel()
        streamRecovery = nil

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
            if streamRestarts > 0 { fields["stream_restarts"] = streamRestarts }
            // Now that the files are closed and their lengths are final, ask
            // whether they are as long as the call was.
            for (key, value) in trackAudit(tag: tag, in: dir, session: session) {
                fields[key] = value
            }
            SessionMeta.update(tag: tag, in: dir, with: fields)
        }
        return session
    }

    /// The capture stream died on its own. Keep the call going and bring the
    /// stream back into the same files; see `streamRecovery`.
    ///
    /// Only an explicit "stop sharing" from the user (-3817, the menu-bar
    /// capture indicator) is taken at its word, as it always was. Everything
    /// else — -3821 above all — is treated as passing: whether it really is
    /// shows in whether the restart works.
    private func handleStreamStopped(
        _ sysRec: SystemAudioRecorder, error: Error, carriesSystemAudio: Bool
    ) {
        guard sysRec === systemAudioRecorder,
              state == .recording || state == .starting || state == .paused
        else { return }

        let ns = error as NSError
        let userStopped = ns.domain == SCStreamErrorDomain
            && ns.code == SCStreamError.Code.userStopped.rawValue
        if userStopped {
            if carriesSystemAudio {
                log("[RecordingManager] Запись экрана остановлена пользователем — завершаю сессию")
                stopRecording(source: "stream-error")
            } else {
                log("[RecordingManager] Запись экрана остановлена пользователем — звук продолжает писаться, закрываю видеофайл")
                Task { await sysRec.stop() }
            }
            return
        }

        guard streamRecovery == nil else { return }
        // A stream that barely lived continues the previous streak.
        if let last = lastStreamRestart, Date().timeIntervalSince(last) < Self.streamHealthySeconds {
            // keep streamAttempt
        } else {
            streamAttempt = 0
        }
        let freeGB = currentDir.flatMap { AudioFormats.freeBytes(at: $0) }
            .map { String(format: ", на диске свободно %.1f ГБ", Double($0) / 1_073_741_824) } ?? ""
        log("[RecordingManager] ⚠️ SCStream остановлен (\(ns.domain) \(ns.code): \(ns.localizedDescription)\(freeGB)) — звонок продолжается, перезапускаю поток")

        streamRecovery = Task { @MainActor [weak self, weak sysRec] in
            while let self, let sysRec, !Task.isCancelled,
                  sysRec === self.systemAudioRecorder, self.state != .idle, self.state != .stopping {
                let delays = Self.streamRetryDelays
                let delay: Double
                if self.streamAttempt < delays.count {
                    delay = delays[self.streamAttempt]
                } else {
                    if self.streamAttempt == delays.count {
                        if !carriesSystemAudio {
                            log("[RecordingManager] ⚠️ SCStream не поднялся за \(delays.count) попыток — звук продолжает писаться (tap + микрофон), закрываю видеофайл")
                            self.streamRecovery = nil
                            await sysRec.stop()
                            return
                        }
                        log("[RecordingManager] ⚠️ SCStream не поднялся за \(delays.count) попыток — продолжаю писать микрофон, системный звук пока тишиной; пробую снова каждые \(Int(Self.streamSlowRetry)) с")
                    }
                    delay = Self.streamSlowRetry
                }
                self.streamAttempt += 1
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return  // cancelled: the session ended
                }
                guard !Task.isCancelled, sysRec === self.systemAudioRecorder,
                      self.state != .idle, self.state != .stopping else { return }
                do {
                    try await sysRec.restartStream()
                    guard sysRec.isStreamAlive else { return }
                    self.streamRestarts += 1
                    self.lastStreamRestart = Date()
                    log("[RecordingManager] ✅ SCStream перезапущен (попытка \(self.streamAttempt), перезапусков за звонок: \(self.streamRestarts)) — сессия \(self.currentTag ?? "?") продолжается")
                    self.streamRecovery = nil
                    return
                } catch {
                    log("[RecordingManager] SCStream не поднялся (попытка \(self.streamAttempt)): \(error.localizedDescription)")
                }
            }
            self?.streamRecovery = nil
        }
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

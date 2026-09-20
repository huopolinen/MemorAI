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
    private var micRecorder: MicRecorder?
    private let settings = SettingsManager.shared

    // Track current session file URLs for transcription
    private var currentMicURL: URL?
    private var currentSystemURL: URL?
    private var currentScreenURL: URL?
    /// "call_<timestamp>" — names every file of the session and its meta.json.
    private var currentTag: String?
    private var currentDir: URL?

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
        self.currentMicURL = micURL
        self.currentSystemURL = sysURL
        self.currentScreenURL = vidURL

        // Claim the session before a single byte is written. If the app dies
        // between here and the first buffer, the next launch still finds a
        // marker naming these files and knows nobody owns them any more.
        var files = ["mic": micURL.lastPathComponent, "system": sysURL.lastPathComponent]
        if let vidURL { files["screen"] = vidURL.lastPathComponent }
        SessionMeta.begin(tag: tag, in: baseDir, trigger: source, files: files)

        Task {
            do {
                let sysRec = SystemAudioRecorder(audioURL: sysURL, videoURL: vidURL)
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
                self.systemAudioRecorder = sysRec
                try await sysRec.start()

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
        micRecorder?.isPaused = true
        setState(.paused)
        log("[RecordingManager] Paused")
    }

    func resumeRecording() {
        guard state == .paused else { return }
        systemAudioRecorder?.isPaused = false
        micRecorder?.isPaused = false
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
            SessionMeta.update(tag: tag, in: dir, with: [
                "status": SessionMeta.Status.stopped.rawValue,
                "ended": SessionMeta.iso.string(from: Date()),
                "stop_reason": source,
                "pid": nil,
                "pid_started": nil,
            ])
        }
        return session
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

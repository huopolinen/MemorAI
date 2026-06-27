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

        let sysURL = baseDir.appendingPathComponent("call_\(timestamp)_system.m4a")
        let micURL = baseDir.appendingPathComponent("call_\(timestamp)_mic.m4a")
        let vidURL: URL? = settings.recordScreen
            ? baseDir.appendingPathComponent("call_\(timestamp)_screen.mp4")
            : nil

        self.currentMicURL = micURL
        self.currentSystemURL = sysURL
        self.currentScreenURL = vidURL

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
                }

                setState(.recording)
                log("[RecordingManager] All recorders running")
            } catch {
                log("[RecordingManager] ❌ Failed to start: \(error)")
                await systemAudioRecorder?.stop()
                micRecorder?.stop()
                systemAudioRecorder = nil
                micRecorder = nil
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

    func stopRecording(source: String = "manual") {
        guard state == .recording || state == .starting || state == .paused else { return }
        log("[RecordingManager] Recording stopped (source: \(source))")
        setState(.stopping)

        let micURL = currentMicURL
        let sysURL = currentSystemURL
        let screenURL = currentScreenURL

        Task {
            micRecorder?.stop()
            await systemAudioRecorder?.stop()
            micRecorder = nil
            systemAudioRecorder = nil
            setState(.idle)
            onRecordingActiveChanged?(false)
            log("[RecordingManager] All recorders stopped")

            // Mux mic + system audio into screen.mp4 in-place so the video file is
            // self-contained for downstream playback. Runs in parallel with transcription.
            if let screenURL = screenURL {
                AudioMuxer.shared.muxScreenWithAudio(screenURL: screenURL, micURL: micURL, systemURL: sysURL)
            }

            // Auto-transcribe if enabled and whisper is available
            if settings.autoTranscribe {
                guard Transcriber.shared.isAvailable else {
                    log("[RecordingManager] Auto-transcribe on but whisper/model missing — skipping")
                    return
                }
                isTranscribing = true
                onStateChange?(state) // trigger UI update
                log("[RecordingManager] Starting transcription…")
                Transcriber.shared.transcribeSession(micURL: micURL, systemURL: sysURL) { [weak self] in
                    self?.isTranscribing = false
                    self?.onTranscriptionDone?()
                    self?.onStateChange?(self?.state ?? .idle)
                    log("[RecordingManager] Transcription complete")
                }
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

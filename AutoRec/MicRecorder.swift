import Foundation
import AVFoundation

/// Records microphone audio (what you say) into a separate .m4a file
/// using AVAudioEngine + AVAudioFile.
///
/// Robustness features:
/// - Listens to AVAudioEngineConfigurationChange (route changes kill the engine silently otherwise).
/// - Watchdog: if no audio buffer arrives for >10s while we expect to be recording, restart the engine.
/// - All lifecycle and error events go through the shared `log()` so they land in memorai.log.
class MicRecorder {
    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var isRecording = false
    var isPaused = false
    private let outputURL: URL

    private var lastBufferTime: Date?
    private var watchdogTimer: Timer?
    private let watchdogInterval: TimeInterval = 5.0
    private let maxStallSeconds: TimeInterval = 10.0

    private var configChangeObserver: NSObjectProtocol?
    private var bufferCount: UInt64 = 0
    private var writeErrorCount: Int = 0
    private let maxWriteErrors = 5

    // --- Silence detection (mirrors SystemAudioRecorder) ---
    /// Fires on transitions: true = mic silent for silenceDurationThreshold, false = voice resumed.
    var onSilenceChanged: ((Bool) -> Void)?
    private let silenceRMSThreshold: Float = 0.001
    private let silenceDurationThreshold: TimeInterval = 90.0
    private var silenceStart: Date?
    private var isSilent = false

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func start() throws {
        guard !isRecording else { return }

        try? FileManager.default.removeItem(at: outputURL)

        try startEngine()
        isRecording = true
        installConfigChangeObserver()
        startWatchdog()

        log("[MicRecorder] Recording started → \(outputURL.lastPathComponent)")
    }

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            throw MicRecorderError.noMicAvailable
        }

        if audioFile == nil {
            // HE-AAC (v1) — mono-capable. HE-AAC v2 requires stereo (parametric stereo),
            // silently fails on mono writes.
            let fileSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC_HE,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32000,
            ]
            self.audioFile = try AVAudioFile(forWriting: outputURL, settings: fileSettings)
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self, self.isRecording, !self.isPaused else { return }
            self.lastBufferTime = Date()
            self.bufferCount &+= 1
            do {
                try self.audioFile?.write(from: buffer)
                self.writeErrorCount = 0
            } catch {
                self.writeErrorCount += 1
                log("[MicRecorder] ❌ Write error (\(self.writeErrorCount)/\(self.maxWriteErrors)): \(error.localizedDescription)")
                if self.writeErrorCount >= self.maxWriteErrors {
                    log("[MicRecorder] ❌ Too many write errors — stopping mic recording")
                    self.stop()
                }
            }
            self.updateSilenceState(buffer)
        }

        try engine.start()
        self.engine = engine
        self.lastBufferTime = Date()

        log("[MicRecorder] Engine started: \(Int(recordingFormat.sampleRate))Hz, \(recordingFormat.channelCount)ch")
    }

    private func installConfigChangeObserver() {
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigChange()
        }
    }

    private func handleConfigChange() {
        guard isRecording else { return }
        log("[MicRecorder] ⚠️ AudioEngine config change (input device switch) — restarting engine")
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        do {
            try startEngine()
        } catch {
            log("[MicRecorder] ❌ Engine restart failed: \(error.localizedDescription)")
        }
    }

    private func startWatchdog() {
        watchdogTimer?.invalidate()
        let timer = Timer(timeInterval: watchdogInterval, repeats: true) { [weak self] _ in
            self?.checkWatchdog()
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    private func checkWatchdog() {
        guard isRecording, !isPaused, let last = lastBufferTime else { return }
        let stalled = Date().timeIntervalSince(last)
        if stalled > maxStallSeconds {
            log("[MicRecorder] ⚠️ No buffers for \(Int(stalled))s (total \(bufferCount) buffers) — restarting engine")
            handleConfigChange()
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        if let obs = configChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            configChangeObserver = nil
        }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        audioFile = nil
        silenceStart = nil
        isSilent = false
        log("[MicRecorder] Recording stopped (\(bufferCount) buffers total)")
    }

    // MARK: - Silence detection

    /// RMS across all channels of a Float32 PCM buffer. Returns 0 for non-float formats.
    private func bufferRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }
        let channels = Int(buffer.format.channelCount)
        var sum: Float = 0
        for ch in 0..<channels {
            let samples = channelData[ch]
            for i in 0..<frameCount {
                let s = samples[i]
                sum += s * s
            }
        }
        return sqrtf(sum / Float(frameCount * channels))
    }

    private func updateSilenceState(_ buffer: AVAudioPCMBuffer) {
        let rms = bufferRMS(buffer)
        let now = Date()
        if rms < silenceRMSThreshold {
            if silenceStart == nil {
                silenceStart = now
            }
            if !isSilent, let start = silenceStart, now.timeIntervalSince(start) >= silenceDurationThreshold {
                isSilent = true
                log("[MicRecorder] Silence detected (>\(Int(silenceDurationThreshold))s)")
                DispatchQueue.main.async { [weak self] in
                    self?.onSilenceChanged?(true)
                }
            }
        } else {
            silenceStart = nil
            if isSilent {
                isSilent = false
                log("[MicRecorder] Voice resumed")
                DispatchQueue.main.async { [weak self] in
                    self?.onSilenceChanged?(false)
                }
            }
        }
    }
}

enum MicRecorderError: Error, LocalizedError {
    case noMicAvailable

    var errorDescription: String? {
        switch self {
        case .noMicAvailable: return "No microphone available or format invalid"
        }
    }
}

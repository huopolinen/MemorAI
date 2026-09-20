import Foundation
import CoreAudio
import AppKit
import Darwin

/// Detects active calls by watching which *other* processes hold the microphone input.
///
/// The question "who is holding the microphone" is asked of `AudioProcesses`, which is the
/// one place in the app that talks to the per-process CoreAudio API — the Core Audio tap and
/// `MicRoute` ask it the same thing for their own reasons, and all three must never disagree
/// about which app the call is in. Our own PID is filtered out there, so our MicRecorder's
/// AVAudioEngine does not mask call-end.
///
/// Silence-based signals (system audio, mic RMS) are kept as informational callbacks but no
/// longer drive call-end decisions — a call app releases its own mic when the meeting ends,
/// while ambient room noise through our mic engine can keep RMS above threshold indefinitely.
class CallDetector {
    var onCallStarted: (() -> Void)?
    var onCallEnded: (() -> Void)?

    private var timer: Timer?
    private let pollInterval: TimeInterval = 2.0

    /// How many consecutive polls must agree before we change state.
    private let debounceCount = 2
    private var activeCount = 0
    private var inactiveCount = 0
    private var callActive = false

    private var recordingMode = false
    private var recordingStartTime: Date?

    // Retained informational state (from RecordingManager callbacks). Not used for call-end.
    private(set) var systemAudioSilent = false
    private(set) var micSilent = false
    private(set) var systemAudioAvailable = true

    func startMonitoring() {
        stopMonitoring()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.checkStatus()
        }
        timer?.tolerance = 0.5
        log("[CallDetector] Started monitoring (poll every \(pollInterval)s, our pid=\(getpid()))")
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        log("[CallDetector] Stopped monitoring")
    }

    func enterRecordingMode() {
        recordingMode = true
        recordingStartTime = Date()
        systemAudioSilent = false
        micSilent = false
        systemAudioAvailable = true
        log("[CallDetector] Entered recording mode")
    }

    func exitRecordingMode() {
        recordingMode = false
        recordingStartTime = nil
        systemAudioSilent = false
        micSilent = false
        systemAudioAvailable = true
        activeCount = 0
        inactiveCount = 0
        callActive = false
        log("[CallDetector] Exited recording mode, resumed normal monitoring")
    }

    // MARK: - Informational callbacks (no-op for call-end, kept for logging / future use)

    func reportSystemAudioSilence(_ silent: Bool) {
        if systemAudioSilent != silent {
            systemAudioSilent = silent
            log("[CallDetector] System audio silence: \(silent)")
        }
    }

    func reportMicSilence(_ silent: Bool) {
        if micSilent != silent {
            micSilent = silent
            log("[CallDetector] Mic silence: \(silent)")
        }
    }

    func reportSystemAudioUnavailable() {
        guard systemAudioAvailable else { return }
        systemAudioAvailable = false
        log("[CallDetector] System audio unavailable (mic-only session)")
    }

    // MARK: - Poll

    private func checkStatus() {
        let foreign = AudioProcesses.micHolders()
        let inCall = !foreign.isEmpty

        if inCall {
            activeCount += 1
            inactiveCount = 0
        } else {
            inactiveCount += 1
            activeCount = 0
        }

        if !callActive && activeCount >= debounceCount {
            callActive = true
            if !recordingMode {
                let who = foreign.map { $0.label }.joined(separator: ", ")
                log("[CallDetector] Mic captured by \(who) — call detected")
                onCallStarted?()
            }
            return
        }

        if callActive && inactiveCount >= debounceCount {
            callActive = false
            log("[CallDetector] \(recordingMode ? "No other process holds mic" : "Mic released") — call ended")
            onCallEnded?()
        }
    }
}

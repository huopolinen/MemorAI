import Foundation
import CoreAudio

/// Detects active calls by monitoring microphone usage.
/// When the mic is grabbed by another process (Zoom, Teams, FaceTime, etc.)
/// we treat that as a call in progress.
///
/// During recording, the detector switches to "recording mode":
/// it cannot use mic polling (our own AVAudioEngine keeps isRunning=true),
/// so it relies on system audio silence to detect call end.
class CallDetector {
    var onCallStarted: (() -> Void)?
    var onCallEnded: (() -> Void)?

    private var timer: Timer?
    private var micInUse = false
    private let pollInterval: TimeInterval = 2.0

    /// How many consecutive polls must agree before we change state.
    private let debounceCount = 2
    private var activeCount = 0
    private var inactiveCount = 0

    // --- Recording mode ---
    private var recordingMode = false
    /// Timestamp when recording started (to enforce minimum recording duration)
    private var recordingStartTime: Date?

    /// System audio has been silent long enough — set by RecordingManager
    private(set) var systemAudioSilent = false
    /// Mic has been silent long enough — set by RecordingManager
    private(set) var micSilent = false
    /// True while system audio is a usable end-of-call signal. Set to false when the
    /// SystemAudioRecorder reports that no system audio ever arrived (mic-only session).
    private(set) var systemAudioAvailable = true

    /// Minimum recording duration before auto-stop is considered (seconds).
    /// Must be longer than SCStream warmup (~30s) + silence threshold
    /// to avoid false call-end detection from startup silence.
    private let minRecordingDuration: TimeInterval = 60.0

    func startMonitoring() {
        stopMonitoring()
        recordingMode = false
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.checkMicStatus()
        }
        timer?.tolerance = 0.5
        log("[CallDetector] Started monitoring (poll every \(pollInterval)s)")
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        log("[CallDetector] Stopped monitoring")
    }

    /// Switch to recording mode — mic polling stops, silence-based detection takes over.
    func enterRecordingMode() {
        recordingMode = true
        systemAudioSilent = false
        micSilent = false
        systemAudioAvailable = true
        recordingStartTime = Date()
        // Keep timer running but checkMicStatus will skip in recording mode
        log("[CallDetector] Entered recording mode")
    }

    /// Exit recording mode, resume normal mic polling.
    func exitRecordingMode() {
        recordingMode = false
        recordingStartTime = nil
        systemAudioSilent = false
        micSilent = false
        systemAudioAvailable = true
        activeCount = 0
        inactiveCount = 0
        micInUse = false
        log("[CallDetector] Exited recording mode, resumed normal monitoring")
    }

    /// Called by RecordingManager when system audio silence state changes.
    func reportSystemAudioSilence(_ silent: Bool) {
        let changed = systemAudioSilent != silent
        systemAudioSilent = silent
        if changed {
            log("[CallDetector] System audio silence: \(silent)")
            if silent && recordingMode {
                tryEndCall()
            }
        }
    }

    /// Called by RecordingManager when mic silence state changes (speaker is quiet / muted).
    func reportMicSilence(_ silent: Bool) {
        let changed = micSilent != silent
        micSilent = silent
        if changed {
            log("[CallDetector] Mic silence: \(silent)")
            if silent && recordingMode {
                tryEndCall()
            }
        }
    }

    /// Called by RecordingManager when we learn the session has no system audio at all
    /// (voice memo, headphones-only call). From this point end-of-call is decided by mic alone.
    func reportSystemAudioUnavailable() {
        guard recordingMode, systemAudioAvailable else { return }
        systemAudioAvailable = false
        log("[CallDetector] System audio unavailable — call-end gated on mic silence only")
        tryEndCall()
    }

    private func tryEndCall() {
        guard recordingMode else { return }
        // Require mic silence. If system audio is available, also require system silence
        // (AND-gate) — a brief lull on one side of the call is not the end of the call.
        let systemCondition = !systemAudioAvailable || systemAudioSilent
        guard micSilent, systemCondition else { return }

        if let start = recordingStartTime,
           Date().timeIntervalSince(start) >= minRecordingDuration {
            let reason = systemAudioAvailable
                ? "mic & system silent"
                : "mic silent, system unavailable"
            log("[CallDetector] Call ended (\(reason), recording >\(Int(minRecordingDuration))s)")
            onCallEnded?()
        } else if let start = recordingStartTime {
            let remaining = minRecordingDuration - Date().timeIntervalSince(start) + 1.0
            log("[CallDetector] Silence detected but recording too short, will retry in \(Int(remaining))s")
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                self?.tryEndCall()
            }
        }
    }

    // MARK: - Normal mode (not recording)

    private func checkMicStatus() {
        guard !recordingMode else { return }

        let inUse = isMicrophoneInUse()

        if inUse {
            activeCount += 1
            inactiveCount = 0
        } else {
            inactiveCount += 1
            activeCount = 0
        }

        if activeCount >= debounceCount && !micInUse {
            micInUse = true
            log("[CallDetector] Mic active for \(debounceCount) polls — call detected")
            onCallStarted?()
        } else if inactiveCount >= debounceCount && micInUse {
            micInUse = false
            log("[CallDetector] Mic inactive for \(debounceCount) polls — call ended")
            onCallEnded?()
        }
    }

    // MARK: - CoreAudio mic query

    /// Check if the default input device is being used by any process.
    func isMicrophoneInUse() -> Bool {
        var defaultDeviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &defaultDeviceID
        )
        guard status == noErr, defaultDeviceID != kAudioObjectUnknown else {
            return false
        }

        var isRunning: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let runStatus = AudioObjectGetPropertyData(
            defaultDeviceID, &runningAddress, 0, nil, &size, &isRunning
        )
        guard runStatus == noErr else { return false }

        return isRunning != 0
    }
}

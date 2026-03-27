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

    /// Minimum recording duration before auto-stop is considered (seconds).
    /// Must be longer than SCStream warmup (~30s) + silence threshold (20s)
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
        recordingStartTime = Date()
        // Keep timer running but checkMicStatus will skip in recording mode
        log("[CallDetector] Entered recording mode")
    }

    /// Exit recording mode, resume normal mic polling.
    func exitRecordingMode() {
        recordingMode = false
        recordingStartTime = nil
        systemAudioSilent = false
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

    private func tryEndCall() {
        guard recordingMode, systemAudioSilent else { return }
        if let start = recordingStartTime,
           Date().timeIntervalSince(start) >= minRecordingDuration {
            log("[CallDetector] Call ended (system audio silent, recording >\(Int(minRecordingDuration))s)")
            onCallEnded?()
        } else {
            // Recording too short — schedule a retry at the minimum duration mark
            if let start = recordingStartTime {
                let remaining = minRecordingDuration - Date().timeIntervalSince(start) + 1.0
                log("[CallDetector] Silence detected but recording too short, will retry in \(Int(remaining))s")
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                    self?.tryEndCall()
                }
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

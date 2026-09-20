import Foundation
import AVFoundation
import CoreAudio
import ObjCSupport

/// Records microphone audio (what you say) into a separate .caf file
/// using AVAudioEngine + AVAudioFile.
///
/// The track is uncompressed PCM, not AAC: that is what lets a call survive the
/// process being killed mid-recording. `TrackCompressor` trades it for AAC once
/// the transcript exists — see `AudioFormats` for why the order matters.
///
/// Surviving a microphone change mid-call is the other half of the job, and it
/// takes three things that are each silent when missing:
///
/// - **Following the route.** AVAudioEngine binds to the input device it found
///   at start and stays there. Change the default under a running engine and
///   nothing happens at all: no `AVAudioEngineConfigurationChange`, no error,
///   the same microphone in the file as before. So we watch
///   `kAudioHardwarePropertyDefaultInputDevice` ourselves *and* re-ask on a
///   15-second tick, because the listener alone has been seen to miss changes.
/// - **Proving the new engine is alive, not guessing whose change it was.**
///   See `handleConfigChange`.
/// - **Padding the dead span after the new engine attaches, never before.**
///   See `padPendingGap`.
///
/// подход из amanu (MIT, gsamat/amanu): Sources/amanu/Audio/MicRecorder.swift
/// и docs/pitfalls.md («The microphone has to be followed; it is not inherited»).
class MicRecorder {
    private var engine: AVAudioEngine?
    private let outputURL: URL
    private var isRecording = false
    var isPaused = false

    // MARK: State shared with the audio tap
    //
    // The tap callback runs on a real-time audio thread while restarts happen
    // on main, and a restart reads exactly what the tap writes (the time of the
    // last buffer, the open gap, the file). Before route following there was
    // nothing to race with; now there is, so it lives behind one lock.
    private let lock = NSLock()
    private var audioFile: AVAudioFile?
    private var lastBufferAt: Date?
    /// When the current dead span began, while it is still open. Set on main
    /// when an engine is torn down, cleared by the tap that closes it.
    private var gapSince: Date?
    private var bufferCount: UInt64 = 0
    private var writeErrorCount = 0
    private var silenceStart: Date?
    private var isSilent = false
    /// True once `stop()` has closed the track. A buffer that was already in
    /// flight when that happened must not re-create the file it just closed —
    /// `AVAudioFile(forWriting:)` truncates, so the race would have thrown away
    /// the whole call.
    private var sessionEnded = false

    private let maxWriteErrors = 5

    // MARK: Main-thread only
    private var configChangeObserver: NSObjectProtocol?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var tickTimer: Timer?
    private var ticks = 0
    private var restartPending = false
    /// When the current engine finished attaching — the reference point for
    /// both liveness questions below.
    private var attachedAt = Date.distantPast
    /// The device this engine is on, so a route check can tell "moved" from
    /// "same microphone, different notification".
    private var boundDevice: AudioObjectID?
    /// Format of the open file. Fixed for the session: a device that comes back
    /// at another rate is converted into it rather than changing it.
    private var fileFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterSource: AVAudioFormat?
    /// Wall-clock times of this session's restarts, newest last — used only to
    /// notice a restart storm.
    private var restartTimes: [Date] = []

    // MARK: Echo cancellation (off by default — see SettingsManager.micVoiceProcessing)
    //
    // Read once, at start: a setting toggled mid-call must not change the shape
    // of a track that is already being written. Whatever the session started
    // with is what every restart re-applies — restarting raw "because the call
    // app cancels echo anyway" is wrong (the call app cancels what *it* sends,
    // we tap the device), and amanu paid for it with the far end at −3 dB on
    // its own track for 35 minutes.
    private var voiceProcessingRequested = false
    private var voiceProcessingActive = false
    /// Set once the voice route has proved it delivers nothing but digital
    /// zeros; after that the session stays raw rather than retrying it.
    private var voiceProcessingGaveSilence = false
    // Touched from the audio thread only, reset on main before the engine that
    // will use them is started, so no buffer can be in flight over the reset.
    private var voiceLivenessSettled = true
    private var voiceLivenessFrames = 0
    private var voiceLivenessTarget = 0
    private var voiceLivenessPeak: Float = 0

    /// How often the ticker runs. It answers two questions at different rates:
    /// a stalled engine every tick, the route every third one.
    private let tickInterval: TimeInterval = 5.0
    private let routeTickEvery = 3
    /// No buffer for this long means the engine is dead and has to be rebuilt.
    /// Longer than `settleDeadline` on purpose: right after an attach the
    /// question is asked by the settle path, which knows an attach just
    /// happened; away from an attach a long window avoids restarting a healthy
    /// engine that merely hiccuped.
    private let maxStallSeconds: TimeInterval = 10.0
    /// A configuration change this soon after an attach may be our own doing —
    /// see `handleConfigChange`, which does not act on that by itself.
    private let settleWindow: TimeInterval = 1.5
    /// When the "are buffers arriving?" question gets its answer, measured from
    /// the attach. Long enough for a slow device to warm up, short enough that
    /// a genuinely dead engine costs five seconds and not a call.
    private let settleDeadline: TimeInterval = 5.0
    /// A buffer this recent means capture is alive.
    private let aliveWithin: TimeInterval = 1.5
    /// A route in the middle of changing answers differently from one second to
    /// the next, and every move costs seconds of audio — so ask twice.
    private let routeSettle: TimeInterval = 1.5
    /// Restarts this close together, and how many of them mean something is
    /// wrong with the restart itself rather than with the route.
    private let stormWindow: TimeInterval = 30
    private let stormLimit = 3

    // --- Silence detection (mirrors SystemAudioRecorder) ---
    /// Fires on transitions: true = mic silent for silenceDurationThreshold, false = voice resumed.
    var onSilenceChanged: ((Bool) -> Void)?
    private let silenceRMSThreshold: Float = 0.001
    private let silenceDurationThreshold: TimeInterval = 90.0

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func start() throws {
        guard !isRecording else { return }

        try? FileManager.default.removeItem(at: outputURL)

        isRecording = true
        withLock { sessionEnded = false }
        voiceProcessingRequested = SettingsManager.shared.micVoiceProcessing
        do {
            try attach(voiceProcessing: voiceProcessingRequested)
        } catch {
            isRecording = false
            throw error
        }
        installConfigChangeObserver()
        listenForDefaultInputChanges()
        startTicker()

        log("[MicRecorder] Recording started → \(outputURL.lastPathComponent)")
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        restartPending = false
        tickTimer?.invalidate()
        tickTimer = nil
        if let obs = configChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            configChangeObserver = nil
        }
        stopListeningForDefaultInputChanges()
        teardownEngine()
        let total = withLock { () -> UInt64 in
            sessionEnded = true
            audioFile = nil
            fileFormat = nil
            // Nothing will arrive to close an open gap now, and the track ends
            // where the audio ended.
            gapSince = nil
            lastBufferAt = nil
            silenceStart = nil
            isSilent = false
            return bufferCount
        }
        log("[MicRecorder] Recording stopped (\(total) buffers total)")
    }

    // MARK: - Engine

    /// Build the engine, install the tap and start capturing. Called at start
    /// and again on every restart; the file, if one is already open, is kept.
    private func attach(voiceProcessing: Bool) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let device = MicRoute.preferred()

        // Echo cancellation, when the session asked for it. A route the voice
        // unit refuses is not fatal — raw capture is what we would have done
        // anyway — so a refusal is logged and the attach carries on.
        var voice = false
        if voiceProcessing {
            var vpError: Error?
            let raised = objc_tryCatch {
                do {
                    try inputNode.setVoiceProcessingEnabled(true)
                    // The live voice unit makes macOS treat this like a call
                    // and duck everything else: the meeting itself would get
                    // quieter the moment recording starts.
                    inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                        AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                            enableAdvancedDucking: false, duckingLevel: .min)
                    voice = true
                } catch {
                    vpError = error
                }
            }
            if let reason = raised?.localizedDescription ?? vpError?.localizedDescription {
                log("[MicRecorder] ⚠️ Echo cancellation unavailable (\(reason)) — recording raw")
                voice = false
            }
        }

        // Probe the input format ONLY to confirm a usable mic exists. We deliberately
        // do NOT pass this format to installTap: the hardware input format can change
        // between this read and the tap install (e.g. ScreenCaptureKit reconfiguring
        // the input route when system-audio capture starts moments earlier). Passing a
        // now-stale explicit format makes installTap raise an uncatchable NSException
        // ("format.sampleRate == hwFormat.sampleRate"), which aborts the whole app.
        let probeFormat = inputNode.outputFormat(forBus: 0)
        guard probeFormat.sampleRate > 0, probeFormat.channelCount > 0 else {
            throw MicRecorderError.noMicAvailable
        }

        // With echo cancellation the tap needs ONE explicit mono client format:
        // VoiceProcessingIO is a duplex unit, not an input effect, and handed
        // the inherited multichannel route format it delivers digital silence
        // (amanu rca-001). Mid-session the rate is the open file's rather than
        // the new device's — the file's format is the one thing that cannot
        // change. Raw capture keeps format: nil, see below.
        var tapFormat: AVAudioFormat?
        if voice {
            let rate = withLock { fileFormat }?.sampleRate ?? probeFormat.sampleRate
            guard let mono = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false
            ) else {
                throw MicRecorderError.noMicAvailable
            }
            tapFormat = mono
        }

        // format: nil tells the engine to use the input bus's own format, resolved
        // atomically at install time — no read/install race, no mismatch crash. The
        // output file is created lazily from the first buffer's actual format so its
        // sample rate / channel count always match the data we write.
        //
        // Even with nil, AVAudioEngine can still raise an uncatchable NSException for
        // other invalid states (route changes, device disappearing mid-start). Wrap
        // installTap + start in the ObjC shim so any such exception becomes a Swift
        // error and degrades to a mic-less session instead of aborting the whole app
        // (which would also lose the in-progress system-audio recording).
        var startError: Error?
        let nsError = objc_tryCatch {
            if let tapFormat = tapFormat {
                // Complete the duplex graph: VoiceProcessingIO must render to
                // an output device or the input side never produces audio. The
                // mixer has no sources — nothing is monitored or played — the
                // connection exists only to give the unit an output path.
                engine.connect(engine.mainMixerNode, to: engine.outputNode, format: tapFormat)
            }
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
                self?.handle(buffer)
            }

            do {
                try engine.start()
            } catch {
                startError = error
            }
        }

        if let nsError = nsError {
            inputNode.removeTap(onBus: 0)
            throw MicRecorderError.engineException(nsError.localizedDescription)
        }
        if let startError = startError {
            inputNode.removeTap(onBus: 0)
            throw startError
        }

        self.engine = engine
        self.attachedAt = Date()
        self.boundDevice = device?.id
        self.voiceProcessingActive = inputNode.isVoiceProcessingEnabled
        armVoiceLiveness(format: tapFormat)

        let shape = tapFormat.map { "\(Int($0.sampleRate))Hz/1ch (echo-cancelled)" }
            ?? "\(Int(probeFormat.sampleRate))Hz/\(probeFormat.channelCount)ch (native, no resampling)"
        log("[MicRecorder] Engine started on \(device?.name ?? "default input"): \(shape)")
    }

    private func teardownEngine() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    // MARK: - Capture

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard isRecording else { return }

        // Liveness is bookkeeping about the *engine*, so it is recorded before
        // anything decides whether to write: a paused session still has to be
        // able to tell a live engine from a dead one, and before this the
        // watchdog read a pause as a stall and restarted for nothing.
        let now = Date()
        withLock {
            lastBufferAt = now
            bufferCount &+= 1
        }

        if !voiceLivenessSettled { checkVoiceLiveness(buffer) }

        guard !isPaused else {
            // Pause already drops wall-clock time from the track, so a route
            // gap that opened while paused has nothing left to compensate for.
            withLock { gapSince = nil }
            return
        }

        let opened: AVAudioFile?
        do {
            opened = try openFile(for: buffer)
        } catch {
            noteWriteFailure("Failed to create audio file", error)
            return
        }
        guard let file = opened else { return }

        padPendingGap(before: buffer, to: file)

        guard let outgoing = matchedToFile(buffer) else { return }
        // Wrapped in the ObjC shim for the same reason `installTap` is: a
        // format AVAudioFile dislikes is an NSException, not an error, and an
        // NSException here would abort the process — losing the system-audio
        // track and the screen recording along with this one.
        var writeError: Error?
        let raised = objc_tryCatch {
            do { try file.write(from: outgoing) } catch { writeError = error }
        }
        if let raised = raised {
            noteWriteFailure("Write raised an exception", MicRecorderError.engineException(raised.localizedDescription))
        } else if let writeError = writeError {
            noteWriteFailure("Write error", writeError)
        } else {
            withLock { writeErrorCount = 0 }
        }
        updateSilenceState(buffer)
    }

    /// The open file, created on first use from the first buffer's own format.
    /// Nil once the session has ended — see `sessionEnded`.
    private func openFile(for buffer: AVAudioPCMBuffer) throws -> AVAudioFile? {
        var ended = false
        var existing: AVAudioFile?
        withLock {
            ended = sessionEnded
            existing = audioFile
        }
        if ended { return nil }
        if let existing = existing { return existing }

        let file = try makeAudioFile(format: buffer.format)
        var accepted = false
        withLock {
            if !sessionEnded {
                audioFile = file
                fileFormat = file.processingFormat
                accepted = true
            }
        }
        return accepted ? file : nil
    }

    /// Creates the PCM output file matched to the input device's native rate and channel
    /// count. The tap delivers buffers in the device's native format (24/48/96 kHz, mono
    /// or stereo); writing them into a hardcoded 48 kHz mono AVAudioFile silently packed
    /// samples at the wrong rate and produced 2× speed audio (1.4.0/1.4.1) or empty files
    /// when manual AVAudioConverter conversion failed (1.4.2). Linear PCM accepts any
    /// sample rate and channel count, so writing in native format is reliable.
    private func makeAudioFile(format: AVAudioFormat) throws -> AVAudioFile {
        return try AVAudioFile(
            forWriting: outputURL,
            settings: AudioFormats.pcmSettings(
                sampleRate: format.sampleRate, channels: format.channelCount),
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    /// The buffer in the open file's format, converting if the device changed
    /// shape under us.
    ///
    /// The file's format is fixed when it is created and cannot change; a new
    /// microphone can easily be 24 kHz mono where the old one was 48 kHz
    /// stereo. `AVAudioFile.write(from:)` does not return an error for a
    /// mismatched buffer — it raises an NSException, which aborts the process,
    /// so a restart onto a differently-shaped device was a crash waiting for
    /// the right pair of microphones.
    private func matchedToFile(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let target = withLock({ fileFormat }) else { return nil }
        let source = buffer.format
        if source.sampleRate == target.sampleRate,
           source.channelCount == target.channelCount,
           source.commonFormat == target.commonFormat,
           source.isInterleaved == target.isInterleaved {
            return buffer
        }

        if converter == nil || converterSource != source {
            converter = AVAudioConverter(from: source, to: target)
            converterSource = source
            if converter != nil {
                log("[MicRecorder] Converting \(Int(source.sampleRate))Hz/\(source.channelCount)ch "
                    + "→ file \(Int(target.sampleRate))Hz/\(target.channelCount)ch")
            }
        }
        guard let converter = converter else {
            noteWriteFailure("Cannot convert \(source) to \(target)")
            return nil
        }

        let ratio = target.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        do {
            if source.sampleRate == target.sampleRate {
                try converter.convert(to: out, from: buffer)
            } else {
                try Self.convertResampling(buffer, to: out, using: converter)
            }
        } catch {
            noteWriteFailure("Conversion failed", error)
            return nil
        }
        return out
    }

    /// Feed `buffer` through `converter` exactly once, for the rate-mismatched
    /// case the one-shot `convert(to:from:)` cannot handle.
    private static func convertResampling(
        _ buffer: AVAudioPCMBuffer,
        to out: AVAudioPCMBuffer,
        using converter: AVAudioConverter
    ) throws {
        final class Feed { var done = false }
        let feed = Feed()
        var convertError: NSError?
        converter.convert(to: out, error: &convertError) { _, outStatus in
            if feed.done {
                outStatus.pointee = .noDataNow
                return nil
            }
            feed.done = true
            outStatus.pointee = .haveData
            return buffer
        }
        if let convertError { throw convertError }
    }

    private func noteWriteFailure(_ what: String, _ error: Error? = nil) {
        let count = withLock { () -> Int in
            writeErrorCount += 1
            return writeErrorCount
        }
        let detail = error.map { ": \($0.localizedDescription)" } ?? ""
        log("[MicRecorder] ❌ \(what) (\(count)/\(maxWriteErrors))\(detail)")
        guard count >= maxWriteErrors else { return }
        log("[MicRecorder] ❌ Too many file errors — stopping mic recording")
        // stop() tears down the engine this callback is running on, so it can
        // only be done from somewhere that is not the audio thread.
        DispatchQueue.main.async { [weak self] in self?.stop() }
    }

    // MARK: - Echo cancellation liveness

    /// Arm the "is this route actually producing audio?" check for a voice
    /// attach, and disarm it for a raw one (raw capture has never had this
    /// failure mode).
    private func armVoiceLiveness(format: AVAudioFormat?) {
        guard let format = format else {
            voiceLivenessSettled = true
            return
        }
        // Mid-session the window is longer, because there the check has a false
        // positive it does not have at startup: the noise suppressor emits true
        // digital zeros in a quiet room, in runs approaching a second.
        let seconds: Double = withLock { audioFile } == nil ? 1 : 3
        voiceLivenessTarget = Int(format.sampleRate * seconds)
        voiceLivenessFrames = 0
        voiceLivenessPeak = 0
        voiceLivenessSettled = false
    }

    /// Some device pairs take the voice unit, report it enabled, and deliver
    /// callbacks full of digital zeros. Nothing reports that — the only signal
    /// is the samples themselves, so the first second of them is measured.
    private func checkVoiceLiveness(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        if let data = buffer.floatChannelData?[0] {
            for i in 0..<frames { voiceLivenessPeak = max(voiceLivenessPeak, abs(data[i])) }
        }
        voiceLivenessFrames += frames
        guard voiceLivenessFrames >= voiceLivenessTarget else { return }
        voiceLivenessSettled = true
        guard voiceLivenessPeak == 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isRecording, self.voiceProcessingActive else { return }
            self.voiceProcessingGaveSilence = true
            self.restartCapture(reason: "echo cancellation delivered digital silence")
        }
    }

    // MARK: - Route following

    private func installConfigChangeObserver() {
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            // Other engines in this process are none of our business.
            guard (note.object as? AVAudioEngine) === self.engine else { return }
            self.handleConfigChange()
        }
    }

    /// Something reconfigured the input device under the engine. The engine may
    /// have died of it, or it may be perfectly alive — and at the moment the
    /// notification arrives the two are indistinguishable.
    ///
    /// Which is why this does not try to tell them apart by cause. Deciding "we
    /// probably did that ourselves" and dismissing the change is the expensive
    /// mistake: the same notification arrives when the engine has genuinely
    /// stopped, and a dismissed one means the microphone is never rebuilt —
    /// amanu measured 43 silent seconds of a 67-second recording that way. The
    /// only question with an answer is asked instead: five seconds after the
    /// attach, are buffers still arriving?
    private func handleConfigChange() {
        guard isRecording, !restartPending else { return }
        restartPending = true

        if Date().timeIntervalSince(attachedAt) <= settleWindow, engine?.isRunning == true {
            let wait = max(attachedAt.addingTimeInterval(settleDeadline).timeIntervalSinceNow, 0.5)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self = self, self.isRecording else { return }
                if self.audioIsFlowing {
                    self.restartPending = false
                    log("[MicRecorder] Config change right after our own attach — capture is alive")
                    return
                }
                self.restartCapture(reason: "no audio after the engine was reconfigured")
            }
            return
        }

        // A reconfiguration storm posts several notifications; let it settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.restartCapture(reason: "input device reconfigured")
        }
    }

    /// Whether a buffer has landed since the *current* engine attached, recently
    /// enough to call capture alive. Both halves matter: a buffer from the
    /// engine that has just been torn down says nothing about the one that
    /// replaced it.
    private var audioIsFlowing: Bool {
        guard let last = withLock({ lastBufferAt }), last > attachedAt else { return false }
        return Date().timeIntervalSince(last) < aliveWithin
    }

    /// Follow the system default input while recording. A default that changes
    /// under a running engine is silent in every other way — the engine stays on
    /// the device it was built around, and `AVAudioEngineConfigurationChange` is
    /// not posted — so without this listener, choosing another microphone
    /// mid-call leaves us recording the old one for the rest of the call.
    private func listenForDefaultInputChanges() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.checkRoute() }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener
        )
        if status == noErr {
            defaultInputListener = listener
        } else {
            log("[MicRecorder] ⚠️ Cannot watch the default microphone (OSStatus \(status)) — "
                + "relying on the 15s route tick alone")
        }
    }

    private func stopListeningForDefaultInputChanges() {
        guard let listener = defaultInputListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener
        )
        defaultInputListener = nil
    }

    /// One timer, two questions, because they are answered from the same two
    /// facts (when the engine attached, when the last buffer arrived) and
    /// splitting them across two mechanisms is how they end up disagreeing.
    private func startTicker() {
        tickTimer?.invalidate()
        ticks = 0
        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func tick() {
        guard isRecording else { return }
        ticks += 1
        checkStall()
        // The property listener is not enough on its own — it has been seen to
        // miss changes, and a missed one is a whole call on the wrong
        // microphone, so the answer is re-asked every 15 seconds regardless.
        if ticks % routeTickEvery == 0 { checkRoute() }
    }

    /// The watchdog. Deliberately measured from the later of "engine attached"
    /// and "last buffer": a fresh engine has not had time to deliver anything,
    /// and counting that as a stall restarts it forever.
    private func checkStall() {
        guard !restartPending else { return }
        let last = withLock { lastBufferAt }
        let since = max(last ?? .distantPast, attachedAt)
        let stalled = Date().timeIntervalSince(since)
        guard stalled > maxStallSeconds else { return }
        let total = withLock { bufferCount }
        restartCapture(reason: "no buffers for \(Int(stalled))s (total \(total) buffers)")
    }

    /// Re-examine which microphone we ought to be on, and move if it is not the
    /// one we are on.
    private func checkRoute() {
        guard isRecording, !restartPending else { return }
        guard let wanted = MicRoute.preferred(), wanted.id != boundDevice else { return }
        let target = wanted.id
        DispatchQueue.main.asyncAfter(deadline: .now() + routeSettle) { [weak self] in
            guard let self = self, self.isRecording, !self.restartPending else { return }
            guard let now = MicRoute.preferred(), now.id == target, now.id != self.boundDevice
            else { return }
            let was = AudioDevices.name(of: self.boundDevice) ?? "?"
            self.restartCapture(reason: "microphone moved to \(now.name ?? "?") (was \(was))")
        }
    }

    // MARK: - Restart

    /// Rebuild the engine on the new route, keeping the file and the wall clock.
    private func restartCapture(reason: String) {
        restartPending = false
        guard isRecording else { return }
        log("[MicRecorder] ⚠️ \(reason) — restarting engine")

        teardownEngine()
        // The gap is only *marked* here, not written: the first buffer of the
        // new engine is the only thing that knows how long the dead span really
        // was, because starting a device costs hundreds of milliseconds beyond
        // the last buffer of the old one. Padding before the attach leaves those
        // out of the file and writes everything after the restart earlier than
        // it happened — amanu measured 0.37 s per restart against a Zoom cloud
        // recording of the same call, and it never comes back. Ours would also
        // mis-assign who said what, since speaker attribution lines the two
        // tracks up by time.
        openGap()

        let now = Date()
        restartTimes = restartTimes.filter { now.timeIntervalSince($0) < stormWindow }
        // A track with an echo on it is a bad recording; a track rebuilt every
        // two seconds is no recording. Past the limit the session goes raw.
        let storming = restartTimes.count >= stormLimit
        if storming {
            log("[MicRecorder] ⚠️ \(restartTimes.count) restarts in \(Int(stormWindow))s — "
                + "the route is unstable, capturing raw")
        }
        restartTimes.append(now)

        // The rebuild keeps whatever the session started with. Dropping echo
        // cancellation here is silent at the time and obvious a day later: the
        // far end ends up on our own track, loud enough for speaker
        // attribution to vote it onto our side.
        let voice = voiceProcessingRequested && !voiceProcessingGaveSilence && !storming
        do {
            try attach(voiceProcessing: voice)
            return
        } catch {
            log("[MicRecorder] ❌ Engine restart failed: \(error.localizedDescription)")
        }
        if voice {
            // The new route may be one the voice unit cannot take. Raw is worse
            // than cancelled, and both beat no microphone at all.
            do {
                try attach(voiceProcessing: false)
                log("[MicRecorder] Restarted raw — echo cancellation refused this route")
                return
            } catch {
                log("[MicRecorder] ❌ Raw restart failed too: \(error.localizedDescription)")
            }
        }
        log("[MicRecorder] Retrying the restart in 2s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self, self.isRecording else { return }
            self.restartCapture(reason: "retrying after a failed restart")
        }
    }

    /// Mark the wall-clock start of a dead span. Idempotent on purpose: a
    /// restart that fails and retries is still one gap, and moving its start
    /// forward would swallow the time the retries took.
    private func openGap() {
        withLock {
            if gapSince == nil { gapSince = lastBufferAt }
        }
    }

    /// Close an open gap ahead of the first buffer that follows it: zeroed
    /// frames for the span between the last buffer of the old engine and the
    /// start of the audio this one carries, so the track keeps its place on the
    /// wall clock.
    private func padPendingGap(before buffer: AVAudioPCMBuffer, to file: AVAudioFile) {
        let since: Date? = withLock {
            defer { gapSince = nil }
            return gapSince
        }
        guard let since = since else { return }
        let carried = Double(buffer.frameLength) / buffer.format.sampleRate
        let gap = Date().timeIntervalSince(since) - carried
        let format = file.processingFormat
        // Spans under 50 ms are left alone: buffer timing and the wall clock
        // disagree by about that much anyway, and padding the disagreement
        // would drift the track as surely as ignoring a real gap.
        guard gap > 0.05, format.sampleRate > 0 else { return }
        log("[MicRecorder] Route was down \(Int(gap * 1000))ms — padding the track with silence")
        writeSilence(frames: AVAudioFrameCount(gap * format.sampleRate), to: file)
    }

    private func writeSilence(frames: AVAudioFrameCount, to file: AVAudioFile) {
        let format = file.processingFormat
        var remaining = frames
        let chunk = AVAudioFrameCount(format.sampleRate)
        while remaining > 0 {
            let n = min(remaining, chunk)
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else { return }
            buf.frameLength = n
            if let data = buf.floatChannelData {
                for ch in 0..<Int(format.channelCount) {
                    data[ch].update(repeating: 0, count: Int(n))
                }
            }
            try? file.write(from: buf)
            remaining -= n
        }
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
        var transition: Bool?
        withLock {
            if rms < silenceRMSThreshold {
                if silenceStart == nil { silenceStart = now }
                if !isSilent, let start = silenceStart,
                   now.timeIntervalSince(start) >= silenceDurationThreshold {
                    isSilent = true
                    transition = true
                }
            } else {
                silenceStart = nil
                if isSilent {
                    isSilent = false
                    transition = false
                }
            }
        }
        guard let silent = transition else { return }
        log(silent
            ? "[MicRecorder] Silence detected (>\(Int(silenceDurationThreshold))s)"
            : "[MicRecorder] Voice resumed")
        DispatchQueue.main.async { [weak self] in
            self?.onSilenceChanged?(silent)
        }
    }

    // MARK: - Lock

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

enum MicRecorderError: Error, LocalizedError {
    case noMicAvailable
    case engineException(String)

    var errorDescription: String? {
        switch self {
        case .noMicAvailable: return "No microphone available or format invalid"
        case .engineException(let reason): return "AVAudioEngine exception: \(reason)"
        }
    }
}

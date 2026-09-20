import AVFoundation
import CoreAudio
import CoreGraphics
import Foundation

/// The second way of capturing system audio: a Core Audio process tap
/// (macOS 14.4+) instead of ScreenCaptureKit.
///
/// Why it exists. `SystemAudioRecorder` asks SCStream for "system audio" and
/// gets *everything* the Mac plays — the call, but also the music that was
/// still going, the notification dings, the YouTube tab in the next window.
/// All of it lands in `call_<ts>_system.caf` and from there in the transcript.
/// A process tap can be pointed at the processes of the call app alone, which
/// is the whole point of this path: what comes out is the far end and nothing
/// else, and "the far end went quiet" starts meaning what it says.
///
/// How it works. `AudioHardwareCreateProcessTap` makes a tap object; a
/// *private* aggregate device with that tap in its tap list gives us an IOProc
/// that is handed the mixed-down buffers. No virtual device is installed, no
/// kernel extension, and the aggregate is private so it never appears in the
/// user's sound settings. Both objects are destroyed in `cleanup()` — a
/// leaked aggregate device is a real nuisance on someone's Mac.
///
/// Relationship with screen recording (`RecordingManager` owns this pairing):
/// video still comes from `SCStream`, but when this path is selected the
/// stream is created with `capturesAudio = false` and no audio URL, so the two
/// never write the same file and the system track is never recorded twice.
/// The tap, in turn, never touches video. They share nothing but the session's
/// file names.
///
/// Permissions. The tap needs its own TCC grant ("System Audio Recording",
/// shown next to Screen Recording in System Settings → Privacy & Security),
/// which is *not* the same grant SCStream capture runs on. Measured here on
/// macOS 26.2 on 2026-09-20: with the screen grant present but the audio one
/// missing, every CoreAudio call still returns `noErr` — the start just takes
/// about 90 seconds (≈60 s inside `AudioDeviceCreateIOProcIDWithBlock`, ≈30 s
/// inside `AudioDeviceStart`) and then the IOProc is never called at all. No
/// error, no prompt, no audio. Hence both the deadline on `start` and the
/// probe timer below; and hence `NSAudioCaptureUsageDescription` has to be in
/// the app's Info.plist, or macOS has nothing to put in the prompt.
///
/// Format and crash behaviour are deliberately identical to the SCStream path:
/// 16-bit PCM in a CAF via `AudioFormats.pcmSettings`, readable at every
/// instant, compressed to m4a only once a transcript exists.
///
/// подход из amanu (MIT, gsamat/amanu): Sources/amanu/Audio/SystemAudioRecorder.swift
@available(macOS 14.4, *)
class CoreAudioTapRecorder {
    /// Whose output lands on the system track.
    enum Scope: CustomStringConvertible {
        /// Everything the Mac plays — what the SCStream path always does.
        case everything
        /// Only processes whose bundle id starts with one of these families
        /// (the call app and its helpers).
        case apps([String])

        var description: String {
            switch self {
            case .everything: return "весь звук системы"
            case .apps(let families): return families.joined(separator: ", ")
            }
        }
    }

    enum TapError: Error, LocalizedError {
        case permissionMissing
        case startTimedOut(TimeInterval)
        case tapCreationFailed(OSStatus)
        case tapFormatUnreadable(OSStatus)
        case aggregateCreationFailed(OSStatus)
        case ioProcCreationFailed(OSStatus)
        case deviceStartFailed(OSStatus)
        case fileCreationFailed(Error)

        var errorDescription: String? {
            switch self {
            case .permissionMissing:
                return "нет разрешения «Запись экрана и системного звука» — Core Audio tap без него не запускается"
            case .startTimedOut(let seconds):
                return "тап не запустился за \(Int(seconds))с — похоже, не выдано разрешение на запись системного звука"
            case .tapCreationFailed(let s):
                return "не удалось создать process tap (OSStatus \(s)) — проверь Системные настройки → Конфиденциальность → Запись экрана и системного звука"
            case .tapFormatUnreadable(let s): return "не читается формат тапа (OSStatus \(s))"
            case .aggregateCreationFailed(let s): return "не создаётся агрегатное устройство (OSStatus \(s))"
            case .ioProcCreationFailed(let s): return "не создаётся IOProc (OSStatus \(s))"
            case .deviceStartFailed(let s): return "устройство не стартовало (OSStatus \(s))"
            case .fileCreationFailed(let e): return "не создаётся файл дорожки: \(e.localizedDescription)"
            }
        }
    }

    // MARK: - Callbacks (same contract as SystemAudioRecorder's audio side)

    /// Fires when system audio transitions to/from silence (>90 s quiet).
    var onSilenceChanged: ((Bool) -> Void)?
    /// Fires once per session if no audible system audio ever arrived —
    /// the session is mic-only (voice memo, call in headphones).
    var onSystemAudioUnavailable: (() -> Void)?
    /// Fires if the capture dies mid-session so the session can be stopped
    /// cleanly instead of leaving the mic recording into a dead file.
    var onStreamError: ((Error) -> Void)?

    var isPaused = false

    private let audioURL: URL
    /// Whether to narrow the tap to the call app. Re-evaluated while
    /// recording, so an app that joins late still gets picked up.
    private let callAppOnly: Bool

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "autorec.coreaudio-tap", qos: .userInitiated)
    /// Where the CoreAudio setup runs, so a start that blocks blocks nothing
    /// the session needs.
    private let setupQueue = DispatchQueue(label: "autorec.coreaudio-tap.setup")
    private let stateLock = NSLock()
    /// Set when the caller stopped waiting for `start` — the late start then
    /// cleans up after itself.
    private var abandoned = false

    private var isRecording = false

    // --- Written and read on `queue` only ---
    private var audioFile: AVAudioFile?
    private var audioWriteErrorCount = 0
    private let maxAudioWriteErrors = 5
    private var audioFailed = false
    private var audioWarmedUp = false
    private var silenceStart: Date?
    private var isSilent = false

    private let silenceRMSThreshold: Float = 0.001
    private let silenceDurationThreshold: TimeInterval = 90.0
    private let warmupRMSThreshold: Float = 0.0005
    private let warmupTimeout: TimeInterval = 30.0
    /// When the "is this tap actually delivering audio, or just zeroes?" check
    /// runs. Long enough that a normal startup has produced buffers, short
    /// enough that the answer arrives while the call is still worth saving.
    private let silenceProbeDelay: TimeInterval = 12.0

    // --- Diagnostics, read from timers on another thread ---
    private let statsLock = NSLock()
    private var bufferCount = 0
    private var highestPeak: Float = 0
    private var levelMeasurable = true

    private var warmupTimer: DispatchSourceTimer?
    private var probeTimer: DispatchSourceTimer?
    private var refreshTimer: DispatchSourceTimer?

    /// Families this session has ever seen the call app in. Accumulated and
    /// never pruned: a call app that lets go of the mic for a moment, or hands
    /// audio to a helper, must not fall out of the tap mid-sentence.
    private var sessionFamilies: Set<String> = []
    private var tappedObjects: [AudioObjectID] = []
    private(set) var scope: Scope = .everything
    private var refreshFailureLogged = false

    /// `seedFamilies` pre-loads the set of bundle-id families to tap. Nothing
    /// in the app passes it — it is how the capture path can be exercised
    /// against a chosen application without arranging a live call first.
    init(audioURL: URL, callAppOnly: Bool, seedFamilies: [String] = []) {
        self.audioURL = audioURL
        self.callAppOnly = callAppOnly
        self.sessionFamilies = Set(seedFamilies)
    }

    // MARK: - Lifecycle

    /// Start capturing, giving up after `deadline` seconds.
    ///
    /// The deadline is not paranoia. Measured on this machine (macOS 26.2,
    /// 2026-09-20): with the system-audio grant missing,
    /// `AudioDeviceCreateIOProcIDWithBlock` does not fail and does not return
    /// — it blocks the calling thread for around a minute before the HAL gives
    /// up. Without a deadline the whole session would sit in `.starting` that
    /// entire time, recording nothing, with no mic track either. So the setup
    /// runs on its own queue, the caller waits with a deadline, and a start
    /// that finally lands after we have given up tears itself down instead of
    /// leaving a private aggregate device in the user's audio stack.
    func start(deadline: TimeInterval = 8) throws {
        guard !isRecording else { return }
        // Necessary but not sufficient: the tap needs this grant, but having
        // it does not prove the separate system-audio grant is in place. The
        // probe timer covers the rest.
        guard CGPreflightScreenCaptureAccess() else { throw TapError.permissionMissing }

        final class Outcome: @unchecked Sendable { var error: Error? }
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)

        // `self` is captured strongly on purpose: if the caller gives up and
        // drops the recorder, this block is what still has to destroy the tap
        // and the aggregate device once the HAL finally answers.
        setupQueue.async { [self] in
            do { try performStart() } catch { outcome.error = error }

            stateLock.lock()
            let giveUp = abandoned
            stateLock.unlock()
            if giveUp {
                log("[CoreAudioTap] Запоздалый старт завершился — сношу тап, сессию уже пишет другой путь")
                isRecording = false
                teardown()
            }
            done.signal()
        }

        if done.wait(timeout: .now() + deadline) == .timedOut {
            stateLock.lock(); abandoned = true; stateLock.unlock()
            throw TapError.startTimedOut(deadline)
        }
        if let error = outcome.error { throw error }
    }

    private func performStart() throws {
        try? FileManager.default.removeItem(at: audioURL)

        let (description, objects, scope) = buildDescription()
        self.scope = scope
        self.tappedObjects = objects

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr else { throw TapError.tapCreationFailed(status) }
        tapID = newTapID

        do {
            let format = try tapStreamFormat()
            try createAggregateDevice(tapUUID: description.uuid)
            // The file is created up front (not on the first buffer as in the
            // SCStream path) because the tap tells us its format before it
            // starts: a file that cannot be created should fail the start,
            // not fail silently ten seconds into the call.
            audioFile = try makeFile(format: format)
            try installIOProc(format: format)
        } catch {
            cleanup()
            throw error
        }

        isRecording = true
        startTimers()
        log("[CoreAudioTap] Запись начата — \(audioURL.lastPathComponent), "
            + "\(Int(tapFormatSampleRate))Hz, охват: \(scope), процессов: \(objects.count)")
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        teardown()

        let (count, peak) = stats()
        log("[CoreAudioTap] Запись остановлена — буферов: \(count), пиковый уровень: \(String(format: "%.4f", peak))")
    }

    /// Stop the device, close the track and destroy everything CoreAudio is
    /// holding for us. Safe to call twice.
    private func teardown() {
        warmupTimer?.cancel(); warmupTimer = nil
        probeTimer?.cancel(); probeTimer = nil
        refreshTimer?.cancel(); refreshTimer = nil

        if let procID, aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(aggregateID, procID)
        }
        // Close the file on the queue that writes it: releasing it from
        // another thread could race a buffer still in flight, and AVAudioFile
        // patches the CAF header in its deinit — so this also guarantees the
        // track is properly closed before we return.
        queue.sync { self.audioFile = nil }
        cleanup()
    }

    // MARK: - Tap description

    private var tapFormatSampleRate: Double = 0

    /// Build the tap description for the current situation, plus the audio
    /// objects it covers and the scope it ended up meaning.
    ///
    /// An app scope that matches no running process falls back to a global tap
    /// on purpose: recording everything is wrong in a small way, recording
    /// nothing is wrong in the way that loses the call. The refresh tick then
    /// narrows it as soon as the call app shows up.
    private func buildDescription() -> (CATapDescription, [AudioObjectID], Scope) {
        var objects: [AudioObjectID] = []
        var families: [String] = []

        if callAppOnly {
            families = currentCallAppFamilies()
            objects = AudioProcesses.matching(families: families).map(\.object)
            if objects.isEmpty {
                log("[CoreAudioTap] ⚠️ Приложение звонка не опознано — пишу весь звук системы; "
                    + "сузим охват, как только кто-то возьмёт микрофон")
            }
        }

        let description: CATapDescription
        if objects.isEmpty {
            // Exclude ourselves for the same reason SCStream gets
            // `excludesCurrentProcessAudio` — our own sounds are not the call.
            let own = AudioProcesses.ownObject().map { [$0] } ?? []
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: own)
        } else {
            description = CATapDescription(stereoMixdownOfProcesses: objects)
        }
        description.name = "MemorAI system tap"
        // Private: invisible to everyone else, and destroyed with us.
        description.isPrivate = true
        // Unmuted: the user must keep hearing the call they are on.
        description.muteBehavior = .unmuted

        return (description, objects, objects.isEmpty ? .everything : .apps(families))
    }

    /// The bundle-id families of the call app, accumulated over the session.
    ///
    /// Seeded from whoever holds the microphone — the same question
    /// `CallDetector` asks to decide a call is happening, so the two can never
    /// disagree about which app the call belongs to.
    private func currentCallAppFamilies() -> [String] {
        for holder in AudioProcesses.micHolders() {
            if let family = AudioProcesses.family(of: holder) {
                sessionFamilies.insert(family)
            }
        }
        return sessionFamilies.sorted()
    }

    /// Re-point the tap at the app's processes as they come and go — a browser
    /// renderer restarted by a reloaded tab, a helper the call app spawns when
    /// someone shares their screen, a second app joining the call.
    ///
    /// The tap's description is settable, so this touches neither the
    /// aggregate device nor the file: nothing about the recording is
    /// interrupted. If the system refuses, the existing tap keeps running and
    /// we say so once rather than every ten seconds for an hour.
    private func refreshScope() {
        guard isRecording, callAppOnly, tapID != AudioObjectID(kAudioObjectUnknown) else { return }

        let (description, objects, newScope) = buildDescription()
        guard !objects.isEmpty, objects != tappedObjects else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyDescription,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = description
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectSetPropertyData(
                tapID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), pointer)
        }
        guard status == noErr else {
            if !refreshFailureLogged {
                refreshFailureLogged = true
                log("[CoreAudioTap] ⚠️ Не удалось обновить список процессов тапа (OSStatus \(status)) — "
                    + "остаюсь на тех, с которыми стартовал")
            }
            return
        }
        tappedObjects = objects
        scope = newScope
        log("[CoreAudioTap] Охват обновлён: \(newScope), процессов: \(objects.count)")
    }

    // MARK: - CoreAudio setup

    private func tapStreamFormat() throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            throw TapError.tapFormatUnreadable(status)
        }
        tapFormatSampleRate = format.sampleRate
        return format
    }

    private func createAggregateDevice(tapUUID: UUID) throws {
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MemorAI-tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            // Private so it never shows up in the user's sound settings, and
            // so coreaudiod tears it down with us if we are killed.
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [] as [[String: Any]],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &newAggregateID)
        guard status == noErr else { throw TapError.aggregateCreationFailed(status) }
        aggregateID = newAggregateID
    }

    private func makeFile(format: AVAudioFormat) throws -> AVAudioFile {
        do {
            // Same settings as the SCStream path — 16-bit PCM in a CAF. The
            // tap hands us float32; AVAudioFile converts on write.
            return try AVAudioFile(
                forWriting: audioURL,
                settings: AudioFormats.pcmSettings(
                    sampleRate: format.sampleRate, channels: format.channelCount),
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved)
        } catch {
            throw TapError.fileCreationFailed(error)
        }
    }

    private func installIOProc(format: AVAudioFormat) throws {
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) {
            [weak self] _, inInputData, _, _, _ in
            guard let self, self.isRecording else { return }
            // Paused means "write nothing", exactly as the SCStream path does:
            // the track is a record of what was captured, not of wall time.
            guard !self.isPaused, !self.audioFailed, let file = self.audioFile else { return }
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil)
            else { return }
            self.write(buffer, to: file)
        }
        guard status == noErr, let procID else { throw TapError.ioProcCreationFailed(status) }

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw TapError.deviceStartFailed(status) }
    }

    /// Runs on `queue` (the IOProc's queue), so the file and the silence state
    /// need no further synchronisation. Only the diagnostic counters are
    /// locked, because the probe timer reads them from elsewhere.
    private func write(_ buffer: AVAudioPCMBuffer, to file: AVAudioFile) {
        do {
            try file.write(from: buffer)
            audioWriteErrorCount = 0
        } catch {
            audioWriteErrorCount += 1
            log("[CoreAudioTap] ❌ Ошибка записи (\(audioWriteErrorCount)/\(maxAudioWriteErrors)): \(error.localizedDescription)")
            if audioWriteErrorCount >= maxAudioWriteErrors {
                audioFailed = true
                log("[CoreAudioTap] ❌ Слишком много ошибок записи — дорожка системного звука потеряна")
                // Same contract as an SCStream failure: the session stops
                // rather than leaving the mic recording into half a call.
                let error = TapError.fileCreationFailed(error)
                DispatchQueue.main.async { [weak self] in self?.onStreamError?(error) }
            }
            return
        }

        guard let level = Self.level(of: buffer) else {
            statsLock.lock()
            bufferCount += 1
            levelMeasurable = false
            statsLock.unlock()
            return
        }

        statsLock.lock()
        bufferCount += 1
        highestPeak = max(highestPeak, level.peak)
        statsLock.unlock()

        // Warmup suppresses silence detection until the first audible buffer,
        // so the quiet seconds before anyone speaks don't trigger auto-stop.
        if !audioWarmedUp {
            if level.rms >= warmupRMSThreshold {
                audioWarmedUp = true
                log("[CoreAudioTap] Пошёл звук (первый не-тихий буфер)")
            }
            return
        }
        updateSilenceState(rms: level.rms)
    }

    private func updateSilenceState(rms: Float) {
        let now = Date()
        if rms < silenceRMSThreshold {
            if silenceStart == nil { silenceStart = now }
            if !isSilent, let start = silenceStart,
               now.timeIntervalSince(start) >= silenceDurationThreshold {
                isSilent = true
                log("[CoreAudioTap] Тишина дольше \(Int(silenceDurationThreshold))с")
                DispatchQueue.main.async { [weak self] in self?.onSilenceChanged?(true) }
            }
        } else {
            silenceStart = nil
            if isSilent {
                isSilent = false
                log("[CoreAudioTap] Звук возобновился")
                DispatchQueue.main.async { [weak self] in self?.onSilenceChanged?(false) }
            }
        }
    }

    // MARK: - Diagnostics

    private func stats() -> (count: Int, peak: Float) {
        statsLock.lock()
        defer { statsLock.unlock() }
        return (bufferCount, highestPeak)
    }

    private func startTimers() {
        // 1. "Is anything arriving at all, and is any of it non-zero?"
        //
        // This is the failure this path has that the SCStream path does not: a
        // tap can be created, started and never refused, and still hand back
        // exact zeroes forever when the system-audio privacy grant is missing.
        // The file grows at the normal rate the whole time, so nothing short
        // of looking at the samples can tell it from a quiet room — and the
        // user gets an hour of silence with no idea why. So we look.
        probeTimer = schedule(after: silenceProbeDelay) { [weak self] in
            guard let self, self.isRecording else { return }
            let (count, peak) = self.stats()
            if count == 0 {
                // Measured: this is exactly what a missing system-audio grant
                // looks like once the slow start finally returns — the device
                // is "running" and the IOProc is never called.
                log("[CoreAudioTap] ⚠️ За \(Int(self.silenceProbeDelay))с не пришло ни одного буфера — "
                    + "тап запущен, но система не отдаёт звук. Почти наверняка MemorAI не выдано "
                    + "разрешение «Запись экрана и системного звука» (Системные настройки → "
                    + "Конфиденциальность и безопасность). Выдай его и перезапусти MemorAI, "
                    + "либо переключи системный звук обратно на запись экрана в настройках.")
            } else if peak == 0 {
                // Deliberately phrased as two possibilities: a Mac that is
                // genuinely playing nothing also produces exact zeroes, and
                // accusing the permissions every time someone starts recording
                // before the call connects would make the warning worthless.
                log("[CoreAudioTap] ⚠️ Буферы идут (\(count)), но все сэмплы — ровные нули. "
                    + "Либо в системе сейчас ничего не играет, либо MemorAI не выдано разрешение "
                    + "«Запись экрана и системного звука» (Системные настройки → Конфиденциальность "
                    + "и безопасность). Первое лечится звуком, второе — разрешением и перезапуском.")
            }
        }

        // 2. The mic-only signal the rest of the app is built on.
        warmupTimer = schedule(after: warmupTimeout) { [weak self] in
            guard let self, self.isRecording else { return }
            let warmed = self.queue.sync { self.audioWarmedUp }
            guard !warmed else { return }
            log("[CoreAudioTap] Системного звука нет \(Int(self.warmupTimeout))с — считаю сессию mic-only")
            DispatchQueue.main.async { [weak self] in self?.onSystemAudioUnavailable?() }
        }

        // 3. Follow the call app as its processes change.
        guard callAppOnly else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in self?.refreshScope() }
        timer.resume()
        refreshTimer = timer
    }

    private func schedule(after delay: TimeInterval, _ body: @escaping () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler(handler: body)
        timer.resume()
        return timer
    }

    /// Peak and RMS of one tapped buffer. nil when the buffer is not float32 —
    /// we say "can't measure" rather than guess, because a wrong silence
    /// verdict either stops a live call or records an hour of nothing.
    static func level(of buffer: AVAudioPCMBuffer) -> (peak: Float, rms: Float)? {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let channels = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return (0, 0) }

        // Interleaved buffers put every channel behind one pointer; planar
        // ones give a pointer per channel.
        let channelCount = Int(buffer.format.channelCount)
        let planes = buffer.format.isInterleaved ? 1 : channelCount
        let samplesPerPlane = buffer.format.isInterleaved ? frames * channelCount : frames

        var peak: Float = 0
        var sum: Float = 0
        var total = 0
        for plane in 0..<planes {
            let samples = channels[plane]
            for i in 0..<samplesPerPlane {
                let s = samples[i]
                peak = max(peak, abs(s))
                sum += s * s
            }
            total += samplesPerPlane
        }
        guard total > 0 else { return (0, 0) }
        return (peak, sqrtf(sum / Float(total)))
    }

    // MARK: - Teardown

    /// Destroy everything we created, in the order CoreAudio wants it. A
    /// leaked private aggregate device outlives the app and gets in the way of
    /// the user's own audio, so this runs on every exit path, including a
    /// failed start.
    private func cleanup() {
        if let procID, aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        audioFile = nil
    }

    deinit {
        cleanup()
    }
}

import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreVideo

/// Captures system audio and optionally screen via a single SCStream.
/// System audio → .caf file, screen → .mp4 file (if enabled).
///
/// Either half can be switched off. With `audioURL == nil` the stream is
/// created with `capturesAudio = false` and writes video only — that is the
/// shape used when the system track comes from `CoreAudioTapRecorder`
/// instead. The two paths then share nothing: SCStream never opens the
/// `_system.caf` the tap is writing, and the tap never sees a video frame, so
/// there is no way for the same audio to be recorded twice or for two writers
/// to meet on one file.
///
/// The audio track is written as uncompressed PCM through AVAudioFile rather
/// than as AAC through AVAssetWriter, and that is deliberate: an AVAssetWriter
/// .m4a is unreadable until `finishWriting` completes, so a process killed
/// mid-call left nothing at all (1.5.2's SIGABRT). A PCM CAF is readable at
/// every instant — see `AudioFormats`. Video has no such option and stays on
/// AVAssetWriter.
class SystemAudioRecorder: NSObject {
    private var stream: SCStream?

    // Audio track (uncompressed PCM, created lazily from the first buffer's format)
    private var audioFile: AVAudioFile?
    private var audioWriteErrorCount = 0
    private let maxAudioWriteErrors = 5
    /// Set when the audio track has given up. Kept separate from `isRecording`
    /// so a dead audio file doesn't also silently end the screen recording.
    private var audioFailed = false
    /// nil = video-only stream (system audio is being captured elsewhere).
    private let audioURL: URL?

    // Video writer (optional)
    private var videoWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var videoSessionStarted = false
    private var videoFailed = false
    private let videoURL: URL?

    // Capture dimensions (set during start, used for video writer)
    private var captureWidth: Int = 0
    private var captureHeight: Int = 0

    // Keep strong references to queues — SCStream may not retain them
    private var audioQueue: DispatchQueue?
    private var videoQueue: DispatchQueue?

    private var isRecording = false
    /// True from `start()` until `stop()` begins: the files of this session are
    /// ours and a dead stream may still be replaced. A restart that finishes
    /// after `stop()` has begun must not bring a stream back to life.
    private var sessionActive = false
    /// What the first stream was built from, so a restarted one captures the
    /// same display at the same size — the video writer's dimensions are fixed
    /// at its first frame, and a restart must not change them under it.
    private var streamConfig: SCStreamConfiguration?
    private var displayID: CGDirectDisplayID?
    /// When the first stream started capturing: the zero of this track's
    /// timeline, and of the mic's, which starts right after it.
    private var streamStartedAt: Date?

    // --- Timeline across stream restarts ---
    // A restarted stream picks up minutes of wall-clock time later than the
    // last buffer of the dead one. The mic never stopped, so unless the hole
    // is filled the far end slides earlier by the whole outage and every
    // later reply lands against the wrong words. These are touched only on
    // the audio queue.
    /// End of the last buffer written (or skipped by a pause), in the
    /// stream's own clock.
    private var lastAudioEnd: CMTime = .invalid
    /// Wall-clock moment that last buffer was handled.
    private var lastAudioWall: Date?
    /// Set by `restartStream()`: the next buffer is the first of a new stream,
    /// and the gap before it has to be written as silence.
    private var fillGapOnNextBuffer = false
    /// Set when SCStream died on its own instead of being stopped by us. The
    /// stream is gone and `isRecording` is already false, but the video writer
    /// still holds every frame appended so far in an unfinalized mp4 — without
    /// this flag `stop()` returns at its guard and the file is left with no
    /// moov atom, i.e. unreadable. See `didStopWithError`.
    private var needsFinalize = false
    var isPaused = false

    // --- Silence detection ---
    /// Fires when system audio transitions to/from silence.
    /// `true` = silent for silenceDurationThreshold, `false` = audio resumed.
    var onSilenceChanged: ((Bool) -> Void)?
    /// Fires once per session if system audio never produced a non-silent buffer within
    /// warmupTimeout seconds — signals the session is mic-only (voice memo, headphone-only call).
    var onSystemAudioUnavailable: (() -> Void)?
    /// Fires (on main) when SCStream terminates on its own. The files stay
    /// open: the owner decides whether to `restartStream()` into them or to
    /// `stop()` and close them.
    var onStreamError: ((Error) -> Void)?
    private let silenceRMSThreshold: Float = 0.001
    private let silenceDurationThreshold: TimeInterval = 90.0
    private var silenceStart: Date?
    private var isSilent = false

    // --- Warmup: skip initial silent buffers from SCStream startup ---
    private var audioWarmedUp = false
    private let warmupRMSThreshold: Float = 0.0005
    private let warmupTimeout: TimeInterval = 30.0
    private var warmupTimer: DispatchSourceTimer?

    /// If videoURL is nil, only audio is captured (no screen); if audioURL is
    /// nil, only screen (no system audio). Both nil is a stream with nothing
    /// to do — the caller is expected not to create one.
    init(audioURL: URL?, videoURL: URL?) {
        self.audioURL = audioURL
        self.videoURL = videoURL
        super.init()
    }

    func start() async throws {
        guard !isRecording else { return }

        // Reset warmup state for new recording session
        audioWarmedUp = false
        silenceStart = nil
        isSilent = false

        if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
        if let videoURL { try? FileManager.default.removeItem(at: videoURL) }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw RecordingError.noDisplay
        }

        // The audio file is created on the first buffer, from that buffer's own
        // format — SCStream's actual output can differ from what we asked for.
        self.audioFile = nil
        self.audioWriteErrorCount = 0
        self.audioFailed = false

        // --- Determine capture size ---
        // Use 1x display size (not Retina) — sufficient for call recordings
        // and much more reliable for H.264 encoding
        let recordScreen = videoURL != nil
        let recordAudio = audioURL != nil
        // Make sure dimensions are even for H.264
        let capW = display.width & ~1
        let capH = display.height & ~1
        self.captureWidth = capW
        self.captureHeight = capH

        // --- Single SCStream for both audio and video ---
        let config = SCStreamConfiguration()
        config.capturesAudio = recordAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2

        if recordScreen {
            config.width = capW
            config.height = capH
            config.minimumFrameInterval = CMTime(value: 1, timescale: 10) // 10fps is enough for calls
            config.showsCursor = true
            config.pixelFormat = kCVPixelFormatType_32BGRA
        } else {
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        }

        log("[SystemAudioRecorder] Display: \(display.width)x\(display.height) pts, capture: \(capW)x\(capH) px")

        // Video writer is created lazily on first frame to ensure dimensions match
        self.videoFailed = false

        if recordAudio {
            self.audioQueue = DispatchQueue(label: "autorec.audio", qos: .userInitiated)
        }
        if recordScreen {
            self.videoQueue = DispatchQueue(label: "autorec.video", qos: .userInitiated)
        }
        self.streamConfig = config
        self.displayID = display.displayID
        self.lastAudioEnd = .invalid
        self.lastAudioWall = nil
        self.fillGapOnNextBuffer = false
        self.needsFinalize = false

        let stream = try makeStream(display: display, config: config)
        self.stream = stream
        try await stream.startCapture()
        streamStartedAt = Date()
        sessionActive = true
        isRecording = true

        // No audio track, nothing to time out on: the mic-only signal belongs
        // to whoever is actually writing the system track.
        if recordAudio { startWarmupTimer() }

        log("[SystemAudioRecorder] Started — audio: \(audioURL?.lastPathComponent ?? "off"), video: \(videoURL?.lastPathComponent ?? "off")")
    }

    /// A new SCStream over `display`, wired to this recorder's outputs and
    /// queues. The queues outlive any one stream, so buffers of a restarted
    /// stream are written by the same queue that wrote the dead one's.
    private func makeStream(display: SCDisplay, config: SCStreamConfiguration) throws -> SCStream {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        if let audioQueue {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        if let videoQueue {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        }
        return stream
    }

    /// Whether the capture stream is currently delivering (as opposed to dead
    /// and waiting for `restartStream()`).
    var isStreamAlive: Bool { isRecording && stream != nil }

    /// Bring capture back after the system stopped the stream, into the same
    /// files.
    ///
    /// Nothing about the session changes: the audio file stays open and the
    /// gap is written into it as silence when the first new buffer arrives
    /// (see `fillGap`), and the video writer keeps its session — the new
    /// frames simply carry later timestamps, so the outage plays back as the
    /// last frame held still. Throws when the stream cannot be started; the
    /// caller decides whether to try again.
    func restartStream() async throws {
        guard sessionActive, !isStreamAlive, let config = streamConfig else { return }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard sessionActive else { return }
        // The same display if it is still there; the first one otherwise (the
        // config's fixed size scales whatever it is to the writer's size).
        guard let display = content.displays.first(where: { $0.displayID == displayID })
            ?? content.displays.first
        else { throw RecordingError.noDisplay }

        if let audioQueue {
            audioQueue.sync { self.fillGapOnNextBuffer = true }
        }
        let stream = try makeStream(display: display, config: config)
        self.stream = stream
        do {
            try await stream.startCapture()
        } catch {
            if self.stream === stream { self.stream = nil }
            throw error
        }
        guard sessionActive else {
            // `stop()` ran while we were starting — it owns the files now and
            // this stream must not feed them.
            try? await stream.stopCapture()
            if self.stream === stream { self.stream = nil }
            return
        }
        isRecording = true
        log("[SystemAudioRecorder] Stream restarted — дописываю в те же файлы (\(audioURL?.lastPathComponent ?? "без звука"), \(videoURL?.lastPathComponent ?? "без видео"))")
    }

    /// Write the stretch of the call the far-end track missed as silence, so
    /// the track stays as long as the call and aligned with the mic.
    ///
    /// The gap is measured in the stream's own clock when that clock agrees
    /// with the wall clock, and by the wall clock otherwise: SCStream stamps
    /// buffers in host time, but a restarted stream is a new object and a
    /// wrong guess here would shift the rest of the call, so the plainer
    /// number wins whenever the two disagree by more than a moment.
    /// Runs on the audio queue.
    private func fillGap(beforePTS pts: CMTime?, file: AVAudioFile, reason: String) {
        let now = Date()
        var gap: Double
        if let wall = lastAudioWall {
            let wallGap = now.timeIntervalSince(wall)
            gap = wallGap
            if let pts, lastAudioEnd.isValid, pts.isValid {
                let ptsGap = CMTimeSubtract(pts, lastAudioEnd).seconds
                if ptsGap.isFinite, ptsGap >= 0, abs(ptsGap - wallGap) < 2 { gap = ptsGap }
            }
        } else if let started = streamStartedAt {
            // No buffer was ever written: the track starts late by however
            // long it took the stream to come back.
            gap = now.timeIntervalSince(started)
        } else {
            return
        }
        // A few hundredths are ordinary delivery jitter, not an outage.
        guard gap >= 0.05 else { return }
        gap = min(gap, 6 * 3600)

        let format = file.processingFormat
        let rate = format.sampleRate
        var remaining = AVAudioFramePosition(gap * rate)
        let chunk = AVAudioFrameCount(rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return }
        if let channels = buffer.floatChannelData {
            for ch in 0..<Int(format.channelCount) {
                channels[ch].update(repeating: 0, count: Int(chunk))
            }
        }
        do {
            while remaining > 0 {
                buffer.frameLength = AVAudioFrameCount(min(AVAudioFramePosition(chunk), remaining))
                try file.write(from: buffer)
                remaining -= AVAudioFramePosition(buffer.frameLength)
            }
            log(String(format: "[SystemAudioRecorder] Пропуск %.1f с (%@) заполнен тишиной — дорожка идёт вровень с микрофоном", gap, reason))
        } catch {
            log("[SystemAudioRecorder] ❌ Не удалось дописать тишину за пропуск: \(error.localizedDescription)")
        }
        lastAudioWall = now
        if let pts, pts.isValid { lastAudioEnd = pts }
    }

    /// Arm a one-shot timer: if no non-silent audio buffer arrives in `warmupTimeout` seconds,
    /// treat the session as having no system audio (mic-only use case).
    private func startWarmupTimer() {
        warmupTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + warmupTimeout)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isRecording, !self.audioWarmedUp else { return }
            log("[SystemAudioRecorder] No system audio after \(Int(self.warmupTimeout))s — treating session as mic-only")
            DispatchQueue.main.async { [weak self] in
                self?.onSystemAudioUnavailable?()
            }
        }
        timer.resume()
        warmupTimer = timer
    }

    /// Create video writer lazily on the first real frame, so we know the exact pixel dimensions.
    private func setupVideoWriter(from sampleBuffer: CMSampleBuffer) -> Bool {
        guard let videoURL = videoURL else { return false }

        // Get actual frame dimensions from the pixel buffer
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            log("[SystemAudioRecorder] ❌ No pixel buffer in screen frame")
            return false
        }
        let frameW = CVPixelBufferGetWidth(pixelBuffer)
        let frameH = CVPixelBufferGetHeight(pixelBuffer)

        log("[SystemAudioRecorder] First frame: \(frameW)x\(frameH) px")

        do {
            let vWriter = try AVAssetWriter(outputURL: videoURL, fileType: .mp4)

            let vSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: frameW,
                AVVideoHeightKey: frameH,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 600_000,
                    AVVideoMaxKeyFrameIntervalKey: 30,
                ] as [String: Any],
            ]
            let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
            vInput.expectsMediaDataInRealTime = true
            vInput.transform = .identity
            vWriter.add(vInput)

            guard vWriter.startWriting() else {
                log("[SystemAudioRecorder] ❌ Video writer failed to start: \(vWriter.error?.localizedDescription ?? "unknown")")
                return false
            }

            self.videoWriter = vWriter
            self.videoInput = vInput
            self.videoSessionStarted = false
            return true
        } catch {
            log("[SystemAudioRecorder] ❌ Failed to create video writer: \(error)")
            return false
        }
    }

    func stop() async {
        guard isRecording || needsFinalize else { return }
        // Nobody may restart the stream from here on.
        sessionActive = false
        // Dead at the moment the call ends: the far end has been silent since
        // the stream died, and the track has to say so for its full length.
        let endedWhileDead = !isRecording
        isRecording = false
        needsFinalize = false

        warmupTimer?.cancel()
        warmupTimer = nil

        do {
            try await stream?.stopCapture()
        } catch {
            log("[SystemAudioRecorder] stopCapture error: \(error)")
        }
        stream = nil

        // Small delay to let in-flight buffers drain
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Close the audio file on the queue that writes it: releasing it from
        // another thread could race a buffer still in flight, and AVAudioFile
        // patches the CAF header (data chunk size) in its deinit — so this also
        // guarantees the track is properly closed before we return.
        let closeAudio = {
            if endedWhileDead, !self.isPaused, let file = self.audioFile {
                self.fillGap(beforePTS: nil, file: file, reason: "до конца звонка системный звук не вернулся")
            }
            self.audioFile = nil
        }
        if let queue = audioQueue {
            queue.sync(execute: closeAudio)
        } else {
            closeAudio()
        }

        // Finalize video
        if let vInput = videoInput, let vWriter = videoWriter {
            if vWriter.status == .writing {
                vInput.markAsFinished()
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    vWriter.finishWriting {
                        log("[SystemAudioRecorder] Video done — status: \(vWriter.status.rawValue)")
                        cont.resume()
                    }
                }
            } else {
                log("[SystemAudioRecorder] ❌ Video writer not in writing state: \(vWriter.status.rawValue), error: \(vWriter.error?.localizedDescription ?? "none")")
            }
        }
        videoWriter = nil
        videoInput = nil
        audioQueue = nil
        videoQueue = nil

        log("[SystemAudioRecorder] Stopped")
    }
}

extension SystemAudioRecorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard isRecording, CMSampleBufferDataIsReady(sampleBuffer) else { return }

        switch type {
        case .audio:
            guard !audioFailed, let audioURL, let pcm = pcmBuffer(from: sampleBuffer) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let end = CMTimeAdd(pts, CMTime(
                value: CMTimeValue(pcm.frameLength), timescale: CMTimeScale(pcm.format.sampleRate)))

            // A pause takes time out of both tracks on purpose: advance the
            // timeline without writing, so the pause is never mistaken for an
            // outage and "filled" back in.
            if isPaused {
                lastAudioEnd = end
                lastAudioWall = Date()
                fillGapOnNextBuffer = false
                return
            }

            if audioFile == nil {
                do {
                    audioFile = try AVAudioFile(
                        forWriting: audioURL,
                        settings: AudioFormats.pcmSettings(
                            sampleRate: pcm.format.sampleRate, channels: pcm.format.channelCount),
                        commonFormat: .pcmFormatFloat32,
                        interleaved: false
                    )
                    log("[SystemAudioRecorder] Audio format: \(Int(pcm.format.sampleRate))Hz, \(pcm.format.channelCount)ch → PCM \(audioURL.lastPathComponent)")
                } catch {
                    audioWriteErrorCount += 1
                    log("[SystemAudioRecorder] ❌ Failed to create audio file (\(audioWriteErrorCount)/\(maxAudioWriteErrors)): \(error.localizedDescription)")
                    if audioWriteErrorCount >= maxAudioWriteErrors {
                        log("[SystemAudioRecorder] ❌ Too many file errors — audio track is lost for this session")
                        audioFailed = true
                    }
                    return
                }
            }

            if fillGapOnNextBuffer {
                fillGapOnNextBuffer = false
                if let file = audioFile {
                    fillGap(beforePTS: pts, file: file, reason: "поток перезапускался")
                }
            }

            do {
                try audioFile?.write(from: pcm)
                audioWriteErrorCount = 0
                lastAudioEnd = end
                lastAudioWall = Date()
            } catch {
                audioWriteErrorCount += 1
                log("[SystemAudioRecorder] ❌ Audio write error (\(audioWriteErrorCount)/\(maxAudioWriteErrors)): \(error.localizedDescription)")
                if audioWriteErrorCount >= maxAudioWriteErrors {
                    log("[SystemAudioRecorder] ❌ Too many write errors — stopping audio writes")
                    audioFailed = true
                }
                return
            }

            // Warmup suppresses silence detection for the first non-silent buffer, so the
            // ~30s of digital silence SCStream emits at startup doesn't trigger auto-stop.
            // We always write the buffer so the audio track never finalizes empty.
            if !audioWarmedUp {
                let rms = bufferRMS(sampleBuffer)
                if rms >= warmupRMSThreshold {
                    audioWarmedUp = true
                    log("[SystemAudioRecorder] Audio warmed up (first non-silent buffer)")
                }
                return
            }
            updateSilenceState(sampleBuffer)

        case .microphone:
            break // mic is handled by MicRecorder

        case .screen:
            guard !videoFailed, !isPaused else { return }

            // Check frame status
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
            let statusValue = attachments?.first?[.status] as? Int
            let status = statusValue.flatMap { SCFrameStatus(rawValue: $0) }

            if !videoSessionStarted {
                log("[SystemAudioRecorder] Screen frame received — status: \(statusValue ?? -1), hasImageBuffer: \(CMSampleBufferGetImageBuffer(sampleBuffer) != nil)")
            }

            guard status == .complete else { return }

            // Lazy init video writer on first real frame
            if videoWriter == nil {
                if !setupVideoWriter(from: sampleBuffer) {
                    videoFailed = true
                    return
                }
            }

            guard let input = videoInput, input.isReadyForMoreMediaData else { return }

            if !videoSessionStarted {
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                videoWriter?.startSession(atSourceTime: pts)
                videoSessionStarted = true
                log("[SystemAudioRecorder] Video session started")
            }

            if !input.append(sampleBuffer) {
                let err = videoWriter?.error
                log("[SystemAudioRecorder] ❌ Video append failed — writer status: \(videoWriter?.status.rawValue ?? -1), error: \(err?.localizedDescription ?? "unknown"), underlying: \((err as NSError?)?.userInfo ?? [:])")
                videoFailed = true
            }

        @unknown default:
            break
        }
    }

    /// Wrap a CMSampleBuffer's samples in an AVAudioPCMBuffer, in the stream's
    /// own format. Returns nil for a buffer we can't describe or copy, which the
    /// caller treats as "skip this buffer" rather than as a failure — dropping
    /// 10 ms of audio is always better than tearing down a live recording.
    private func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc),
              let format = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard status == noErr else { return nil }
        return buffer
    }

    /// Compute RMS of a CMSampleBuffer containing float32 audio.
    private func bufferRMS(_ sampleBuffer: CMSampleBuffer) -> Float {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return 0 }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        var data = Data(count: length)
        data.withUnsafeMutableBytes { rawBuf in
            guard let ptr = rawBuf.baseAddress else { return }
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: ptr)
        }
        let floatCount = length / MemoryLayout<Float>.size
        guard floatCount > 0 else { return 0 }
        return data.withUnsafeBytes { rawBuf in
            guard let floats = rawBuf.baseAddress?.assumingMemoryBound(to: Float.self) else { return Float(0) }
            var sum: Float = 0
            for i in 0..<floatCount {
                let s = floats[i]
                sum += s * s
            }
            return sqrtf(sum / Float(floatCount))
        }
    }

    /// Track silence duration using RMS.
    private func updateSilenceState(_ sampleBuffer: CMSampleBuffer) {
        let rms = bufferRMS(sampleBuffer)
        let now = Date()
        if rms < silenceRMSThreshold {
            if silenceStart == nil {
                silenceStart = now
            }
            if !isSilent, let start = silenceStart, now.timeIntervalSince(start) >= silenceDurationThreshold {
                isSilent = true
                log("[SystemAudioRecorder] Silence detected (>\(Int(silenceDurationThreshold))s)")
                DispatchQueue.main.async { [weak self] in
                    self?.onSilenceChanged?(true)
                }
            }
        } else {
            silenceStart = nil
            if isSilent {
                isSilent = false
                log("[SystemAudioRecorder] Audio resumed")
                DispatchQueue.main.async { [weak self] in
                    self?.onSilenceChanged?(false)
                }
            }
        }
    }
}

extension SystemAudioRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // A stream we already replaced (or are tearing down) reporting late
        // must not take the live one down with it.
        guard stream === self.stream else {
            log("[SystemAudioRecorder] Old stream reported an error after it was replaced — ignoring: \(error.localizedDescription)")
            return
        }
        log("[SystemAudioRecorder] Stream stopped with error: \(error)")
        isRecording = false
        // The frames already appended are only readable once the writer has
        // written its moov atom, and the audio file's header is patched when it
        // is closed, so the teardown in `stop()` still has to run.
        needsFinalize = true
        // Drop the dead stream here: `stop()` must not spend the session's
        // teardown asking a stream that already stopped itself to stop.
        // The files stay open — the session may restart the stream into them
        // (`restartStream()`); the warmup timer stays armed for the same
        // reason and only fires while a stream is actually delivering.
        self.stream = nil
        DispatchQueue.main.async { [weak self] in
            self?.onStreamError?(error)
        }
    }
}

enum RecordingError: Error, LocalizedError {
    case noDisplay
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display found for screen capture"
        case .writerFailed(let msg): return "Asset writer failed: \(msg)"
        }
    }
}

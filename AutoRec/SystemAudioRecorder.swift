import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreVideo

/// Captures system audio and optionally screen via a single SCStream.
/// System audio → .m4a file, screen → .mp4 file (if enabled).
class SystemAudioRecorder: NSObject {
    private var stream: SCStream?

    // Audio writer
    private var audioWriter: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var audioSessionStarted = false
    private let audioURL: URL

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
    var isPaused = false

    // --- Silence detection ---
    /// Fires when system audio transitions to/from silence.
    /// `true` = silent for silenceDurationThreshold, `false` = audio resumed.
    var onSilenceChanged: ((Bool) -> Void)?
    /// Fires once per session if system audio never produced a non-silent buffer within
    /// warmupTimeout seconds — signals the session is mic-only (voice memo, headphone-only call).
    var onSystemAudioUnavailable: (() -> Void)?
    /// Fires if SCStream terminates with an error so the session can be stopped cleanly
    /// instead of leaving the mic recording into a dead file.
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

    /// If videoURL is nil, only audio is captured (no screen).
    init(audioURL: URL, videoURL: URL?) {
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

        try? FileManager.default.removeItem(at: audioURL)
        if let videoURL { try? FileManager.default.removeItem(at: videoURL) }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw RecordingError.noDisplay
        }

        // --- Audio writer ---
        let aWriter = try AVAssetWriter(outputURL: audioURL, fileType: .m4a)
        let aSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC_HE,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 48000,
        ]
        let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
        aInput.expectsMediaDataInRealTime = true
        aWriter.add(aInput)
        guard aWriter.startWriting() else {
            throw RecordingError.writerFailed(aWriter.error?.localizedDescription ?? "unknown")
        }
        self.audioWriter = aWriter
        self.audioInput = aInput
        self.audioSessionStarted = false

        // --- Determine capture size ---
        // Use 1x display size (not Retina) — sufficient for call recordings
        // and much more reliable for H.264 encoding
        let recordScreen = videoURL != nil
        // Make sure dimensions are even for H.264
        let capW = display.width & ~1
        let capH = display.height & ~1
        self.captureWidth = capW
        self.captureHeight = capH

        // --- Single SCStream for both audio and video ---
        let config = SCStreamConfiguration()
        config.capturesAudio = true
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

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)

        let aQueue = DispatchQueue(label: "autorec.audio", qos: .userInitiated)
        self.audioQueue = aQueue
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: aQueue)

        if recordScreen {
            let vQueue = DispatchQueue(label: "autorec.video", qos: .userInitiated)
            self.videoQueue = vQueue
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: vQueue)
        }

        self.stream = stream
        try await stream.startCapture()
        isRecording = true

        startWarmupTimer()

        log("[SystemAudioRecorder] Started — audio: \(audioURL.lastPathComponent), video: \(videoURL?.lastPathComponent ?? "off")")
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
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: frameW,
                AVVideoHeightKey: frameH,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 2_000_000,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel,
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
        guard isRecording else { return }
        isRecording = false

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

        // Finalize audio
        if let aInput = audioInput, let aWriter = audioWriter {
            if aWriter.status == .writing {
                aInput.markAsFinished()
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    aWriter.finishWriting {
                        log("[SystemAudioRecorder] Audio done — status: \(aWriter.status.rawValue)")
                        cont.resume()
                    }
                }
            } else {
                log("[SystemAudioRecorder] Audio writer not in writing state: \(aWriter.status.rawValue), error: \(aWriter.error?.localizedDescription ?? "none")")
            }
        }
        audioWriter = nil
        audioInput = nil

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
        guard isRecording, !isPaused, CMSampleBufferDataIsReady(sampleBuffer) else { return }

        switch type {
        case .audio:
            guard let input = audioInput, input.isReadyForMoreMediaData else { return }

            if !audioSessionStarted {
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                audioWriter?.startSession(atSourceTime: pts)
                audioSessionStarted = true
                if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
                   let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
                    log("[SystemAudioRecorder] Audio format: \(asbd.pointee.mSampleRate)Hz, \(asbd.pointee.mChannelsPerFrame)ch, \(asbd.pointee.mBitsPerChannel)bit")
                }
            }
            input.append(sampleBuffer)

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
            guard !videoFailed else { return }

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
        log("[SystemAudioRecorder] Stream stopped with error: \(error)")
        isRecording = false
        warmupTimer?.cancel()
        warmupTimer = nil
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

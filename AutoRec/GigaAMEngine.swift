import CTranscribe
import Foundation

/// Offline transcription with GigaAM-v3 — Sber's Russian ASR model — through
/// Handy's transcribe.cpp runtime (the `CTranscribe` binary framework).
/// подход из amanu (MIT, gsamat/amanu): Transcription/GigaAMEngine.swift
///
/// Why this exists next to the perfectly working local Whisper: whisper-large
/// was trained largely on YouTube subtitles, and on Russian audio with pauses
/// in it, it does not stay silent — it emits the boilerplate it learned there
/// ("Продолжение следует…", "Субтитры сделал DimaTorzok"). `Transcriber` strips
/// those with regexes, which is a bandage over the model choice. GigaAM is
/// Russian-only, CTC-decoded, and has no such training data to hallucinate
/// from, so on the owner's main language it treats the cause.
///
/// A singleton because the loaded model is ~260 MB of weights and
/// `Transcriber` calls `transcribe` once per 10-minute segment of a call —
/// reloading it per segment would dominate the runtime. It is freed again via
/// `releaseResources()` when the session finishes.
final class GigaAMEngine: TranscriptionEngine {
    static let shared = GigaAMEngine()

    private init() {
        // ggml chatters at INFO on every model load and every graph build.
        // Keep warnings and errors (they explain a failed decode) and drop the
        // rest, otherwise one call buries the app log.
        transcribe_log_set({ level, message, _ in
            guard let message = message else { return }
            guard level == TRANSCRIBE_LOG_LEVEL_WARN || level == TRANSCRIBE_LOG_LEVEL_ERROR else { return }
            log("[GigaAM/rt] \(String(cString: message).trimmingCharacters(in: .whitespacesAndNewlines))")
        }, nil)
    }

    let kind: TranscriptionEngineKind = .gigaam
    let inputFormat: EngineAudioFormat = .wav16k

    /// GigaAM was trained on utterances of up to about 25 seconds and its
    /// accuracy falls off past that, so audio is decoded in bounded pieces.
    /// 20 s leaves room for the cut to slide to a nearby pause.
    private let chunkSeconds: Double = 20

    /// The runtime forbids concurrent compute on one model, and `Transcriber`
    /// already serializes its work — the lock is here so a stray caller on
    /// another queue cannot corrupt a decode in flight.
    private let lock = NSLock()
    private var session: OpaquePointer?

    var isAvailable: Bool { GigaAMModelStore.shared.isInstalled }
    var unavailableReason: String? { GigaAMModelStore.shared.unavailableReason }

    /// `language` is ignored: this model speaks only Russian, and the runtime
    /// rejects a language hint for families that do not support one.
    func transcribe(audioURL: URL, language: String) -> String? {
        let samples: [Float]
        do {
            samples = try AudioPCM.monoFloatSamples(of: audioURL)
        } catch {
            log("[GigaAM] ❌ \(error.localizedDescription)")
            return nil
        }

        lock.lock()
        defer { lock.unlock() }

        guard let session = openSession() else { return nil }

        let pieces = AudioPCM.chunks(samples, maxSeconds: chunkSeconds)
        var texts: [String] = []
        for (index, piece) in pieces.enumerated() {
            guard !piece.isEmpty else { continue }
            var params = transcribe_run_params()
            transcribe_run_params_init(&params)
            params.language = nil
            let status = Array(piece).withUnsafeBufferPointer {
                transcribe_run(session, $0.baseAddress, Int32($0.count), &params)
            }
            guard status == TRANSCRIBE_OK else {
                log("[GigaAM] ⚠️ chunk \(index + 1)/\(pieces.count) failed: \(Self.message(status))")
                continue
            }
            guard let raw = transcribe_full_text(session) else { continue }
            let text = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { texts.append(text) }
        }

        guard !texts.isEmpty else {
            log("[GigaAM] no speech recognized in \(audioURL.lastPathComponent)")
            return nil
        }
        // One line per chunk: `Transcriber`'s dedup passes work line-wise, and
        // this is the same shape whisper-cli's -otxt output has.
        return texts.joined(separator: "\n") + "\n"
    }

    /// Drop the loaded weights. `Transcriber` calls this once a session's
    /// transcript is written, so an app that records one call a day does not
    /// hold a quarter of a gigabyte for the other 23 hours.
    func releaseResources() {
        lock.lock()
        defer { lock.unlock() }
        guard session != nil else { return }
        transcribe_session_free(session)
        session = nil
        log("[GigaAM] model unloaded")
    }

    // MARK: - Private

    /// Caller must hold `lock`.
    private func openSession() -> OpaquePointer? {
        if let session = session { return session }
        let path = GigaAMModelStore.shared.modelPath
        guard FileManager.default.fileExists(atPath: path) else {
            log("[GigaAM] ❌ model not found at \(path)")
            return nil
        }
        var opened: OpaquePointer?
        // NULL load/session params = library defaults, which pick Metal when
        // it is available and fall back to CPU when it is not.
        let status = path.withCString { transcribe_open($0, nil, nil, &opened) }
        guard status == TRANSCRIBE_OK, let opened = opened else {
            log("[GigaAM] ❌ could not load model: \(Self.message(status))")
            return nil
        }
        session = opened
        log("[GigaAM] model loaded (\(GigaAMModelStore.shared.bytesOnDisk / 1_048_576) МБ)")
        return opened
    }

    private static func message(_ status: transcribe_status) -> String {
        String(cString: transcribe_status_string(Int32(status.rawValue)))
    }
}

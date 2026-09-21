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
        transcribeDetailed(audioURL: audioURL, language: language)?.text
    }

    /// True once the loaded model has told us it can time its segments.
    /// Defaults to true so Settings can promise speaker labels before the
    /// model has ever been opened; a model that turns out not to align is
    /// corrected here on its first load, and said out loud in the log.
    private(set) var providesTimestamps = true

    /// The same decode, keeping the segment times the CTC decoder aligns.
    ///
    /// GigaAM is CTC, so every frame of audio is already assigned to a token —
    /// segment boundaries fall out of the decode rather than being a second
    /// model or a second pass. The runtime reports what it actually produced
    /// via `transcribe_returned_timestamp_kind`, and that (not our hopes) is
    /// what decides whether the transcript gets speaker labels.
    func transcribeDetailed(audioURL: URL, language: String) -> TranscriptionResult? {
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
        var segments: [TranscriptSegment] = []
        // One chunk that came back with words and no times poisons the whole
        // file: a transcript whose middle 20 seconds have no place on the
        // timeline would be attributed against the wrong part of the tracks.
        // A chunk with no words in it is a different thing entirely — see
        // `spoken` below.
        var timed = true
        // Chunks the runtime refused outright. Their words are gone, so the
        // result cannot be called complete even though the rest decoded.
        var failed = 0
        for (index, piece) in pieces.enumerated() {
            guard !piece.isEmpty else { continue }
            // A slice keeps its index in the original array, which is exactly
            // where this chunk starts on the file's clock.
            let chunkOffset = Double(piece.startIndex) / AudioPCM.sampleRate
            var params = transcribe_run_params()
            transcribe_run_params_init(&params)
            params.language = nil
            // `_init` already asks for AUTO — the finest alignment the family
            // can give. Saying so here keeps the intent from being silently
            // lost if the default ever changes.
            params.timestamps = TRANSCRIBE_TIMESTAMPS_AUTO
            let status = Array(piece).withUnsafeBufferPointer {
                transcribe_run(session, $0.baseAddress, Int32($0.count), &params)
            }
            guard status == TRANSCRIBE_OK else {
                log("[GigaAM] ⚠️ chunk \(index + 1)/\(pieces.count) failed: \(Self.message(status))")
                // The words of this chunk are gone, so anything after it would
                // sit on a timeline with a hole in it.
                failed += 1
                timed = false
                continue
            }
            guard let raw = transcribe_full_text(session) else { continue }
            let text = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
            // Twenty seconds of a call where nobody spoke come back as "." —
            // text with not a letter in it. Keeping it would put a line of
            // punctuation in the transcript, and treating its missing times as
            // lost alignment would take the speaker labels off the whole call.
            let spoken = TranscriptText.hasSpeech(text)
            if spoken { texts.append(text) }

            guard timed, spoken else { continue }
            let chunkSegments = Self.segments(of: session, offset: chunkOffset)
            if chunkSegments.isEmpty {
                if providesTimestamps {
                    log("[GigaAM] ⚠️ рантайм не вернул таймкоды для куска \(index + 1)/\(pieces.count) со словами"
                        + " — этот транскрипт будет без меток говорящих")
                }
                timed = false
            } else {
                segments.append(contentsOf: chunkSegments)
            }
        }

        guard !texts.isEmpty else {
            log("[GigaAM] no speech recognized in \(audioURL.lastPathComponent)")
            // Silence is not a failure. Said with an empty *result* rather than
            // nil, the caller keeps the timeline it has built for the rest of
            // the recording; nil means "this piece is lost" and costs it.
            return failed > 0 ? nil : TranscriptionResult(text: "", segments: [])
        }
        // One line per chunk: `Transcriber`'s dedup passes work line-wise, and
        // this is the same shape whisper-cli's -otxt output has.
        let text = texts.joined(separator: "\n") + "\n"
        return TranscriptionResult(text: text, segments: timed && !segments.isEmpty ? segments : nil)
    }

    // MARK: - Timings

    /// SentencePiece marks the start of a word with this, and nothing else does.
    private static let wordMark = "\u{2581}"
    /// Two phrases with more silence than this between them are two turns. A
    /// shorter gap is a breath inside one.
    private static let pauseBreak: TimeInterval = 0.6
    /// After a full stop, much less silence is needed to call it a new phrase.
    private static let sentenceBreak: TimeInterval = 0.25
    /// Nobody talks this long without a pause; if the gaps say otherwise, the
    /// alignment is drifting and a cut is better than one phrase over a minute
    /// of audio that attribution would have to average over.
    private static let maxPhrase: TimeInterval = 15

    /// One row of the runtime's token output, in seconds.
    struct Token {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
    }

    /// Rebuild timed phrases from the run's token rows.
    ///
    /// GigaAM reports TOKEN granularity and nothing coarser — for this family
    /// `transcribe_n_segments` and `transcribe_n_words` are both 0, and all the
    /// alignment lives in the token rows. So the phrases a speaker-labelled
    /// transcript is made of are assembled here: tokens into words (a "▁"
    /// prefix starts a new one), words into phrases (a pause ends one).
    ///
    /// Empty means this run produced no alignment at all, which upstream
    /// answers with a transcript that has no speaker labels.
    private static func segments(of session: OpaquePointer, offset: TimeInterval) -> [TranscriptSegment] {
        guard transcribe_returned_timestamp_kind(session) != TRANSCRIBE_TIMESTAMPS_NONE else { return [] }

        // The coarser rows first: if a future runtime version starts filling
        // them in for this family, they are better than anything we assemble.
        let rows = segmentRows(of: session, offset: offset)
        if !rows.isEmpty { return rows }

        let count = transcribe_n_tokens(session)
        guard count > 0 else { return [] }
        var tokens: [Token] = []
        tokens.reserveCapacity(Int(count))
        for i in 0..<count {
            var row = transcribe_token()
            transcribe_token_init(&row)
            guard transcribe_get_token(session, i, &row) == TRANSCRIBE_OK,
                  let raw = row.text
            else { continue }
            let text = String(cString: raw)
            guard !text.isEmpty else { continue }
            tokens.append(Token(text: text,
                                start: Double(row.t0_ms) / 1000,
                                end: Double(row.t1_ms) / 1000))
        }
        return phrases(from: tokens, offset: offset)
    }

    /// The segment rows, when the runtime fills them in. GigaAM does not today.
    private static func segmentRows(of session: OpaquePointer, offset: TimeInterval) -> [TranscriptSegment] {
        let count = transcribe_n_segments(session)
        guard count > 0 else { return [] }
        var result: [TranscriptSegment] = []
        for i in 0..<count {
            var row = transcribe_segment()
            transcribe_segment_init(&row)
            guard transcribe_get_segment(session, i, &row) == TRANSCRIBE_OK,
                  let raw = row.text
            else { continue }
            let text = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            result.append(TranscriptSegment(
                start: Double(row.t0_ms) / 1000 + offset,
                end: Double(row.t1_ms) / 1000 + offset,
                text: text,
                // 0 means the family did not diarize, which GigaAM does not.
                speaker: row.speaker_id > 0 ? "SPEAKER_\(row.speaker_id)" : nil))
        }
        return result
    }

    /// The assembly itself, over rows the runtime has already handed us — the
    /// same rule without the C API, so it can be reasoned about on its own.
    ///
    /// Punctuation deliberately does not carry time: a CTC decoder emits "?"
    /// on the silence *after* the question, up to a second past the last sound
    /// of it, and letting that stretch the phrase would hand attribution a
    /// window that reaches into the other person's turn.
    static func phrases(from tokens: [Token], offset: TimeInterval) -> [TranscriptSegment] {
        struct Word {
            var text = ""
            var start: TimeInterval?
            var end: TimeInterval?
        }

        var words: [Word] = []
        for token in tokens {
            let isWordStart = token.text.hasPrefix(wordMark)
            let body = token.text.replacingOccurrences(of: wordMark, with: "")
            if isWordStart || words.isEmpty {
                words.append(Word())
            }
            words[words.count - 1].text += body
            guard TranscriptText.hasSpeech(body) else { continue }
            if words[words.count - 1].start == nil { words[words.count - 1].start = token.start }
            words[words.count - 1].end = token.end
        }

        var result: [TranscriptSegment] = []
        var buffer: [String] = []
        var start: TimeInterval?
        var end: TimeInterval?

        func flush() {
            defer {
                buffer = []
                start = nil
                end = nil
            }
            let text = buffer.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let start else { return }
            result.append(TranscriptSegment(start: start + offset,
                                            end: max(end ?? start, start) + offset,
                                            text: text))
        }

        for word in words {
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let wordStart = word.start, let phraseEnd = end, let phraseStart = start {
                let gap = wordStart - phraseEnd
                let endsSentence = buffer.last?.last.map { ".!?…".contains($0) } ?? false
                if gap > pauseBreak
                    || (endsSentence && gap > sentenceBreak)
                    || (word.end ?? wordStart) - phraseStart > maxPhrase {
                    flush()
                }
            }
            buffer.append(text)
            if start == nil { start = word.start }
            if let wordEnd = word.end { end = wordEnd }
        }
        flush()
        return result
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
        noteTimestampCapability(of: opened)
        return opened
    }

    /// Ask the freshly loaded model whether it can align its output, and say so
    /// in the log — the answer is the difference between a transcript with
    /// "Я"/"Собеседник" on every turn and one without, and a person who picked
    /// GigaAM deserves to know which one they are getting.
    ///
    /// Caller must hold `lock`.
    private func noteTimestampCapability(of session: OpaquePointer) {
        guard let model = transcribe_get_model(session) else { return }
        var caps = transcribe_capabilities()
        transcribe_capabilities_init(&caps)
        guard transcribe_model_get_capabilities(model, &caps) == TRANSCRIBE_OK else { return }
        let kind = caps.max_timestamp_kind
        providesTimestamps = kind != TRANSCRIBE_TIMESTAMPS_NONE
        if providesTimestamps {
            log("[GigaAM] выравнивание по времени: \(Self.name(of: kind)) — метки говорящих будут")
        } else {
            log("[GigaAM] ⚠️ модель не даёт таймкодов — транскрипты будут без меток говорящих")
        }
    }

    private static func name(of kind: transcribe_timestamp_kind) -> String {
        switch kind {
        case TRANSCRIBE_TIMESTAMPS_SEGMENT: return "по фразам"
        case TRANSCRIBE_TIMESTAMPS_WORD:    return "по словам"
        case TRANSCRIBE_TIMESTAMPS_TOKEN:   return "по токенам"
        case TRANSCRIBE_TIMESTAMPS_AUTO:    return "auto"
        default:                            return "нет"
        }
    }

    private static func message(_ status: transcribe_status) -> String {
        String(cString: transcribe_status_string(Int32(status.rawValue)))
    }
}

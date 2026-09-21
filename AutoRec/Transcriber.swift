import Foundation

/// Orchestrates transcription of a recording session:
/// merges mic + system audio → a canonical 16 kHz mono WAV → splits into
/// 10-minute segments → hands each segment to the selected `TranscriptionEngine`
/// → assembles, de-duplicates, attributes each phrase to a speaker, and saves
/// the transcript as both readable text and machine-readable JSON.
///
/// The engine (local Whisper, Groq, or Gemini) is chosen in Settings; this class
/// is engine-agnostic and only owns the engine-independent audio pipeline.
///
/// The mix is what the engine hears, and mixing is lossy in exactly the way
/// that matters: two people become one voice. That is why the merged file is
/// only ever the *input* here, and the original two tracks stay open until the
/// transcript has been attributed — see `SpeakerAttribution`.
class Transcriber {
    static let shared = Transcriber()

    private let ffmpegPath: String = Subprocess.resolveTool("ffmpeg", candidates: [
        "/opt/homebrew/bin/ffmpeg", "/opt/local/bin/ffmpeg", "/usr/local/bin/ffmpeg",
    ])

    private let minTrackDuration: Double = 1.0
    private let chunkSec: Double = 600 // 10 minutes per segment

    /// Minimum speech (seconds) that must survive silence-trimming before we bother
    /// transcribing. Near-silent recordings collapse below this and are skipped, so
    /// Whisper never gets a chance to hallucinate subtitle credits onto dead air.
    private let minSpeechDuration: Double = 1.0

    /// ffmpeg filter that strips the dead air at the START and END of a recording —
    /// the pre-connect ringing and post-goodbye silence where Whisper hallucinates
    /// subtitle credits ("Продолжение следует…", "Субтитры сделал … DimaTorzok").
    ///
    /// Deliberately leading/trailing-only at a strict -50 dB (true digital silence):
    /// the mic+system mix has almost no detectable internal silence (one channel
    /// fills the other's gaps), and aggressive internal trimming risks clipping quiet
    /// speech. Mid-call hallucinations on noisy pauses are left to the LLM polisher.
    /// `areverse` flips the stream so the same head-trim also cleans the tail.
    ///
    /// Only the fallback now: it deletes an unknown amount of audio, so after it
    /// the transcript's clock has no known relationship to the tracks and speaker
    /// attribution is impossible. The normal path trims to bounds measured from
    /// the tracks themselves (`SpeakerAttribution.speechBounds`), which does the
    /// same job and says by how much. This filter is what is left when a track
    /// cannot be read by AVFoundation at all.
    private let silenceFilter =
        "silenceremove=start_periods=1:start_duration=0:start_threshold=-50dB:detection=peak,"
        + "areverse,"
        + "silenceremove=start_periods=1:start_duration=0:start_threshold=-50dB:detection=peak,"
        + "areverse"

    /// Serial queue: cloud requests are sequential (rate limits) and local whisper
    /// jobs saturate CPU if run in parallel.
    private let transcriptionQueue = DispatchQueue(label: "com.local.memorai.transcribe", qos: .utility)

    /// Whether the currently-selected engine is ready to transcribe.
    var isAvailable: Bool { TranscriptionEngineFactory.current().isAvailable }

    /// ffmpeg is required for the merge/encode pipeline regardless of engine.
    var ffmpegAvailable: Bool {
        FileManager.default.fileExists(atPath: ffmpegPath) || ffmpegPath == "ffmpeg"
    }

    /// Transcribe a recording session by merging mic + system audio into one file.
    func transcribeSession(micURL: URL?, systemURL: URL?, completion: @escaping () -> Void) {
        transcriptionQueue.async { [self] in
            let engine = TranscriptionEngineFactory.current()
            guard engine.isAvailable else {
                log("[Transcriber] Engine \(engine.kind.rawValue) unavailable (\(engine.unavailableReason ?? "?")) — skipping")
                DispatchQueue.main.async { completion() }
                return
            }
            log("[Transcriber] Using engine: \(engine.kind.displayName)")

            let micDur = trackDuration(micURL)
            let sysDur = trackDuration(systemURL)
            let micOK = micDur >= minTrackDuration
            let sysOK = sysDur >= minTrackDuration
            log("[Transcriber] Track durations — mic: \(Int(micDur))s (ok=\(micOK)), system: \(Int(sysDur))s (ok=\(sysOK))")

            guard micOK || sysOK else {
                log("[Transcriber] Both tracks too short — skipping")
                DispatchQueue.main.async { completion() }
                return
            }

            let refURL = (micOK ? micURL : systemURL)!
            let dir = refURL.deletingLastPathComponent()
            let baseName = refURL.deletingPathExtension().lastPathComponent
            let sessionTag = baseName
                .replacingOccurrences(of: "_mic", with: "")
                .replacingOccurrences(of: "_system", with: "")
                .replacingOccurrences(of: "call_", with: "")
            // "call_<timestamp>" — the name the session's meta.json goes by.
            let tag = baseName
                .replacingOccurrences(of: "_mic", with: "")
                .replacingOccurrences(of: "_system", with: "")
            let transcriptBase = dir.appendingPathComponent("\(tag)_transcript")
            let txtPath = transcriptBase.appendingPathExtension("txt")
            let jsonPath = transcriptBase.appendingPathExtension("json")

            if FileManager.default.fileExists(atPath: txtPath.path) {
                log("[Transcriber] Transcript already exists: \(txtPath.lastPathComponent)")
                DispatchQueue.main.async { completion() }
                return
            }

            // ── Read both tracks once ───────────────────────────────────────────
            // The envelopes pay for themselves twice: they say where the speech
            // starts and ends (the silence trim) and which track was loud under
            // each phrase (the speaker labels).
            let attribution = SpeakerAttribution(
                mic: micOK ? micURL : nil, system: sysOK ? systemURL : nil)
            if attribution == nil {
                log("[Transcriber] ⚠️ дорожки не читаются через AVFoundation — обрезаю тишину фильтром, без меток говорящих")
            }

            // Where the transcript's clock sits inside the tracks. Every segment
            // time the engine returns is relative to the trimmed mix, so this is
            // what turns it back into a position in the original recording.
            var trimStart: TimeInterval = 0
            var trimLength: TimeInterval?
            if let attribution {
                guard let bounds = attribution.speechBounds() else {
                    log("[Transcriber] Ни на одной дорожке нет речи — расшифровывать нечего")
                    DispatchQueue.main.async { completion() }
                    return
                }
                // Never seek past the end of the shorter track: the mix needs
                // both inputs to still have audio at that point.
                let shortest = [micOK ? micDur : nil, sysOK ? sysDur : nil].compactMap { $0 }.min() ?? 0
                trimStart = max(0, min(bounds.start, shortest - minTrackDuration))
                let end = min(bounds.end, max(micDur, sysDur))
                trimLength = max(0, end - trimStart)
                guard (trimLength ?? 0) >= minSpeechDuration else {
                    log(String(format: "[Transcriber] Речи всего %.1f с — пропускаю расшифровку", trimLength ?? 0))
                    DispatchQueue.main.async { completion() }
                    return
                }
                log(String(format: "[Transcriber] Речь с %.1f с по %.1f с записи", trimStart, end))
            }

            // ── Merge → canonical 16 kHz mono WAV ───────────────────────────────
            let mergedWav = dir.appendingPathComponent("\(tag)_merged.wav")
            log("[Transcriber] Preparing audio (\(micOK && sysOK ? "merge mic+system" : (micOK ? "mic only" : "system only")))")

            // `-ss` before each `-i` seeks every input by the same amount, so the
            // two tracks stay in step with each other and with `trimStart`.
            var args = ["-y"]
            if micOK && sysOK {
                if trimLength != nil { args += ["-ss", seconds(trimStart)] }
                args += ["-i", micURL!.path]
                if trimLength != nil { args += ["-ss", seconds(trimStart)] }
                args += ["-i", systemURL!.path]
                if let trimLength { args += ["-t", seconds(trimLength)] }
                let mix = "[0:a]loudnorm=I=-16:TP=-1.5:LRA=11[mic];"
                    + "[1:a]loudnorm=I=-16:TP=-1.5:LRA=11[sys];"
                    + "[mic][sys]amix=inputs=2:duration=longest"
                args += ["-filter_complex", trimLength != nil ? mix + "[a]" : mix + ",\(silenceFilter)[a]",
                         "-map", "[a]"]
            } else {
                let sourceURL = micOK ? micURL! : systemURL!
                if trimLength != nil { args += ["-ss", seconds(trimStart)] }
                args += ["-i", sourceURL.path]
                if let trimLength { args += ["-t", seconds(trimLength)] }
                if trimLength == nil { args += ["-af", silenceFilter] }
            }
            args += ["-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", mergedWav.path]

            let merge = Subprocess.run(ffmpegPath, args: args)
            guard merge.ok else {
                log("[Transcriber] ❌ ffmpeg merge failed (exit \(merge.exitCode)): \(merge.stderr.suffix(500))")
                DispatchQueue.main.async { completion() }
                return
            }

            // ── Bail out on near-silent recordings ──────────────────────────────
            // After silence-trimming, a recording that was just ringing/dead air
            // collapses to ~0 s. Skip it: otherwise Whisper hallucinates subtitle
            // credits onto the nothingness and we save a transcript of pure garbage.
            let duration = trackDuration(mergedWav)
            guard duration >= minSpeechDuration else {
                log("[Transcriber] No speech after silence-trim (\(String(format: "%.1f", duration))s) — skipping transcription")
                try? FileManager.default.removeItem(at: mergedWav)
                DispatchQueue.main.async { completion() }
                return
            }

            // ── Segment → engine ────────────────────────────────────────────────
            let fmt = engine.inputFormat
            var fullTranscript = ""
            // Every timed phrase of the call, on the merged file's clock.
            // Becomes nil the moment one chunk comes back with words it cannot
            // place: a transcript with a ten-minute hole in the middle is worse
            // than an honest unlabelled one.
            var timedSegments: [TranscriptSegment]? = []

            func absorb(_ result: TranscriptionResult?, chunkOffset: Double) {
                guard let result else { return }
                fullTranscript += result.text
                guard let segments = result.segments else {
                    // A stretch where nobody said anything has nothing to time,
                    // and it must not cost the rest of the call its labels —
                    // only words without times mean the alignment is gone.
                    guard TranscriptText.hasSpeech(result.text) else { return }
                    if timedSegments != nil {
                        log("[Transcriber] движок не дал таймкодов для куска со словами — метки говорящих для этой записи отключаю")
                    }
                    timedSegments = nil
                    return
                }
                timedSegments? += segments.map {
                    TranscriptSegment(start: $0.start + chunkOffset, end: $0.end + chunkOffset,
                                      text: $0.text, speaker: $0.speaker)
                }
            }

            if duration <= chunkSec * 1.5 {
                // Whole file in one shot.
                let segURL: URL
                if fmt == .wav16k {
                    segURL = mergedWav // already in the right format
                } else {
                    segURL = dir.appendingPathComponent("_seg_\(sessionTag).\(fmt.fileExtension)")
                    guard makeSegment(from: mergedWav, offset: nil, length: nil, format: fmt, to: segURL) else {
                        log("[Transcriber] ❌ segment encode failed")
                        try? FileManager.default.removeItem(at: mergedWav)
                        DispatchQueue.main.async { completion() }
                        return
                    }
                }
                log("[Transcriber] Transcribing (\(Int(duration))s) via \(engine.kind.rawValue)…")
                absorb(engine.transcribeDetailed(audioURL: segURL, language: SettingsManager.shared.whisperLanguage),
                       chunkOffset: 0)
                if segURL != mergedWav { try? FileManager.default.removeItem(at: segURL) }
            } else {
                let bounds = segmentBounds(of: mergedWav, duration: duration)
                log("[Transcriber] [\(sessionTag)] Transcribing \(bounds.count) chunks (\(Int(duration))s) via \(engine.kind.rawValue)…")
                for (i, bound) in bounds.enumerated() {
                    let offset = bound.offset
                    let segURL = dir.appendingPathComponent("_chunk_\(sessionTag)_\(i).\(fmt.fileExtension)")
                    guard makeSegment(from: mergedWav, offset: offset, length: bound.length, format: fmt, to: segURL) else {
                        log("[Transcriber] [\(sessionTag)] ⚠️ Chunk \(i+1) encode failed, skipping")
                        // A missing chunk is a hole in the timeline; whatever
                        // comes after it would be attributed against the wrong
                        // part of the tracks.
                        timedSegments = nil
                        continue
                    }
                    log("[Transcriber] [\(sessionTag)]   Chunk \(i+1)/\(bounds.count) @ \(Int(offset))s…")
                    let result = engine.transcribeDetailed(
                        audioURL: segURL, language: SettingsManager.shared.whisperLanguage)
                    if result == nil {
                        log("[Transcriber] [\(sessionTag)] ⚠️ Chunk \(i+1) produced no text")
                        timedSegments = nil
                    }
                    // Chunk i starts `offset` seconds into the merged file, so
                    // its segment times need that added back to be comparable.
                    absorb(result, chunkOffset: offset)
                    try? FileManager.default.removeItem(at: segURL)
                }
            }

            // ── Clean, attribute, save ──────────────────────────────────────────
            var attributed: SpeakerAttribution.Attribution?
            var cleanedSegments: [TranscriptSegment]?
            if let timedSegments, !timedSegments.isEmpty {
                // The same hallucination/loop cleanup as the plain path, applied
                // per segment so the timeline survives it, and then the dashes
                // the engine drew where the speaker changed are made into real
                // segment boundaries — one segment can only carry one label.
                cleanedSegments = Self.splitOnDialogueDashes(Self.cleanSegments(timedSegments))
                if let cleanedSegments, !cleanedSegments.isEmpty,
                   let attribution, attribution.hasBothTracks {
                    attributed = attribution.attribute(
                        segments: cleanedSegments, offset: trimStart, reference: mergedWav)
                } else if attribution?.hasBothTracks != true {
                    log("[Transcriber] одна дорожка — таймкоды пишу, метки говорящих нет")
                }
            } else if !engine.providesTimestamps {
                log("[Transcriber] движок \(engine.kind.rawValue) не даёт таймкодов — транскрипт без меток говорящих")
            }

            try? FileManager.default.removeItem(at: mergedWav)

            // All segments are done, so any in-process model weights (GigaAM's
            // ~260 MB) can go back to the OS until the next call.
            engine.releaseResources()

            let plain = Self.cleanText(fullTranscript)
            let body: String
            if let attributed, !attributed.segments.isEmpty {
                body = TranscriptDocument.plainText(attributed.segments, suffixes: attributed.suffixes)
            } else {
                body = plain
            }

            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                log("[Transcriber] ❌ Engine produced no output")
                DispatchQueue.main.async { completion() }
                return
            }

            try? body.write(to: txtPath, atomically: true, encoding: .utf8)
            log("[Transcriber] ✅ Transcript saved: \(txtPath.lastPathComponent)")

            // The JSON is the whole point of the archive: it keeps the engine's
            // exact wording and timings even when the .txt beside it has been
            // through the polisher, which is good for eyes and lossy for
            // analysis. Written whenever there are timings at all — times
            // without sides still beat prose without either.
            var tracks: [String: String] = [:]
            if micOK, let micURL { tracks["mic"] = micURL.lastPathComponent }
            if sysOK, let systemURL { tracks["system"] = systemURL.lastPathComponent }
            if let json = TranscriptDocument.json(
                tag: tag, engine: engine.kind.rawValue,
                language: SettingsManager.shared.whisperLanguage,
                segments: attributed?.segments,
                plainSegments: cleanedSegments,
                suffixes: attributed?.suffixes ?? [:],
                trackOffset: trimStart, tracks: tracks
            ) {
                try? json.write(to: jsonPath, options: .atomic)
                log("[Transcriber] ✅ \(jsonPath.lastPathComponent): \(cleanedSegments?.count ?? 0) сегментов"
                    + (attributed != nil ? ", с метками говорящих" : ", без меток говорящих"))
            } else {
                // A previous run may have left one; it would now describe text
                // that is no longer there.
                try? FileManager.default.removeItem(at: jsonPath)
            }

            // Tell the session what it now has, so anything reading the folder
            // later (the CLI, an AI, a future us) knows without opening files.
            SessionMeta.update(tag: tag, in: dir, with: [
                "speakers": attributed != nil,
                "transcript_json": cleanedSegments != nil ? jsonPath.lastPathComponent : nil,
            ])

            // Polish raw ASR output (capitalization/punctuation/paragraphs) via the
            // Groq LLM. Gemini already returns formatted text, so skip it there.
            let groqKey = SettingsManager.shared.groqApiKey
            if SettingsManager.shared.polishTranscripts, engine.kind != .gemini, !groqKey.isEmpty,
               let raw = try? String(contentsOf: txtPath, encoding: .utf8),
               let polished = TranscriptPolisher.polish(
                   raw, apiKey: groqKey, speakerLabels: attributed != nil) {
                try? polished.write(to: txtPath, atomically: true, encoding: .utf8)
                log("[Transcriber] ✨ Transcript polished (punctuation/paragraphs)")
            }

            DispatchQueue.main.async { completion() }
        }
    }

    /// ffmpeg wants a plain number of seconds; milliseconds are enough and keep
    /// the offset honest (an integer `-ss` would shift the clock by up to a
    /// second, which is several speaker turns' worth of error).
    private func seconds(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    /// Where to cut a long recording into engine-sized segments.
    ///
    /// Cutting every `chunkSec` on the nose rubs a word in half at every
    /// boundary — "…пойдём другим юм." on one side, "..ц Мы будем делать новое
    /// юрлицо…" on the other — and the engine either invents the missing half
    /// or drops it. `AudioPCM.cutPoints` moves each cut into the quietest
    /// moment of the seconds before it: the same rule the engines already use
    /// on the pieces they decode, asked here of the file instead of samples.
    ///
    /// Falls back to even cuts if the file cannot be scanned; a boundary in a
    /// bad place is much better than no transcript.
    private func segmentBounds(of wav: URL, duration: Double) -> [(offset: Double, length: Double)] {
        var points: [TimeInterval]
        do {
            points = try AudioPCM.cutPoints(of: wav, maxSeconds: chunkSec)
        } catch {
            log("[Transcriber] ⚠️ не удалось просмотреть \(wav.lastPathComponent) на паузы"
                + " (\(error.localizedDescription)) — режу ровно по \(Int(chunkSec)) с")
            points = []
        }
        if points.isEmpty {
            points = Array(stride(from: chunkSec, to: duration, by: chunkSec))
        }

        var bounds: [(offset: Double, length: Double)] = []
        var start: Double = 0
        for point in points where point > start + minSpeechDuration && point < duration {
            bounds.append((start, point - start))
            start = point
        }
        bounds.append((start, duration - start))
        return bounds
    }

    /// Extract/encode a segment of `mergedWav` into `format` at `out`.
    /// `offset`/`length` (seconds) select a sub-range; nil = whole file.
    private func makeSegment(from mergedWav: URL, offset: Double?, length: Double?,
                             format: EngineAudioFormat, to out: URL) -> Bool {
        var args = ["-y"]
        // Fractional: the cuts are snapped to a pause and land on a tenth of a
        // second, and rounding one off would shift every timestamp in the
        // chunk — which is several speaker turns' worth of error.
        if let offset = offset { args += ["-ss", seconds(offset)] }
        args += ["-i", mergedWav.path]
        if let length = length { args += ["-t", seconds(length)] }
        args += format.ffmpegEncodeArgs
        args.append(out.path)
        return Subprocess.run(ffmpegPath, args: args).ok
    }

    /// Get media file duration in seconds via ffmpeg. Returns 0 on failure.
    private func trackDuration(_ url: URL?) -> Double {
        guard let url = url, FileManager.default.fileExists(atPath: url.path) else { return 0 }
        // No output file → ffmpeg prints the Duration header and exits immediately
        // (avoids fully decoding long files just to read their length).
        let result = Subprocess.run(ffmpegPath, args: ["-i", url.path], timeout: 15)
        let output = result.stderr
        if let match = try? NSRegularExpression(pattern: #"Duration: (\d+):(\d+):(\d+\.\d+)"#)
                .firstMatch(in: output, range: NSRange(output.startIndex..., in: output)) {
            let h = Double((output as NSString).substring(with: match.range(at: 1))) ?? 0
            let m = Double((output as NSString).substring(with: match.range(at: 2))) ?? 0
            let s = Double((output as NSString).substring(with: match.range(at: 3))) ?? 0
            return h * 3600 + m * 60 + s
        }
        return 0
    }

    // MARK: - Cleanup

    /// Strip known Whisper hallucinations. On silence/music, whisper-large emits
    /// boilerplate learned from YouTube subtitle data — subtitle credits and
    /// "to be continued" stings — that no amount of speech is actually present for.
    /// Deterministic and always-on (unlike the LLM polisher, which is optional and
    /// occasionally keeps a credit embedded mid-sentence), so it's the reliable floor.
    ///
    /// Kept engine-agnostic on purpose: GigaAM has no such training data to
    /// hallucinate from, but Whisper (local and via Groq) is still selectable,
    /// and running these substitutions over clean text costs nothing.
    private static func stripHallucinations(_ text: String) -> String {
        var content = text
        let hallucinationPatterns = [
            #"Продолжение следует[.…\s]*"#,
            #"Субтитры (?:сделал|делал|создавал|подготовил)[^.!?\n]*?DimaTorzok[.!?]*"#,
            #"Субтитры (?:сделал|делал|создавал|подготовил)[^.!?\n]{0,40}[.!?]"#,
            #"(?:Редактор субтитров|Корректор)[^.!?\n]*[.!?]?"#,
            #"DimaTorzok[.!?]*"#,
            #"Спасибо за просмотр[.!…\s]*"#,
            #"Подписывайтесь на канал[^.!?\n]*[.!?]?"#,
        ]
        for pat in hallucinationPatterns {
            if let re = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) {
                content = re.stringByReplacingMatches(
                    in: content, range: NSRange(content.startIndex..., in: content), withTemplate: "")
            }
        }
        // Tidy up the gaps left behind (doubled spaces, space-before-punctuation).
        if let re = try? NSRegularExpression(pattern: #"[ \t]{2,}"#) {
            content = re.stringByReplacingMatches(
                in: content, range: NSRange(content.startIndex..., in: content), withTemplate: " ")
        }

        // Collapse in-line filler loops. LLM engines (Gemini) emit long runs of a
        // backchannel token on filler-heavy audio, e.g. "Угу. Угу. Угу. Угу. …"
        // all on one line — invisible to the line passes. Collapse 3+ consecutive
        // repeats of the same short token to a single one.
        if let re = try? NSRegularExpression(
            pattern: #"(\b[\p{L}\p{N}]{1,15}[.,!?…]*)(?:\s+\1){2,}"#,
            options: [.caseInsensitive]) {
            content = re.stringByReplacingMatches(
                in: content, range: NSRange(content.startIndex..., in: content), withTemplate: "$1")
        }
        return content
    }

    /// Remove hallucination loops from plain text: exact duplicates and
    /// near-duplicate runs, line by line.
    static func cleanText(_ raw: String) -> String {
        let content = stripHallucinations(raw)
        let lines = content.components(separatedBy: "\n")

        // Pass 1: collapse exact consecutive duplicates
        var deduped: [String] = []
        var prevTrimmed: String? = nil
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed != prevTrimmed {
                deduped.append(line)
            }
            prevTrimmed = trimmed
        }

        // Pass 2: collapse near-duplicate runs (same prefix of 15+ chars, 3+ in a row)
        let prefixLen = 15
        var result: [String] = []
        var i = 0
        while i < deduped.count {
            let trimmed = deduped[i].trimmingCharacters(in: .whitespaces)
            if trimmed.count >= prefixLen {
                let prefix = String(trimmed.prefix(prefixLen))
                var runEnd = i + 1
                while runEnd < deduped.count {
                    let nextTrimmed = deduped[runEnd].trimmingCharacters(in: .whitespaces)
                    if nextTrimmed.hasPrefix(prefix) { runEnd += 1 } else { break }
                }
                if runEnd - i >= 3 {
                    result.append(deduped[i])
                    i = runEnd
                    continue
                }
            }
            result.append(deduped[i])
            i += 1
        }

        // Pass 3: one-letter leftovers ("а.", "У.", "."). The decoder emits
        // them on breaths; a line of them is noise in the file a person reads.
        let kept = result.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty || !TranscriptText.isNoise(trimmed)
        }

        let removed = lines.count - kept.count
        if removed > 0 { log("[Transcriber] Dedup: removed \(removed) hallucinated lines") }
        return kept.joined(separator: "\n")
    }

    /// Cut a segment where the engine drew a dialogue dash.
    ///
    /// GigaAM writes "—" where the speaker changes — 9 % of segments on one of
    /// the owner's calls, 17 % on another — so a single segment can read
    /// "С приложении. — Ну да, на сайте и приложении. — Да-да-да." That is
    /// three turns of two people, and a segment can only be given one speaker
    /// label. Splitting it there lets each piece be matched against the track
    /// that was actually loud under it.
    ///
    /// The words inside a segment have no times of their own by this point, so
    /// the segment's time is shared out by how much of the text each piece
    /// holds. Speech rate is even enough over a few seconds for that to land
    /// well within the tenth of a second attribution works at.
    ///
    /// The dash stays with the text that follows it: if both pieces turn out to
    /// be the same speaker after all, the renderer joins them back and the line
    /// reads exactly as it did before — nothing is lost for a dash that merely
    /// punctuated a sentence.
    static func splitOnDialogueDashes(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        var split = 0

        for segment in segments {
            let pieces = dialoguePieces(of: segment.text)
            let total = pieces.reduce(0) { $0 + $1.count }
            guard pieces.count > 1, total > 0 else {
                result.append(segment)
                continue
            }

            let duration = max(0, segment.end - segment.start)
            var consumed: TimeInterval = 0
            var made: [TranscriptSegment] = []
            for piece in pieces {
                let start = segment.start + consumed
                consumed += duration * Double(piece.count) / Double(total)
                let text = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                // A trailing "—" with nothing after it marks a turn whose words
                // landed in the next segment; it is not a phrase of its own.
                guard TranscriptText.hasSpeech(text) else { continue }
                made.append(TranscriptSegment(start: start, end: segment.start + consumed,
                                              text: text, speaker: segment.speaker))
            }

            // Only one piece had words in it — keep the segment as the engine
            // wrote it, dash and all, rather than quietly editing its text.
            guard made.count > 1 else {
                result.append(segment)
                continue
            }
            split += 1
            result.append(contentsOf: made)
        }

        if split > 0 {
            log("[Transcriber] Реплики: по тире разрезано \(split) сегментов"
                + " → \(result.count - segments.count + split)")
        }
        return result
    }

    /// The segment's text, cut before every dash that stands on its own — one
    /// with a space in front of it and a space (or the end of the segment)
    /// behind. That leaves "из-за" and "А-а" alone: those are hyphens inside a
    /// word, and a hyphen is not this dash to begin with.
    private static func dialoguePieces(of text: String) -> [String] {
        let characters = Array(text)
        var pieces: [String] = []
        var start = 0
        for i in characters.indices {
            let character = characters[i]
            guard character == "—" || character == "–" else { continue }
            guard i > start else { continue }  // the piece already starts with one
            guard i == 0 || characters[i - 1].isWhitespace else { continue }
            guard i + 1 == characters.count || characters[i + 1].isWhitespace else { continue }
            pieces.append(String(characters[start..<i]))
            start = i
        }
        pieces.append(String(characters[start...]))
        return pieces
    }

    /// The same cleanup, applied to timed segments instead of lines.
    ///
    /// It has to be the segment and not the rendered text, because the text is
    /// rendered *after* attribution: deleting a line afterwards would leave the
    /// JSON describing phrases the .txt no longer contains, and a hallucinated
    /// segment would first get a speaker label and a timestamp of its own.
    static func cleanSegments(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        // Pass 1: hallucination patterns; a segment that was nothing but a
        // subtitle credit disappears entirely.
        var cleaned: [TranscriptSegment] = []
        for segment in segments {
            var copy = segment
            copy.text = stripHallucinations(segment.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !copy.text.isEmpty else { continue }
            cleaned.append(copy)
        }

        // Pass 2: exact consecutive duplicates. Whisper loops repeat the same
        // phrase for minutes; one of them is the real one.
        var deduped: [TranscriptSegment] = []
        for segment in cleaned {
            if let last = deduped.last, last.text == segment.text {
                // Keep the first occurrence but stretch it over the loop, so the
                // timeline has no gap where the repeats were.
                deduped[deduped.count - 1].end = max(last.end, segment.end)
                continue
            }
            deduped.append(segment)
        }

        // Pass 3: near-duplicate runs (same 15-char prefix, 3+ in a row).
        let prefixLen = 15
        var result: [TranscriptSegment] = []
        var i = 0
        while i < deduped.count {
            let text = deduped[i].text
            if text.count >= prefixLen {
                let prefix = String(text.prefix(prefixLen))
                var runEnd = i + 1
                while runEnd < deduped.count, deduped[runEnd].text.hasPrefix(prefix) { runEnd += 1 }
                if runEnd - i >= 3 {
                    var kept = deduped[i]
                    kept.end = deduped[runEnd - 1].end
                    result.append(kept)
                    i = runEnd
                    continue
                }
            }
            result.append(deduped[i])
            i += 1
        }

        let removed = segments.count - result.count
        if removed > 0 { log("[Transcriber] Dedup: убрано \(removed) зациклившихся сегментов") }
        return result
    }
}

import Foundation

/// Orchestrates transcription of a recording session:
/// merges mic + system audio → a canonical 16 kHz mono WAV → splits into
/// 10-minute segments → hands each segment to the selected `TranscriptionEngine`
/// → assembles, de-duplicates, and saves the transcript.
///
/// The engine (local Whisper, Groq, or Gemini) is chosen in Settings; this class
/// is engine-agnostic and only owns the engine-independent audio pipeline.
class Transcriber {
    static let shared = Transcriber()

    private let ffmpegPath: String = Subprocess.resolveTool("ffmpeg", candidates: [
        "/opt/homebrew/bin/ffmpeg", "/opt/local/bin/ffmpeg", "/usr/local/bin/ffmpeg",
    ])

    private let minTrackDuration: Double = 1.0
    private let chunkSec: Double = 600 // 10 minutes per segment

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
            let transcriptBase = dir.appendingPathComponent(
                baseName.replacingOccurrences(of: "_mic", with: "_transcript")
                        .replacingOccurrences(of: "_system", with: "_transcript")
            )
            let txtPath = transcriptBase.appendingPathExtension("txt")

            if FileManager.default.fileExists(atPath: txtPath.path) {
                log("[Transcriber] Transcript already exists: \(txtPath.lastPathComponent)")
                DispatchQueue.main.async { completion() }
                return
            }

            // ── Merge → canonical 16 kHz mono WAV ───────────────────────────────
            let mergedWav = dir.appendingPathComponent(
                baseName.replacingOccurrences(of: "_mic", with: "_merged")
                        .replacingOccurrences(of: "_system", with: "_merged") + ".wav"
            )
            log("[Transcriber] Preparing audio (\(micOK && sysOK ? "merge mic+system" : (micOK ? "mic only" : "system only")))")
            let merge: Subprocess.Result
            if micOK && sysOK {
                merge = Subprocess.run(ffmpegPath, args: [
                    "-y", "-i", micURL!.path, "-i", systemURL!.path,
                    "-filter_complex",
                    "[0:a]loudnorm=I=-16:TP=-1.5:LRA=11[mic];"
                    + "[1:a]loudnorm=I=-16:TP=-1.5:LRA=11[sys];"
                    + "[mic][sys]amix=inputs=2:duration=longest[a]",
                    "-map", "[a]", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le",
                    mergedWav.path,
                ])
            } else {
                let sourceURL = micOK ? micURL! : systemURL!
                merge = Subprocess.run(ffmpegPath, args: [
                    "-y", "-i", sourceURL.path,
                    "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", mergedWav.path,
                ])
            }
            guard merge.ok else {
                log("[Transcriber] ❌ ffmpeg merge failed (exit \(merge.exitCode)): \(merge.stderr.suffix(500))")
                DispatchQueue.main.async { completion() }
                return
            }

            // ── Segment → engine ────────────────────────────────────────────────
            let duration = trackDuration(mergedWav)
            let fmt = engine.inputFormat
            var fullTranscript = ""

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
                fullTranscript = engine.transcribe(audioURL: segURL, language: SettingsManager.shared.whisperLanguage) ?? ""
                if segURL != mergedWav { try? FileManager.default.removeItem(at: segURL) }
            } else {
                let chunks = Int(ceil(duration / chunkSec))
                log("[Transcriber] [\(sessionTag)] Transcribing \(chunks) chunks (\(Int(duration))s) via \(engine.kind.rawValue)…")
                for i in 0..<chunks {
                    let offset = Double(i) * chunkSec
                    let segURL = dir.appendingPathComponent("_chunk_\(sessionTag)_\(i).\(fmt.fileExtension)")
                    guard makeSegment(from: mergedWav, offset: offset, length: chunkSec, format: fmt, to: segURL) else {
                        log("[Transcriber] [\(sessionTag)] ⚠️ Chunk \(i+1) encode failed, skipping")
                        continue
                    }
                    log("[Transcriber] [\(sessionTag)]   Chunk \(i+1)/\(chunks) @ \(Int(offset))s…")
                    if let text = engine.transcribe(audioURL: segURL, language: SettingsManager.shared.whisperLanguage) {
                        fullTranscript += text
                    } else {
                        log("[Transcriber] [\(sessionTag)] ⚠️ Chunk \(i+1) produced no text")
                    }
                    try? FileManager.default.removeItem(at: segURL)
                }
            }

            try? FileManager.default.removeItem(at: mergedWav)

            if !fullTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try? fullTranscript.write(to: txtPath, atomically: true, encoding: .utf8)
                deduplicateTranscript(at: txtPath)
                log("[Transcriber] ✅ Transcript saved: \(txtPath.lastPathComponent)")

                // Polish raw ASR output (capitalization/punctuation/paragraphs) via the
                // Groq LLM. Gemini already returns formatted text, so skip it there.
                let groqKey = SettingsManager.shared.groqApiKey
                if SettingsManager.shared.polishTranscripts, engine.kind != .gemini, !groqKey.isEmpty,
                   let raw = try? String(contentsOf: txtPath, encoding: .utf8),
                   let polished = TranscriptPolisher.polish(raw, apiKey: groqKey) {
                    try? polished.write(to: txtPath, atomically: true, encoding: .utf8)
                    log("[Transcriber] ✨ Transcript polished (punctuation/paragraphs)")
                }
            } else {
                log("[Transcriber] ❌ Engine produced no output")
            }

            DispatchQueue.main.async { completion() }
        }
    }

    /// Extract/encode a segment of `mergedWav` into `format` at `out`.
    /// `offset`/`length` (seconds) select a sub-range; nil = whole file.
    private func makeSegment(from mergedWav: URL, offset: Double?, length: Double?,
                             format: EngineAudioFormat, to out: URL) -> Bool {
        var args = ["-y"]
        if let offset = offset { args += ["-ss", String(Int(offset))] }
        args += ["-i", mergedWav.path]
        if let length = length { args += ["-t", String(Int(length))] }
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

    /// Remove hallucination loops: exact duplicates and near-duplicate runs.
    private func deduplicateTranscript(at url: URL) {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return }

        // Pass 0: collapse in-line filler loops. LLM engines (Gemini) emit long
        // runs of a backchannel token on filler-heavy audio, e.g.
        // "Угу. Угу. Угу. Угу. …" all on one line — invisible to the line passes.
        // Collapse 3+ consecutive repeats of the same short token to a single one.
        var content = raw
        if let re = try? NSRegularExpression(
            pattern: #"(\b[\p{L}\p{N}]{1,15}[.,!?…]*)(?:\s+\1){2,}"#,
            options: [.caseInsensitive]) {
            content = re.stringByReplacingMatches(
                in: content, range: NSRange(content.startIndex..., in: content), withTemplate: "$1")
        }

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

        let cleaned = result.joined(separator: "\n")
        try? cleaned.write(to: url, atomically: true, encoding: .utf8)
        let removed = lines.count - result.count
        if removed > 0 { log("[Transcriber] Dedup: removed \(removed) hallucinated lines") }
    }
}

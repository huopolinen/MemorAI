import Foundation

/// Transcribes audio files using whisper-cli (whisper.cpp).
/// Converts m4a → wav via ffmpeg, then runs whisper-cli.
class Transcriber {
    static let shared = Transcriber()

    private let whisperPath = "/usr/local/bin/whisper-cli"
    private let ffmpegPath: String = {
        // Try common paths
        for path in ["/opt/local/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg"] {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return "ffmpeg"
    }()

    /// Prefer medium model (better Russian accuracy). Fall back to base if medium is missing.
    private let modelPath: String = {
        let fm = FileManager.default
        let medium = NSString("~/.local/share/whisper-models/ggml-medium.bin").expandingTildeInPath
        let base = NSString("~/.local/share/whisper-models/ggml-base.bin").expandingTildeInPath
        if fm.fileExists(atPath: medium) { return medium }
        return base
    }()

    /// Minimum audio duration (seconds) for a track to be considered usable.
    /// A mic file that only captured the first few seconds (silent failure) must not
    /// be merged with a full system track — that produces garbage output.
    private let minTrackDuration: Double = 30.0

    /// Hard cap for a single whisper/ffmpeg invocation (seconds). Prevents runaway jobs.
    private let processTimeout: TimeInterval = 3600

    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: whisperPath) &&
        FileManager.default.fileExists(atPath: modelPath)
    }

    /// Transcribe a recording session by merging mic + system audio into one file.
    /// Splits into 10-minute chunks to prevent whisper hallucination loops on long recordings.
    func transcribeSession(micURL: URL?, systemURL: URL?, completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .utility).async { [self] in
            guard isAvailable else {
                log("[Transcriber] whisper-cli or model not found (model: \(modelPath))")
                DispatchQueue.main.async { completion() }
                return
            }

            let micDur = trackDuration(micURL)
            let sysDur = trackDuration(systemURL)
            let micOK = micDur >= minTrackDuration
            let sysOK = sysDur >= minTrackDuration

            log("[Transcriber] Track durations — mic: \(Int(micDur))s (ok=\(micOK)), system: \(Int(sysDur))s (ok=\(sysOK))")

            guard micOK || sysOK else {
                log("[Transcriber] Both tracks too short — skipping transcription")
                DispatchQueue.main.async { completion() }
                return
            }

            let refURL = (micOK ? micURL : systemURL)!
            let dir = refURL.deletingLastPathComponent()
            let baseName = refURL.deletingPathExtension().lastPathComponent
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

            let mergedWav = dir.appendingPathComponent(
                baseName.replacingOccurrences(of: "_mic", with: "_merged")
                        .replacingOccurrences(of: "_system", with: "_merged") + ".wav"
            )

            // Merge both tracks only when both are long enough. Otherwise use the usable single track
            // to avoid diluting a good track with a broken one.
            log("[Transcriber] Preparing audio (\(micOK && sysOK ? "merge mic+system" : (micOK ? "mic only" : "system only")))")
            let convertResult: ProcessResult
            if micOK && sysOK {
                convertResult = runProcess(ffmpegPath, args: [
                    "-y",
                    "-i", micURL!.path,
                    "-i", systemURL!.path,
                    "-filter_complex",
                    "[0:a]loudnorm=I=-16:TP=-1.5:LRA=11[mic];"
                    + "[1:a]loudnorm=I=-16:TP=-1.5:LRA=11[sys];"
                    + "[mic][sys]amix=inputs=2:duration=longest[a]",
                    "-map", "[a]",
                    "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le",
                    mergedWav.path
                ])
            } else {
                let sourceURL = micOK ? micURL! : systemURL!
                convertResult = runProcess(ffmpegPath, args: [
                    "-y", "-i", sourceURL.path,
                    "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le",
                    mergedWav.path
                ])
            }

            guard convertResult.exitCode == 0 else {
                log("[Transcriber] ❌ ffmpeg merge failed (exit \(convertResult.exitCode)): \(convertResult.stderr.suffix(500))")
                DispatchQueue.main.async { completion() }
                return
            }

            // Get duration in seconds
            let duration = trackDuration(mergedWav)
            let chunkSec = 600.0 // 10 minutes per chunk
            let lang = SettingsManager.shared.whisperLanguage
            var fullTranscript = ""

            if duration <= chunkSec * 1.5 {
                log("[Transcriber] Transcribing merged audio (\(Int(duration))s, model: \((modelPath as NSString).lastPathComponent))...")
                let tmpBase = dir.appendingPathComponent("_whisper_tmp")
                let result = runProcess(whisperPath, args: [
                    "-m", modelPath, "-l", lang,
                    "-et", "2.2", "-lpt", "-0.5",
                    "-otxt", "-of", tmpBase.path,
                    mergedWav.path
                ])
                if result.exitCode == 0,
                   let text = try? String(contentsOf: tmpBase.appendingPathExtension("txt"), encoding: .utf8) {
                    fullTranscript = text
                } else if result.exitCode != 0 {
                    log("[Transcriber] ❌ Whisper failed (exit \(result.exitCode)): \(result.stderr.suffix(500))")
                }
                try? FileManager.default.removeItem(at: tmpBase.appendingPathExtension("txt"))
            } else {
                let chunks = Int(ceil(duration / chunkSec))
                log("[Transcriber] Transcribing \(chunks) chunks (\(Int(duration))s total, model: \((modelPath as NSString).lastPathComponent))...")

                for i in 0..<chunks {
                    let offset = Double(i) * chunkSec
                    let chunkWav = dir.appendingPathComponent("_chunk_\(i).wav")
                    let chunkBase = dir.appendingPathComponent("_chunk_\(i)")

                    let extractResult = runProcess(ffmpegPath, args: [
                        "-y", "-i", mergedWav.path,
                        "-ss", String(Int(offset)), "-t", String(Int(chunkSec)),
                        "-c:a", "pcm_s16le", chunkWav.path
                    ])
                    guard extractResult.exitCode == 0 else {
                        log("[Transcriber] ⚠️ Chunk \(i+1) extraction failed, skipping")
                        continue
                    }

                    log("[Transcriber]   Chunk \(i+1)/\(chunks) @ \(Int(offset))s…")
                    let result = runProcess(whisperPath, args: [
                        "-m", modelPath, "-l", lang,
                        "-et", "2.2", "-lpt", "-0.5",
                        "-otxt", "-of", chunkBase.path,
                        chunkWav.path
                    ])

                    if result.exitCode == 0,
                       let text = try? String(contentsOf: chunkBase.appendingPathExtension("txt"), encoding: .utf8) {
                        fullTranscript += text
                    } else {
                        log("[Transcriber] ⚠️ Chunk \(i+1) whisper failed (exit \(result.exitCode))")
                    }

                    try? FileManager.default.removeItem(at: chunkWav)
                    try? FileManager.default.removeItem(at: chunkBase.appendingPathExtension("txt"))
                }
            }

            try? FileManager.default.removeItem(at: mergedWav)

            if !fullTranscript.isEmpty {
                try? fullTranscript.write(to: txtPath, atomically: true, encoding: .utf8)
                deduplicateTranscript(at: txtPath)
                log("[Transcriber] ✅ Transcript saved: \(txtPath.lastPathComponent)")
            } else {
                log("[Transcriber] ❌ Whisper produced no output")
            }

            DispatchQueue.main.async { completion() }
        }
    }

    /// Get media file duration in seconds via ffmpeg. Returns 0 on failure or missing file.
    private func trackDuration(_ url: URL?) -> Double {
        guard let url = url, FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let result = runProcess(ffmpegPath, args: ["-i", url.path, "-f", "null", "-"], timeout: 10)
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
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
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
                    if nextTrimmed.hasPrefix(prefix) {
                        runEnd += 1
                    } else {
                        break
                    }
                }
                let runLen = runEnd - i
                if runLen >= 3 {
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
        if removed > 0 {
            log("[Transcriber] Dedup: removed \(removed) hallucinated lines")
        }
    }

    private struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// Run a subprocess with an optional timeout. On timeout the process is terminated
    /// and exit code -2 is returned.
    private func runProcess(_ path: String, args: [String], timeout: TimeInterval? = nil) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ProcessResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }

        let deadline = timeout ?? processTimeout
        var timedOut = false
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + deadline)
        timer.setEventHandler {
            if process.isRunning {
                timedOut = true
                process.terminate()
            }
        }
        timer.resume()

        process.waitUntilExit()
        timer.cancel()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let exitCode: Int32 = timedOut ? -2 : process.terminationStatus
        if timedOut {
            log("[Transcriber] ⏱ Process timed out after \(Int(deadline))s: \((path as NSString).lastPathComponent)")
        }
        return ProcessResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }
}

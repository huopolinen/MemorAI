import Foundation

/// Transcribes audio files using whisper-cli (whisper.cpp).
/// Converts m4a → wav via ffmpeg, then runs whisper-cli.
class Transcriber {
    static let shared = Transcriber()

    private let ffmpegPath: String = {
        for path in ["/opt/homebrew/bin/ffmpeg", "/opt/local/bin/ffmpeg", "/usr/local/bin/ffmpeg"] {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return "ffmpeg"
    }()

    private static let whisperCandidates = [
        "/opt/homebrew/bin/whisper-cli",  // Apple Silicon Homebrew
        "/usr/local/bin/whisper-cli",     // Intel Homebrew
        "/opt/local/bin/whisper-cli",     // MacPorts
    ]

    static let defaultModelDir = NSString("~/.local/share/whisper-models").expandingTildeInPath

    /// Resolved whisper-cli path (user override or auto-detected). Nil if not found.
    var resolvedWhisperPath: String? {
        let custom = SettingsManager.shared.whisperPath
        if !custom.isEmpty {
            return FileManager.default.fileExists(atPath: custom) ? custom : nil
        }
        return Self.whisperCandidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Resolved model file path. May point to a file that doesn't exist yet (for download target).
    var resolvedModelPath: String {
        let custom = SettingsManager.shared.modelPath
        if !custom.isEmpty { return custom }
        let fm = FileManager.default
        let medium = (Self.defaultModelDir as NSString).appendingPathComponent("ggml-medium.bin")
        let base = (Self.defaultModelDir as NSString).appendingPathComponent("ggml-base.bin")
        if fm.fileExists(atPath: medium) { return medium }
        return base
    }

    private let minTrackDuration: Double = 1.0
    private let processTimeout: TimeInterval = 3600

    var isAvailable: Bool {
        guard let wp = resolvedWhisperPath else { return false }
        return FileManager.default.fileExists(atPath: wp) &&
               FileManager.default.fileExists(atPath: resolvedModelPath)
    }

    /// Transcribe a recording session by merging mic + system audio into one file.
    /// Splits into 10-minute chunks to prevent whisper hallucination loops on long recordings.
    func transcribeSession(micURL: URL?, systemURL: URL?, completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .utility).async { [self] in
            guard isAvailable, let wp = resolvedWhisperPath else {
                log("[Transcriber] whisper-cli or model not found — skipping (whisper: \(resolvedWhisperPath ?? "not found"), model: \(resolvedModelPath))")
                DispatchQueue.main.async { completion() }
                return
            }
            let whisperExec = wp
            let modelFile = resolvedModelPath

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
                log("[Transcriber] Transcribing merged audio (\(Int(duration))s, model: \((modelFile as NSString).lastPathComponent))...")
                let tmpBase = dir.appendingPathComponent("_whisper_tmp")
                let result = runProcess(whisperExec, args: [
                    "-m", modelFile, "-l", lang,
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
                log("[Transcriber] Transcribing \(chunks) chunks (\(Int(duration))s total, model: \((modelFile as NSString).lastPathComponent))...")

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
                    let result = runProcess(whisperExec, args: [
                        "-m", modelFile, "-l", lang,
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

    // MARK: - Model Download

    func downloadBaseModel(progress: @escaping (Double) -> Void, completion: @escaping (Error?) -> Void) {
        let urlString = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin"
        guard let url = URL(string: urlString) else { return }

        let destDir = Self.defaultModelDir
        let destPath = (destDir as NSString).appendingPathComponent("ggml-base.bin")
        try? FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)

        let delegate = DownloadDelegate(destPath: destPath, progress: progress, completion: completion)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: .main)
        activeDownloadDelegate = delegate
        session.downloadTask(with: url).resume()
    }

    private var activeDownloadDelegate: DownloadDelegate?

    private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
        private let destPath: String
        private let progressHandler: (Double) -> Void
        private let completionHandler: (Error?) -> Void

        init(destPath: String, progress: @escaping (Double) -> Void, completion: @escaping (Error?) -> Void) {
            self.destPath = destPath
            self.progressHandler = progress
            self.completionHandler = completion
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite total: Int64) {
            let fraction = total > 0 ? Double(totalBytesWritten) / Double(total) : 0
            DispatchQueue.main.async { self.progressHandler(fraction) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            do {
                let dest = URL(fileURLWithPath: destPath)
                if FileManager.default.fileExists(atPath: destPath) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: location, to: dest)
                DispatchQueue.main.async { self.completionHandler(nil) }
            } catch {
                DispatchQueue.main.async { self.completionHandler(error) }
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error = error {
                DispatchQueue.main.async { self.completionHandler(error) }
            }
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

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
    private let modelPath = NSString("~/.local/share/whisper-models/ggml-base.bin").expandingTildeInPath

    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: whisperPath) &&
        FileManager.default.fileExists(atPath: modelPath)
    }

    /// Transcribe an audio file. Returns the path to the transcript .txt file, or nil on failure.
    func transcribe(audioURL: URL, completion: @escaping (URL?) -> Void) {
        DispatchQueue.global(qos: .utility).async { [self] in
            guard isAvailable else {
                print("[Transcriber] whisper-cli or model not found")
                completion(nil)
                return
            }

            let baseName = audioURL.deletingPathExtension().lastPathComponent
            let dir = audioURL.deletingLastPathComponent()
            let wavURL = dir.appendingPathComponent(baseName + ".wav")
            let transcriptBase = dir.appendingPathComponent(
                baseName.replacingOccurrences(of: "_mic", with: "_transcript")
                        .replacingOccurrences(of: "_system", with: "_transcript")
            )

            // Skip if transcript already exists
            let txtPath = transcriptBase.appendingPathExtension("txt")
            if FileManager.default.fileExists(atPath: txtPath.path) {
                print("[Transcriber] Transcript already exists: \(txtPath.lastPathComponent)")
                completion(txtPath)
                return
            }

            // Step 1: Convert m4a → wav (16kHz mono, required by whisper)
            print("[Transcriber] Converting to WAV: \(audioURL.lastPathComponent)")
            let convertResult = runProcess(
                ffmpegPath,
                args: ["-y", "-i", audioURL.path, "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wavURL.path]
            )
            guard convertResult.exitCode == 0 else {
                print("[Transcriber] ffmpeg failed: \(convertResult.stderr)")
                completion(nil)
                return
            }

            // Step 2: Run whisper-cli
            print("[Transcriber] Transcribing: \(wavURL.lastPathComponent)")
            let lang = SettingsManager.shared.whisperLanguage
            let whisperResult = runProcess(
                whisperPath,
                args: [
                    "-m", modelPath,
                    "-l", lang,
                    "-et", "2.2",
                    "-lpt", "-0.5",
                    "-otxt",
                    "-of", transcriptBase.path,
                    wavURL.path
                ]
            )

            // Clean up temp wav
            try? FileManager.default.removeItem(at: wavURL)

            if whisperResult.exitCode == 0 && FileManager.default.fileExists(atPath: txtPath.path) {
                print("[Transcriber] ✅ Transcript saved: \(txtPath.lastPathComponent)")
                completion(txtPath)
            } else {
                print("[Transcriber] ❌ Whisper failed: \(whisperResult.stderr)")
                completion(nil)
            }
        }
    }

    /// Transcribe a recording session by merging mic + system audio into one file.
    /// Splits into 10-minute chunks to prevent whisper hallucination loops on long recordings.
    func transcribeSession(micURL: URL?, systemURL: URL?, completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .utility).async { [self] in
            guard isAvailable else {
                print("[Transcriber] whisper-cli or model not found")
                DispatchQueue.main.async { completion() }
                return
            }

            let micOK = hasContent(micURL)
            let sysOK = hasContent(systemURL)

            guard micOK || sysOK else {
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
                print("[Transcriber] Transcript already exists: \(txtPath.lastPathComponent)")
                DispatchQueue.main.async { completion() }
                return
            }

            let mergedWav = dir.appendingPathComponent(
                baseName.replacingOccurrences(of: "_mic", with: "_merged")
                        .replacingOccurrences(of: "_system", with: "_merged") + ".wav"
            )

            // Merge mic + system → mono 16kHz wav
            // Normalize both sources to same loudness before mixing, and trim initial silence
            // from SCStream startup delay (~30s of digital silence on system audio)
            print("[Transcriber] Merging audio tracks...")
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
                print("[Transcriber] ffmpeg merge failed: \(convertResult.stderr)")
                DispatchQueue.main.async { completion() }
                return
            }

            // Get duration in seconds
            let duration = Self.wavDuration(mergedWav, ffmpegPath: ffmpegPath)
            let chunkSec = 600.0 // 10 minutes per chunk
            let lang = SettingsManager.shared.whisperLanguage
            var fullTranscript = ""

            if duration <= chunkSec * 1.5 {
                // Short enough — transcribe in one go
                print("[Transcriber] Transcribing merged audio (\(Int(duration))s)...")
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
                }
                try? FileManager.default.removeItem(at: tmpBase.appendingPathExtension("txt"))
            } else {
                // Split into chunks to prevent hallucination loops
                let chunks = Int(ceil(duration / chunkSec))
                print("[Transcriber] Transcribing \(chunks) chunks (\(Int(duration))s total)...")

                for i in 0..<chunks {
                    let offset = Double(i) * chunkSec
                    let chunkWav = dir.appendingPathComponent("_chunk_\(i).wav")
                    let chunkBase = dir.appendingPathComponent("_chunk_\(i)")

                    // Extract chunk
                    let extractResult = runProcess(ffmpegPath, args: [
                        "-y", "-i", mergedWav.path,
                        "-ss", String(Int(offset)), "-t", String(Int(chunkSec)),
                        "-c:a", "pcm_s16le", chunkWav.path
                    ])
                    guard extractResult.exitCode == 0 else { continue }

                    // Transcribe chunk
                    print("[Transcriber]   Chunk \(i+1)/\(chunks) @ \(Int(offset))s...")
                    let result = runProcess(whisperPath, args: [
                        "-m", modelPath, "-l", lang,
                        "-et", "2.2", "-lpt", "-0.5",
                        "-otxt", "-of", chunkBase.path,
                        chunkWav.path
                    ])

                    if result.exitCode == 0,
                       let text = try? String(contentsOf: chunkBase.appendingPathExtension("txt"), encoding: .utf8) {
                        fullTranscript += text
                    }

                    // Clean up chunk files
                    try? FileManager.default.removeItem(at: chunkWav)
                    try? FileManager.default.removeItem(at: chunkBase.appendingPathExtension("txt"))
                }
            }

            // Clean up merged wav
            try? FileManager.default.removeItem(at: mergedWav)

            // Write and deduplicate
            if !fullTranscript.isEmpty {
                try? fullTranscript.write(to: txtPath, atomically: true, encoding: .utf8)
                deduplicateTranscript(at: txtPath)
                print("[Transcriber] ✅ Transcript saved: \(txtPath.lastPathComponent)")
            } else {
                print("[Transcriber] ❌ Whisper produced no output")
            }

            DispatchQueue.main.async { completion() }
        }
    }

    /// Get wav file duration in seconds via ffprobe/ffmpeg.
    private static func wavDuration(_ url: URL, ffmpegPath: String) -> Double {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpegPath)
        proc.arguments = ["-i", url.path, "-f", "null", "-"]
        let pipe = Pipe()
        proc.standardError = pipe
        proc.standardOutput = Pipe()
        try? proc.run()
        proc.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // Parse "Duration: HH:MM:SS.xx"
        if let range = output.range(of: #"Duration: (\d+):(\d+):(\d+\.\d+)"#, options: .regularExpression),
           let match = try? NSRegularExpression(pattern: #"Duration: (\d+):(\d+):(\d+\.\d+)"#)
                .firstMatch(in: output, range: NSRange(output.startIndex..., in: output)) {
            let h = Double((output as NSString).substring(with: match.range(at: 1))) ?? 0
            let m = Double((output as NSString).substring(with: match.range(at: 2))) ?? 0
            let s = Double((output as NSString).substring(with: match.range(at: 3))) ?? 0
            return h * 3600 + m * 60 + s
        }
        return 0
    }

    private func hasContent(_ url: URL?) -> Bool {
        guard let url = url, FileManager.default.fileExists(atPath: url.path) else { return false }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? UInt64 ?? 0) > 1000
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
                    // Hallucination run — keep only the first line
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
            print("[Transcriber] Dedup: removed \(removed) hallucinated lines")
        }
    }

    private struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private func runProcess(_ path: String, args: [String]) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ProcessResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}

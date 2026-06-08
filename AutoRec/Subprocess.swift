import Foundation

/// Shared helper for running command-line tools (ffmpeg, whisper-cli, …).
/// Extracted so both `Transcriber` and the transcription engines share one
/// timeout-aware process runner instead of duplicating it.
enum Subprocess {
    struct Result {
        let exitCode: Int32
        let stdout: String
        let stderr: String
        var ok: Bool { exitCode == 0 }
    }

    /// Run `path` with `args`. On timeout the process is terminated and exit
    /// code -2 is returned; on launch failure, -1.
    @discardableResult
    static func run(_ path: String, args: [String], timeout: TimeInterval = 3600) -> Result {
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
            return Result(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }

        var timedOut = false
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler {
            if process.isRunning {
                timedOut = true
                process.terminate()
            }
        }
        timer.resume()

        // Drain pipes on background queues to avoid deadlock when output exceeds
        // the OS pipe buffer while we block in waitUntilExit().
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let drainQueue = DispatchQueue(label: "com.local.memorai.subprocess.drain", attributes: .concurrent)
        group.enter()
        drainQueue.async { outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        drainQueue.async { errData = stderrPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        process.waitUntilExit()
        timer.cancel()
        group.wait()

        let exitCode: Int32 = timedOut ? -2 : process.terminationStatus
        if timedOut {
            log("[Subprocess] ⏱ Timed out after \(Int(timeout))s: \((path as NSString).lastPathComponent)")
        }
        return Result(
            exitCode: exitCode,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    /// First existing path among common Homebrew/MacPorts locations for `tool`,
    /// falling back to the bare name (resolved via PATH at exec time).
    static func resolveTool(_ tool: String, candidates: [String]) -> String {
        candidates.first { FileManager.default.fileExists(atPath: $0) } ?? tool
    }
}

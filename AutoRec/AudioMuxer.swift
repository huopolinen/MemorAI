import Foundation

/// Replaces the video-only screen.mp4 in-place with a copy that has both mic and
/// system audio mixed in. Originals (mic.m4a, system.m4a) are left untouched —
/// Transcriber consumes them after, and they're useful for re-mixing later.
class AudioMuxer {
    static let shared = AudioMuxer()

    private let ffmpegPath: String = {
        for path in ["/opt/homebrew/bin/ffmpeg", "/opt/local/bin/ffmpeg", "/usr/local/bin/ffmpeg"] {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return "ffmpeg"
    }()

    private let queue = DispatchQueue(label: "com.local.memorai.audiomux", qos: .utility)

    func muxScreenWithAudio(screenURL: URL, micURL: URL?, systemURL: URL?, completion: (() -> Void)? = nil) {
        queue.async { [self] in
            mux(screenURL: screenURL, micURL: micURL, systemURL: systemURL)
            completion?()
        }
    }

    private func mux(screenURL: URL, micURL: URL?, systemURL: URL?) {
        guard FileManager.default.fileExists(atPath: screenURL.path) else {
            log("[AudioMuxer] Screen file missing — skipping")
            return
        }

        let micExists = micURL.flatMap { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let sysExists = systemURL.flatMap { FileManager.default.fileExists(atPath: $0.path) } ?? false
        guard micExists || sysExists else {
            log("[AudioMuxer] No audio sources — skipping screen mux")
            return
        }

        let tempURL = screenURL.deletingPathExtension().appendingPathExtension("muxing.mp4")
        try? FileManager.default.removeItem(at: tempURL)

        // Input order: 0 = video (no audio), 1+ = audio sources in the order added.
        var args: [String] = ["-y", "-i", screenURL.path]
        if micExists { args.append(contentsOf: ["-i", micURL!.path]) }
        if sysExists { args.append(contentsOf: ["-i", systemURL!.path]) }

        let micIdx = 1
        let sysIdx = micExists ? 2 : 1
        let audioMap: String
        if micExists && sysExists {
            args.append(contentsOf: [
                "-filter_complex",
                "[\(micIdx):a][\(sysIdx):a]amix=inputs=2:duration=longest:dropout_transition=0[a]"
            ])
            audioMap = "[a]"
        } else if micExists {
            audioMap = "\(micIdx):a"
        } else {
            audioMap = "\(sysIdx):a"
        }

        args.append(contentsOf: [
            "-map", "0:v",
            "-map", audioMap,
            "-c:v", "copy",
            "-c:a", "aac",
            "-b:a", "128k",
            tempURL.path,
        ])

        let sources = [micExists ? "mic" : nil, sysExists ? "system" : nil]
            .compactMap { $0 }.joined(separator: "+")
        log("[AudioMuxer] Muxing \(sources) → \(screenURL.lastPathComponent)")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: ffmpegPath)
        task.arguments = args
        let errPipe = Pipe()
        task.standardOutput = Pipe()
        task.standardError = errPipe

        do {
            try task.run()
        } catch {
            log("[AudioMuxer] ❌ ffmpeg launch failed: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: tempURL)
            return
        }
        task.waitUntilExit()

        guard task.terminationStatus == 0 else {
            let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
            let errMsg = String(data: errData.suffix(400), encoding: .utf8) ?? ""
            log("[AudioMuxer] ❌ ffmpeg failed (exit \(task.terminationStatus)): \(errMsg)")
            try? FileManager.default.removeItem(at: tempURL)
            return
        }

        do {
            _ = try FileManager.default.replaceItemAt(screenURL, withItemAt: tempURL)
            log("[AudioMuxer] ✅ Audio muxed into \(screenURL.lastPathComponent)")
        } catch {
            log("[AudioMuxer] ❌ Replace failed: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: tempURL)
        }
    }
}

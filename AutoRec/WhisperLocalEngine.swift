import Foundation

/// Offline transcription via whisper.cpp's `whisper-cli`.
/// Also owns whisper binary/model resolution and model downloads, shared with
/// `WhisperSetupWindowController`.
final class WhisperLocalEngine: TranscriptionEngine {
    static let shared = WhisperLocalEngine()
    private init() {}

    let kind: TranscriptionEngineKind = .whisperLocal
    let inputFormat: EngineAudioFormat = .wav16k

    private static let whisperCandidates = [
        "/opt/homebrew/bin/whisper-cli",  // Apple Silicon Homebrew
        "/usr/local/bin/whisper-cli",     // Intel Homebrew
        "/opt/local/bin/whisper-cli",     // MacPorts
    ]

    static let defaultModelDir = NSString("~/.local/share/whisper-models").expandingTildeInPath

    /// Downloadable models, best quality first.
    static let downloadableModels: [(name: String, sizeLabel: String)] = [
        ("ggml-medium.bin", "~1.5 GB"),
        ("ggml-base.bin", "~150 MB"),
    ]

    /// Resolved whisper-cli path (user override or auto-detected). Nil if not found.
    var resolvedWhisperPath: String? {
        let custom = SettingsManager.shared.whisperPath
        if !custom.isEmpty {
            return FileManager.default.fileExists(atPath: custom) ? custom : nil
        }
        return Self.whisperCandidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Resolved model file path. May point to a not-yet-downloaded file.
    var resolvedModelPath: String {
        let custom = SettingsManager.shared.modelPath
        if !custom.isEmpty { return custom }
        let fm = FileManager.default
        let medium = (Self.defaultModelDir as NSString).appendingPathComponent("ggml-medium.bin")
        let base = (Self.defaultModelDir as NSString).appendingPathComponent("ggml-base.bin")
        if fm.fileExists(atPath: medium) { return medium }
        return base
    }

    var isAvailable: Bool {
        guard let wp = resolvedWhisperPath else { return false }
        return FileManager.default.fileExists(atPath: wp) &&
               FileManager.default.fileExists(atPath: resolvedModelPath)
    }

    var unavailableReason: String? {
        if resolvedWhisperPath == nil { return "whisper-cpp не установлен" }
        if !FileManager.default.fileExists(atPath: resolvedModelPath) { return "модель не найдена" }
        return nil
    }

    func transcribe(audioURL: URL, language: String) -> String? {
        guard let whisperExec = resolvedWhisperPath else {
            log("[WhisperLocal] whisper-cli not found")
            return nil
        }
        let modelFile = resolvedModelPath
        let lang = TranscriptionLanguage.isoCode(for: language) ?? "auto"
        let outBase = audioURL.deletingPathExtension().appendingPathExtension("whisperout")

        let result = Subprocess.run(whisperExec, args: [
            "-m", modelFile, "-l", lang,
            "-et", "2.2", "-lpt", "-0.5",
            "-otxt", "-of", outBase.path,
            audioURL.path,
        ])

        let txtURL = outBase.appendingPathExtension("txt")
        defer { try? FileManager.default.removeItem(at: txtURL) }

        guard result.ok else {
            log("[WhisperLocal] ❌ whisper-cli failed (exit \(result.exitCode)): \(result.stderr.suffix(400))")
            return nil
        }
        return try? String(contentsOf: txtURL, encoding: .utf8)
    }

    // MARK: - Model download

    private var activeDownloadDelegate: DownloadDelegate?

    /// Download a whisper ggml model into `defaultModelDir`.
    func downloadModel(named modelName: String,
                       progress: @escaping (Double) -> Void,
                       completion: @escaping (Error?) -> Void) {
        let urlString = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(modelName)"
        guard let url = URL(string: urlString) else {
            completion(NSError(domain: "WhisperLocal", code: 1,
                               userInfo: [NSLocalizedDescriptionKey: "Bad model URL"]))
            return
        }

        let destDir = Self.defaultModelDir
        let destPath = (destDir as NSString).appendingPathComponent(modelName)
        try? FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)

        let delegate = DownloadDelegate(destPath: destPath, progress: progress, completion: { [weak self] err in
            self?.activeDownloadDelegate = nil
            completion(err)
        })
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: .main)
        activeDownloadDelegate = delegate
        session.downloadTask(with: url).resume()
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
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
}

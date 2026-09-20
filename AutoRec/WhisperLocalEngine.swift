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

    /// Keeps the in-flight transfer alive; the shared downloader owns the rest.
    private var activeDownload: ModelDownloader.Handle?

    /// Download a whisper ggml model into `defaultModelDir`.
    ///
    /// No integrity manifest here on purpose: these come from the `main` ref of
    /// the whisper.cpp repo, so a pinned size/hash would start failing the day
    /// upstream republishes a model. GigaAM, pinned to one revision, does check.
    func downloadModel(named modelName: String,
                       progress: @escaping (Double) -> Void,
                       completion: @escaping (Error?) -> Void) {
        let urlString = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(modelName)"
        guard let url = URL(string: urlString) else {
            completion(NSError(domain: "WhisperLocal", code: 1,
                               userInfo: [NSLocalizedDescriptionKey: "Bad model URL"]))
            return
        }
        let destPath = (Self.defaultModelDir as NSString).appendingPathComponent(modelName)
        activeDownload = ModelDownloader.download(
            from: url, to: destPath,
            progress: progress,
            completion: { [weak self] error in
                self?.activeDownload = nil
                completion(error)
            })
    }
}

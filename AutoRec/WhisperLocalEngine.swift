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
        transcribeDetailed(audioURL: audioURL, language: language)?.text
    }

    /// whisper.cpp knows exactly when it heard each phrase; `-oj` writes it out
    /// next to the text. We ask for both files: the JSON carries the timings
    /// speaker labels are built on, and the .txt is the fallback if a future
    /// whisper.cpp changes the JSON shape under us — losing the labels is
    /// acceptable, losing the transcript is not.
    func transcribeDetailed(audioURL: URL, language: String) -> TranscriptionResult? {
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
            "-otxt", "-oj", "-of", outBase.path,
            audioURL.path,
        ])

        let txtURL = outBase.appendingPathExtension("txt")
        let jsonURL = outBase.appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: txtURL)
            try? FileManager.default.removeItem(at: jsonURL)
        }

        guard result.ok else {
            log("[WhisperLocal] ❌ whisper-cli failed (exit \(result.exitCode)): \(result.stderr.suffix(400))")
            return nil
        }

        if let segments = Self.segments(fromJSONAt: jsonURL), !segments.isEmpty {
            let text = segments.map(\.text).joined(separator: "\n")
            return TranscriptionResult(text: text, segments: segments)
        }
        log("[WhisperLocal] ⚠️ JSON без сегментов — беру текст, метки говорящих в этом куске не будет")
        guard let text = try? String(contentsOf: txtURL, encoding: .utf8) else { return nil }
        return TranscriptionResult(text: text, segments: nil)
    }

    /// `transcription[].offsets` is milliseconds from the start of the file
    /// handed to whisper — see the `-oj` output format.
    private static func segments(fromJSONAt url: URL) -> [TranscriptSegment]? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["transcription"] as? [[String: Any]]
        else { return nil }

        return items.compactMap { item -> TranscriptSegment? in
            guard let offsets = item["offsets"] as? [String: Any],
                  let from = (offsets["from"] as? NSNumber)?.doubleValue,
                  let to = (offsets["to"] as? NSNumber)?.doubleValue,
                  let text = item["text"] as? String
            else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return TranscriptSegment(start: from / 1000, end: to / 1000, text: trimmed)
        }
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

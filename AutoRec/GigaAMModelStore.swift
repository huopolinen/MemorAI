import Foundation

/// Where the GigaAM-v3 GGUF lives on disk, and how it gets there.
/// подход из amanu (MIT, gsamat/amanu): Transcription/GigaAMModelStore.swift
///
/// The download URL is pinned to one Hugging Face revision rather than to
/// `main`: the model's weights are the thing that decides what the transcripts
/// look like, so "which file did this Mac actually get" has to be answerable
/// months later. The pin also makes the size/SHA-256 check meaningful.
final class GigaAMModelStore {
    static let shared = GigaAMModelStore()
    private init() {}

    /// Sits next to `~/.local/share/whisper-models`, so both local engines keep
    /// their weights in one predictable place a person can find and delete.
    static let defaultModelDir = NSString("~/.local/share/gigaam-models").expandingTildeInPath

    static let fileName = "gigaam-v3-e2e-ctc-Q8_0.gguf"

    /// Q8_0 is what Handy ships by default: it keeps the CTC decoder fast while
    /// preserving punctuation and Cyrillic casing, at 260 MB instead of ~950 MB
    /// for the F16 weights.
    private static let revision = "075dff81f843cf23d22b4ce943ffdc4dd8650cd7"

    static let downloadURL = URL(string:
        "https://huggingface.co/handy-computer/gigaam-v3-e2e-ctc-gguf/resolve/"
        + "\(revision)/\(fileName)?download=true")!

    static let integrity = ModelDownloader.Integrity(
        expectedBytes: 272_151_136,
        sha256: "9ccce4750dc813a493d96ca15ee251712bedec15ac9a02fa3d2bd732f08ae5eb")

    /// Human-readable download size for buttons and alerts.
    static let sizeLabel = "~260 МБ"

    /// Resolved model path — the user's override, or the default cache.
    var modelPath: String {
        let custom = SettingsManager.shared.gigaamModelPath
        if !custom.isEmpty { return custom }
        return (Self.defaultModelDir as NSString).appendingPathComponent(Self.fileName)
    }

    /// Present and plausibly complete. Deliberately a size check and not a
    /// SHA-256: this is read on every menu redraw and settings refresh, and
    /// hashing 260 MB there would stall the UI. The full check runs once, right
    /// after the download, where being slow costs nothing.
    var isInstalled: Bool {
        let path = modelPath
        guard FileManager.default.fileExists(atPath: path) else { return false }
        // A user-chosen file may legitimately be a different quantization, so
        // only the managed copy is held to the manifest's size.
        guard SettingsManager.shared.gigaamModelPath.isEmpty else { return true }
        return bytesOnDisk == Self.integrity.expectedBytes
    }

    var bytesOnDisk: Int64 {
        (try? URL(fileURLWithPath: modelPath)
            .resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    /// Nil when ready; otherwise a sentence that says what to do about it.
    var unavailableReason: String? {
        guard !isInstalled else { return nil }
        if FileManager.default.fileExists(atPath: modelPath) {
            return "модель GigaAM скачана не полностью — скачай заново (\(Self.sizeLabel))"
        }
        return "модель GigaAM не скачана (\(Self.sizeLabel))"
    }

    // MARK: - Download

    private var activeDownload: ModelDownloader.Handle?

    /// Fetch the model into the managed cache directory, verifying size and
    /// SHA-256 before it takes its final name.
    func download(progress: @escaping (Double) -> Void,
                  completion: @escaping (Error?) -> Void) {
        let destPath = (Self.defaultModelDir as NSString).appendingPathComponent(Self.fileName)
        activeDownload = ModelDownloader.download(
            from: Self.downloadURL,
            to: destPath,
            integrity: Self.integrity,
            progress: progress,
            completion: { [weak self] error in
                self?.activeDownload = nil
                if let error = error {
                    log("[GigaAM] ❌ model download failed: \(error.localizedDescription)")
                } else {
                    log("[GigaAM] ✅ model ready: \(destPath)")
                }
                completion(error)
            })
    }

    func cancelDownload() {
        activeDownload?.cancel()
        activeDownload = nil
    }

    /// Remove the managed copy. Never touches a user-supplied path — that file
    /// is not ours to delete.
    func deleteManagedModel() throws {
        let managed = (Self.defaultModelDir as NSString).appendingPathComponent(Self.fileName)
        guard FileManager.default.fileExists(atPath: managed) else { return }
        try FileManager.default.removeItem(atPath: managed)
    }
}

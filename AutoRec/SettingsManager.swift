import Foundation

class SettingsManager {
    static let shared = SettingsManager()

    private let defaults = UserDefaults.standard

    // MARK: - Call Recording

    var outputPath: String {
        get {
            defaults.string(forKey: "outputPath")
                ?? NSString("~/Downloads/MemorAI").expandingTildeInPath
        }
        set { defaults.set(newValue, forKey: "outputPath") }
    }

    var autoDetect: Bool {
        get {
            if defaults.object(forKey: "autoDetect") == nil { return true }
            return defaults.bool(forKey: "autoDetect")
        }
        set { defaults.set(newValue, forKey: "autoDetect") }
    }

    var recordScreen: Bool {
        get {
            if defaults.object(forKey: "recordScreen") == nil { return true }
            return defaults.bool(forKey: "recordScreen")
        }
        set { defaults.set(newValue, forKey: "recordScreen") }
    }

    var autoTranscribe: Bool {
        get {
            if defaults.object(forKey: "autoTranscribe") == nil { return true }
            return defaults.bool(forKey: "autoTranscribe")
        }
        set { defaults.set(newValue, forKey: "autoTranscribe") }
    }

    /// Whisper language code: "ru", "en", "auto", etc. Default "ru".
    var whisperLanguage: String {
        get { defaults.string(forKey: "whisperLanguage") ?? "ru" }
        set { defaults.set(newValue, forKey: "whisperLanguage") }
    }

    // MARK: - Screen Memory

    var screenMemoryEnabled: Bool {
        get {
            if defaults.object(forKey: "screenMemoryEnabled") == nil { return true }
            return defaults.bool(forKey: "screenMemoryEnabled")
        }
        set { defaults.set(newValue, forKey: "screenMemoryEnabled") }
    }

    var saveClipboard: Bool {
        get {
            if defaults.object(forKey: "saveClipboard") == nil { return true }
            return defaults.bool(forKey: "saveClipboard")
        }
        set { defaults.set(newValue, forKey: "saveClipboard") }
    }

    var captureInterval: TimeInterval {
        get {
            let val = defaults.double(forKey: "captureInterval")
            return val > 0 ? val : 3
        }
        set { defaults.set(newValue, forKey: "captureInterval") }
    }

    var excludedBundleIds: [String] {
        get { defaults.stringArray(forKey: "excludedBundleIds") ?? [] }
        set { defaults.set(newValue, forKey: "excludedBundleIds") }
    }

    // MARK: - Helpers

    func ensureOutputDirectory() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: outputPath) {
            try? fm.createDirectory(atPath: outputPath, withIntermediateDirectories: true)
        }
    }
}

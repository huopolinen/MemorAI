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
            if defaults.object(forKey: "screenMemoryEnabled") == nil { return false }
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

    /// HEIF/JPEG compression quality for saved screenshots (0.1–1.0).
    var screenshotQuality: Double {
        get {
            let val = defaults.double(forKey: "screenshotQuality")
            return val > 0 ? val : 0.5
        }
        set { defaults.set(min(max(newValue, 0.1), 1.0), forKey: "screenshotQuality") }
    }

    /// dHash Hamming-distance threshold above which a new screenshot is considered
    /// "changed enough" to save. Lower = more screenshots (more sensitive).
    var screenshotChangeThreshold: Int {
        get {
            if defaults.object(forKey: "screenshotChangeThreshold") == nil { return 10 }
            return defaults.integer(forKey: "screenshotChangeThreshold")
        }
        set { defaults.set(newValue, forKey: "screenshotChangeThreshold") }
    }

    var excludedBundleIds: [String] {
        get { defaults.stringArray(forKey: "excludedBundleIds") ?? [] }
        set { defaults.set(newValue, forKey: "excludedBundleIds") }
    }

    // MARK: - Transcription Engine

    /// Selected transcription backend. See `TranscriptionEngineKind`.
    var transcriptionEngine: String {
        get { defaults.string(forKey: "transcriptionEngine") ?? "whisper_local" }
        set { defaults.set(newValue, forKey: "transcriptionEngine") }
    }

    /// Groq API key (console.groq.com). Used by the Groq engine.
    var groqApiKey: String {
        get { defaults.string(forKey: "groqApiKey") ?? "" }
        set { defaults.set(newValue, forKey: "groqApiKey") }
    }

    /// Google Gemini API key (aistudio.google.com). Used by the Gemini engine.
    var geminiApiKey: String {
        get { defaults.string(forKey: "geminiApiKey") ?? "" }
        set { defaults.set(newValue, forKey: "geminiApiKey") }
    }

    /// Gemini model id. Editable so newer free models can be used without a rebuild.
    var geminiModel: String {
        get {
            let m = defaults.string(forKey: "geminiModel") ?? ""
            return m.isEmpty ? "gemini-2.5-flash" : m
        }
        set { defaults.set(newValue, forKey: "geminiModel") }
    }

    /// Post-process raw ASR transcripts (Whisper/Groq) into punctuated, paragraphed
    /// text via the Groq LLM. Requires a Groq key; no-op without one or for Gemini.
    var polishTranscripts: Bool {
        get {
            if defaults.object(forKey: "polishTranscripts") == nil { return true }
            return defaults.bool(forKey: "polishTranscripts")
        }
        set { defaults.set(newValue, forKey: "polishTranscripts") }
    }

    // MARK: - Whisper (local engine)

    /// Custom whisper-cli binary path override. Empty = auto-detect from common locations.
    var whisperPath: String {
        get { defaults.string(forKey: "whisperPath") ?? "" }
        set { defaults.set(newValue, forKey: "whisperPath") }
    }

    /// Custom Whisper model file path override. Empty = use default ~/.local/share/whisper-models/.
    var modelPath: String {
        get { defaults.string(forKey: "modelPath") ?? "" }
        set { defaults.set(newValue, forKey: "modelPath") }
    }

    // MARK: - Helpers

    func ensureOutputDirectory() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: outputPath) {
            try? fm.createDirectory(atPath: outputPath, withIntermediateDirectories: true)
        }
    }
}

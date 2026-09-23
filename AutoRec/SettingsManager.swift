import Foundation

/// How the far end of a call is captured.
enum SystemAudioSource: String, CaseIterable {
    /// ScreenCaptureKit — everything the Mac plays. The original path.
    case screenCapture = "screen_capture"
    /// Core Audio process tap — can be pointed at the call app alone.
    case coreAudioTap = "core_audio_tap"

    var displayName: String {
        switch self {
        case .screenCapture: return "Через запись экрана (как раньше)"
        case .coreAudioTap: return "Через Core Audio (только звук звонка)"
        }
    }
}

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

    /// Where the system track comes from. Default is the ScreenCaptureKit
    /// path, which is the one that has been recording calls all along — the
    /// Core Audio tap is offered next to it, not in place of it.
    var systemAudioSource: SystemAudioSource {
        get { SystemAudioSource(rawValue: defaults.string(forKey: "systemAudioSource") ?? "") ?? .screenCapture }
        set { defaults.set(newValue.rawValue, forKey: "systemAudioSource") }
    }

    /// Core Audio path only: narrow the tap to the app the call is on instead
    /// of recording everything the Mac plays. This is the reason that path
    /// exists, so it is on by default — but it is a switch, because a call in
    /// an app we fail to recognise is better recorded indiscriminately than
    /// not at all.
    var tapCallAppOnly: Bool {
        get {
            if defaults.object(forKey: "tapCallAppOnly") == nil { return true }
            return defaults.bool(forKey: "tapCallAppOnly")
        }
        set { defaults.set(newValue, forKey: "tapCallAppOnly") }
    }

    var autoTranscribe: Bool {
        get {
            if defaults.object(forKey: "autoTranscribe") == nil { return true }
            return defaults.bool(forKey: "autoTranscribe")
        }
        set { defaults.set(newValue, forKey: "autoTranscribe") }
    }

    /// Apple's echo cancellation (voice processing) on the mic track.
    ///
    /// Off by default, and that is not timidity: enabling it switches the
    /// microphone into Apple's duplex call mode, which can duck or break up
    /// what the *other* side hears — recording a call must never degrade the
    /// call itself. On, the mic track stops recording whatever the speakers are
    /// playing, which is worth it for people on speakers rather than headphones.
    var micVoiceProcessing: Bool {
        get {
            if defaults.object(forKey: "micVoiceProcessing") == nil { return false }
            return defaults.bool(forKey: "micVoiceProcessing")
        }
        set { defaults.set(newValue, forKey: "micVoiceProcessing") }
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

    /// Extra dictation tools whose use of the microphone is not a call, on
    /// top of the built-in list in `AudioProcesses` (Claude Code, Claude
    /// Desktop, macOS dictation, Siri). Each entry is a bundle-id prefix, an
    /// exact process name or a fragment of the executable path. No UI:
    /// `defaults write <bundle id> extraDictationApps -array "…"`.
    var extraDictationApps: [String] {
        get { defaults.stringArray(forKey: "extraDictationApps") ?? [] }
        set { defaults.set(newValue, forKey: "extraDictationApps") }
    }

    // MARK: - Transcription Engine

    /// Selected transcription backend. See `TranscriptionEngineKind`.
    var transcriptionEngine: String {
        get {
            if let stored = defaults.string(forKey: "transcriptionEngine") { return stored }
            // Nobody has chosen yet. A Mac that already has whisper-cli and a
            // model keeps using them — switching it to GigaAM would silently
            // break a working install behind a 260 MB download. Everyone else
            // starts on GigaAM: one click, no Homebrew, and a far better model
            // for the Russian calls this app is mostly used for.
            return WhisperLocalEngine.shared.isAvailable ? "whisper_local" : "gigaam"
        }
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

    // MARK: - GigaAM (local Russian engine)

    /// Custom GigaAM GGUF path override. Empty = the managed copy in
    /// ~/.local/share/gigaam-models/. Set it to use a different quantization
    /// than the one the app downloads.
    var gigaamModelPath: String {
        get { defaults.string(forKey: "gigaamModelPath") ?? "" }
        set { defaults.set(newValue, forKey: "gigaamModelPath") }
    }

    // MARK: - Helpers

    func ensureOutputDirectory() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: outputPath) {
            try? fm.createDirectory(atPath: outputPath, withIntermediateDirectories: true)
        }
    }
}

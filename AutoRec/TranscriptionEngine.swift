import Foundation

/// The selectable transcription backends.
enum TranscriptionEngineKind: String, CaseIterable {
    case whisperLocal = "whisper_local"
    case groq = "groq"
    case gemini = "gemini"

    var displayName: String {
        switch self {
        case .whisperLocal: return "Локальный Whisper (офлайн)"
        case .groq: return "Groq — Whisper large-v3 (быстро, надёжно, рекомендуется)"
        case .gemini: return "Google Gemini (разметка по спикерам; free-tier нестабилен)"
        }
    }

    /// Short label for the status-bar menu.
    var shortName: String {
        switch self {
        case .whisperLocal: return "Whisper"
        case .groq: return "Groq"
        case .gemini: return "Gemini"
        }
    }

    /// Whether this engine needs an internet connection / API key.
    var isCloud: Bool { self != .whisperLocal }
}

/// Audio container an engine wants each prepared segment in.
enum EngineAudioFormat {
    case wav16k   // 16 kHz mono PCM — what whisper.cpp expects
    case flac     // compact lossless — small enough for cloud upload limits

    var fileExtension: String { self == .wav16k ? "wav" : "flac" }

    /// ffmpeg codec/args to produce this format (always 16 kHz mono).
    var ffmpegEncodeArgs: [String] {
        switch self {
        case .wav16k: return ["-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le"]
        case .flac:   return ["-ar", "16000", "-ac", "1", "-c:a", "flac", "-compression_level", "8"]
        }
    }
}

/// Transcribes a single prepared audio segment. Called on `Transcriber`'s
/// background serial queue, so implementations may block (e.g. synchronous
/// network requests) without freezing the UI.
protocol TranscriptionEngine {
    var kind: TranscriptionEngineKind { get }

    /// Format the orchestrator should hand each segment to this engine in.
    var inputFormat: EngineAudioFormat { get }

    /// True when the engine is configured well enough to attempt transcription.
    var isAvailable: Bool { get }

    /// Short reason the engine can't run (for menus/alerts). Nil when available.
    var unavailableReason: String? { get }

    /// Transcribe one audio file. Returns text, or nil on failure (already logged).
    /// `language` is an ISO-639-1 code ("ru", "en") or "auto".
    func transcribe(audioURL: URL, language: String) -> String?
}

enum TranscriptionEngineFactory {
    /// Engine selected in Settings.
    static func current() -> TranscriptionEngine {
        let raw = SettingsManager.shared.transcriptionEngine
        let kind = TranscriptionEngineKind(rawValue: raw) ?? .whisperLocal
        return engine(for: kind)
    }

    static func engine(for kind: TranscriptionEngineKind) -> TranscriptionEngine {
        switch kind {
        case .whisperLocal: return WhisperLocalEngine.shared
        case .groq:         return GroqEngine()
        case .gemini:       return GeminiEngine()
        }
    }
}

// MARK: - Language helpers

enum TranscriptionLanguage {
    /// Human language name for prompt-based engines (Gemini). "auto" → nil.
    static func englishName(for code: String) -> String? {
        switch code.lowercased() {
        case "ru": return "Russian"
        case "en": return "English"
        case "uk": return "Ukrainian"
        case "de": return "German"
        case "fr": return "French"
        case "es": return "Spanish"
        case "auto", "": return nil
        default: return nil
        }
    }

    /// ISO-639-1 code for code-based engines (Whisper/Groq). "auto" → nil.
    static func isoCode(for code: String) -> String? {
        let c = code.lowercased()
        return (c == "auto" || c.isEmpty) ? nil : c
    }
}

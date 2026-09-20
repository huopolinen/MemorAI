import Foundation

/// What a transcript is made of once we stop treating it as a wall of text.
///
/// The app's whole point is an archive an AI can read later, and a wall of text
/// cannot answer "who said that" — the question that matters most in a call.
/// Answering it needs two things the old pipeline threw away: when each phrase
/// was spoken, and which of the two tracks it came from. `TranscriptSegment`
/// carries the first; `SpeakerAttribution` uses it to recover the second.

/// One timed piece of what an engine heard, on the clock of the audio file the
/// engine was handed.
struct TranscriptSegment {
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    /// The engine's own diarization label ("SPEAKER_01", "Спикер 2"), when it
    /// produces one. None of our engines diarize today, but the attribution
    /// pass is materially better when they do — a label is a *voice*, and a
    /// voice can be settled on one side for the whole call.
    var speaker: String?

    init(start: TimeInterval, end: TimeInterval, text: String, speaker: String? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
    }
}

/// What an engine gives back: always text, and timed segments when it can.
///
/// `segments == nil` is not a failure — it is an honest "this engine cannot
/// tell you when". Gemini answers in free-form prose and that is all it has.
/// The caller degrades to an unlabelled transcript rather than guessing.
struct TranscriptionResult {
    var text: String
    var segments: [TranscriptSegment]?

    init(text: String, segments: [TranscriptSegment]? = nil) {
        self.text = text
        self.segments = segments
    }
}

/// Which of the two tracks a phrase came from.
enum SpeakerSide: String {
    /// The microphone: the owner of the machine.
    case me
    /// The system audio tap: everyone on the other end of the call.
    case them
}

/// A segment after attribution: same words, now with a side and how sure we are.
struct AttributedSegment {
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var side: SpeakerSide
    /// The engine's diarization label, kept so several people sharing the far
    /// end can still be told apart.
    var label: String?
    /// 0…1. Low means the two tracks read almost the same under this phrase
    /// (people talking over each other, or a stretch where both were quiet) —
    /// the side is our best guess, not a fact.
    var confidence: Double
}

/// Renders a transcript to the two files that live beside the recording: one
/// for a human to read, one for a machine to parse.
enum TranscriptDocument {
    static func displayName(side: SpeakerSide, suffix: String?) -> String {
        let base = side == .me ? "Я" : "Собеседник"
        guard let suffix, !suffix.isEmpty else { return base }
        return "\(base) \(suffix)"
    }

    /// Human-readable transcript: one paragraph per speaker turn.
    ///
    /// Consecutive segments from the same speaker are joined into a single
    /// paragraph — the engine cuts a segment every few seconds, and a label on
    /// every line would read like a chat log of one person talking to himself.
    static func plainText(_ segments: [AttributedSegment], suffixes: [String: String]) -> String {
        var out: [String] = []
        var currentName: String?
        var buffer: [String] = []

        func flush() {
            guard let name = currentName, !buffer.isEmpty else { return }
            out.append("\(name): \(buffer.joined(separator: " "))")
            buffer = []
        }

        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let name = displayName(side: segment.side, suffix: segment.label.flatMap { suffixes[$0] })
            if name != currentName {
                flush()
                currentName = name
            }
            buffer.append(text)
        }
        flush()
        return out.joined(separator: "\n\n") + "\n"
    }

    /// Machine-readable transcript. This is the file an AI reads later, so it
    /// keeps the raw engine wording and exact times — the .txt beside it may
    /// have been through the LLM polisher, which is good for eyes and lossy
    /// for analysis.
    ///
    /// `trackOffset` is what to add to a segment's time to find it inside the
    /// original .caf/.m4a tracks: the transcript clock starts at the first
    /// speech, the track clock starts when recording started.
    static func json(
        tag: String,
        engine: String,
        language: String,
        segments: [AttributedSegment]?,
        plainSegments: [TranscriptSegment]?,
        suffixes: [String: String],
        trackOffset: TimeInterval,
        tracks: [String: String]
    ) -> Data? {
        var items: [[String: Any]] = []
        if let segments {
            items = segments.map { segment in
                var item: [String: Any] = [
                    "start": round(segment.start * 100) / 100,
                    "end": round(segment.end * 100) / 100,
                    "speaker": segment.side.rawValue,
                    "label": displayName(side: segment.side,
                                         suffix: segment.label.flatMap { suffixes[$0] }),
                    "confidence": round(segment.confidence * 100) / 100,
                    "text": segment.text,
                ]
                if let label = segment.label { item["engine_speaker"] = label }
                return item
            }
        } else if let plainSegments {
            // Timestamps without sides: one track, or an engine whose output we
            // could time but not attribute. Still worth writing — knowing when
            // something was said is most of the value of a machine-readable
            // transcript.
            items = plainSegments.map { segment in
                [
                    "start": round(segment.start * 100) / 100,
                    "end": round(segment.end * 100) / 100,
                    "speaker": NSNull(),
                    "text": segment.text,
                ]
            }
        } else {
            return nil
        }

        let root: [String: Any] = [
            "version": 1,
            "tag": tag,
            "engine": engine,
            "language": language,
            "speakers": segments != nil,
            "created": iso.string(from: Date()),
            "clock": "transcript",
            "track_offset": round(trackOffset * 100) / 100,
            "tracks": tracks,
            "segments": items,
        ]
        return try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Its own formatter rather than `SessionMeta.iso` so this file (and the
    /// attribution beside it) stays free of the recording machinery and can be
    /// compiled on its own for testing.
    private static let iso = ISO8601DateFormatter()
}

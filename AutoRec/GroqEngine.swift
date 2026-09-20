import Foundation

/// Transcription via Groq's free OpenAI-compatible audio API.
/// Runs `whisper-large-v3-turbo` server-side — a strict upgrade over the local
/// `ggml-base` model, especially for Russian.
final class GroqEngine: TranscriptionEngine {
    let kind: TranscriptionEngineKind = .groq
    let inputFormat: EngineAudioFormat = .flac

    private let endpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    private let model = "whisper-large-v3-turbo"

    private var apiKey: String { SettingsManager.shared.groqApiKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isAvailable: Bool { !apiKey.isEmpty }
    var unavailableReason: String? { apiKey.isEmpty ? "не задан Groq API-ключ" : nil }

    func transcribe(audioURL: URL, language: String) -> String? {
        transcribeDetailed(audioURL: audioURL, language: language)?.text
    }

    /// Asks for `verbose_json` instead of `text`: same transcript, plus the
    /// per-phrase `start`/`end` that speaker attribution runs on. Whisper's API
    /// returns segment-level timings by default, so nothing extra is requested
    /// and the response is no slower.
    func transcribeDetailed(audioURL: URL, language: String) -> TranscriptionResult? {
        guard !apiKey.isEmpty else { log("[Groq] missing API key"); return nil }
        guard let audioData = try? Data(contentsOf: audioURL) else {
            log("[Groq] cannot read \(audioURL.lastPathComponent)")
            return nil
        }

        let boundary = "----memorai\(UInt64(audioData.count))Boundary"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }
        field("model", model)
        field("response_format", "verbose_json")
        field("temperature", "0")
        if let iso = TranscriptionLanguage.isoCode(for: language) { field("language", iso) }

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.flac\"\r\n")
        body.append("Content-Type: audio/flac\r\n\r\n")
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 300

        let (data, response, error) = HTTP.sendSyncRetrying(request)
        if let error = error {
            log("[Groq] ❌ network error: \(error.localizedDescription)")
            return nil
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        guard status == 200 else {
            log("[Groq] ❌ HTTP \(status): \(text.prefix(400))")
            return nil
        }

        guard let data, let parsed = Self.parse(data) else {
            // Not the JSON we expected. The body is still very likely the
            // transcript (that is what `response_format=text` used to return),
            // and a transcript without speaker labels beats no transcript.
            let fallback = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fallback.isEmpty else { return nil }
            log("[Groq] ⚠️ ответ не разобран как verbose_json — беру как текст, без меток говорящих")
            return TranscriptionResult(text: text, segments: nil)
        }
        return parsed
    }

    /// `verbose_json`: `{"text": "...", "segments": [{"start": 0.0, "end": 3.2, "text": "…"}]}`.
    /// Times are seconds from the start of the uploaded file.
    private static func parse(_ data: Data) -> TranscriptionResult? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = root["text"] as? String
        else { return nil }

        guard let items = root["segments"] as? [[String: Any]] else {
            return TranscriptionResult(text: text, segments: nil)
        }
        let segments = items.compactMap { item -> TranscriptSegment? in
            guard let start = (item["start"] as? NSNumber)?.doubleValue,
                  let end = (item["end"] as? NSNumber)?.doubleValue,
                  let raw = item["text"] as? String
            else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return TranscriptSegment(start: start, end: end, text: trimmed)
        }
        return TranscriptionResult(text: text, segments: segments.isEmpty ? nil : segments)
    }
}

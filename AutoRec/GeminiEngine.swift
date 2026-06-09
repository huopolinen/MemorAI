import Foundation

/// Transcription via Google Gemini (the technology behind NotebookLM).
/// Unlike raw ASR, Gemini is prompted to return a clean, well-punctuated,
/// speaker-attributed transcript — matching the "NotebookLM / Notion AI" feel.
final class GeminiEngine: TranscriptionEngine {
    let kind: TranscriptionEngineKind = .gemini
    let inputFormat: EngineAudioFormat = .flac

    private var apiKey: String { SettingsManager.shared.geminiApiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var model: String {
        let m = SettingsManager.shared.geminiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return m.isEmpty ? "gemini-2.5-flash" : m
    }

    var isAvailable: Bool { !apiKey.isEmpty }
    var unavailableReason: String? { apiKey.isEmpty ? "не задан Gemini API-ключ" : nil }

    func transcribe(audioURL: URL, language: String) -> String? {
        guard !apiKey.isEmpty else { log("[Gemini] missing API key"); return nil }
        guard let audioData = try? Data(contentsOf: audioURL) else {
            log("[Gemini] cannot read \(audioURL.lastPathComponent)")
            return nil
        }

        let langClause: String
        if let name = TranscriptionLanguage.englishName(for: language) {
            langClause = "The audio is primarily in \(name). Transcribe in that language."
        } else {
            langClause = "Transcribe in whatever language is spoken; do not translate."
        }
        let prompt = """
        You are a professional transcriptionist. Transcribe the attached audio recording verbatim. \
        \(langClause) \
        Produce a clean, accurately punctuated transcript. When you can distinguish different voices, \
        label them as "Спикер 1:", "Спикер 2:", etc. on separate lines. \
        Do not summarize, comment, translate, or add anything that is not spoken. \
        Never repeat a word or short filler (e.g. "угу", "ага", "да") more than twice in a row — \
        transcribe backchannel sounds at most once; do not loop. \
        Output only the transcript text.
        """

        // 2.5 models are "thinking" models — for transcription we don't want them
        // burning the output budget on reasoning (it returns STOP with no text),
        // so disable thinking. thinkingConfig is invalid on 2.0, so gate on "2.5".
        var genConfig: [String: Any] = ["temperature": 0]
        if model.contains("2.5") {
            genConfig["thinkingConfig"] = ["thinkingBudget": 0]
        }

        let payload: [String: Any] = [
            "contents": [[
                "parts": [
                    ["text": prompt],
                    ["inline_data": ["mime_type": "audio/flac",
                                     "data": audioData.base64EncodedString()]],
                ],
            ]],
            "generationConfig": genConfig,
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else {
            log("[Gemini] failed to serialize request")
            return nil
        }

        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Newer Google AI Studio keys (AQ.*) are passed via header, not ?key=.
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = bodyData
        request.timeoutInterval = 300

        let (data, response, error) = HTTP.sendSyncRetrying(request)
        if let error = error {
            log("[Gemini] ❌ network error: \(error.localizedDescription)")
            return nil
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let data = data else {
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            log("[Gemini] ❌ HTTP \(status): \(text.prefix(500))")
            return nil
        }

        guard let text = Self.extractText(from: data) else {
            log("[Gemini] ❌ no text in response: \(String(data: data, encoding: .utf8)?.prefix(400) ?? "")")
            return nil
        }
        return text
    }

    /// Pull `candidates[0].content.parts[*].text` out of a generateContent response.
    private static func extractText(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = root["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return nil }
        let joined = parts.compactMap { $0["text"] as? String }.joined()
        return joined.isEmpty ? nil : joined
    }
}

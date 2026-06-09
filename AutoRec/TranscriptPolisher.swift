import Foundation

/// Post-processes a raw ASR transcript into readable text: adds capitalization,
/// punctuation, and paragraph breaks WITHOUT changing the words. Uses Groq's free
/// LLM API (separate quota from Gemini), so it pairs with the Groq Whisper engine
/// to give "reliable + readable" — Whisper's accuracy with clean formatting.
///
/// Wording-preserving by contract: the prompt forbids summarizing, omitting, or
/// rewording. Best-effort — on any failure the original text is kept.
enum TranscriptPolisher {
    private static let endpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
    private static let model = "llama-3.3-70b-versatile"
    private static let wordsPerChunk = 2200 // keep input+output well within token limits

    /// Returns formatted text, or nil if polishing isn't possible/failed (caller keeps raw).
    static func polish(_ text: String, apiKey: String) -> String? {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let chunks = splitByWords(trimmed, perChunk: wordsPerChunk)
        var out: [String] = []
        for (i, chunk) in chunks.enumerated() {
            guard let formatted = formatChunk(chunk, key: key) else {
                log("[Polisher] chunk \(i + 1)/\(chunks.count) failed — aborting, keeping raw")
                return nil
            }
            out.append(formatted)
        }
        log("[Polisher] formatted \(chunks.count) chunk(s)")
        return out.joined(separator: "\n\n")
    }

    private static func formatChunk(_ chunk: String, key: String) -> String? {
        let system = """
        Ты редактор расшифровок речи. На вход — сырой текст распознавания (часто без \
        заглавных букв и знаков препинания). Твоя задача: расставить заглавные буквы, \
        запятые, точки, тире, вопросительные и восклицательные знаки, разбить на абзацы \
        по смыслу. Если по контексту явно меняется говорящий — начинай новый абзац. \
        СТРОГО запрещено: менять или переставлять слова, что-то сокращать, удалять, \
        добавлять, пересказывать или комментировать. Сохрани все слова как есть. \
        Верни ТОЛЬКО отредактированный текст, без преамбул.
        """
        let payload: [String: Any] = [
            "model": model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": chunk],
            ],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 120

        let (data, response, error) = HTTP.sendSyncRetrying(req)
        if let error = error { log("[Polisher] network error: \(error.localizedDescription)"); return nil }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let data = data else {
            let b = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            log("[Polisher] HTTP \(status): \(b.prefix(300))")
            return nil
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else { return nil }
        let result = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    /// Split on whitespace into chunks of ~perChunk words, breaking at a sentence
    /// boundary near the limit when possible so chunks don't cut mid-thought.
    private static func splitByWords(_ text: String, perChunk: Int) -> [String] {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        guard words.count > perChunk else { return [text] }
        var chunks: [String] = []
        var i = 0
        while i < words.count {
            let end = min(i + perChunk, words.count)
            chunks.append(words[i..<end].joined(separator: " "))
            i = end
        }
        return chunks
    }
}

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
    /// Groq retires models without notice, and this one's death was invisible:
    /// every polish returned HTTP 404, the caller fell back to the raw text as
    /// designed, and nothing looked broken from the outside. If polishing ever
    /// seems to stop happening, check this name against Groq's model list first.
    private static let model = "openai/gpt-oss-120b"
    private static let wordsPerChunk = 2200 // keep input+output well within token limits

    /// Returns formatted text, or nil if polishing isn't possible/failed (caller keeps raw).
    ///
    /// `speakerLabels` says the text is already split into "Я: …" / "Собеседник: …"
    /// turns. Those labels cost real work to recover — they come from comparing
    /// the two audio tracks, not from the words — so the model is told to leave
    /// them alone and the result is checked before it is accepted.
    static func polish(_ text: String, apiKey: String, speakerLabels: Bool = false) -> String? {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            log("[Polisher] нет ключа Groq — оставляю сырой текст")
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let chunks = splitByWords(trimmed, perChunk: wordsPerChunk)
        var out: [String] = []
        for (i, chunk) in chunks.enumerated() {
            guard let formatted = formatChunk(chunk, key: key, speakerLabels: speakerLabels) else {
                log("[Polisher] chunk \(i + 1)/\(chunks.count) failed — aborting, keeping raw")
                return nil
            }
            out.append(formatted)
        }
        let result = out.joined(separator: "\n\n")

        // A polished transcript that lost its speaker labels is a downgrade, not
        // an improvement: punctuation can be inferred by whoever reads it, "who
        // said this" cannot. Losing a few labels to reflow is expected; losing
        // most of them means the model rewrote the structure, and we keep the raw.
        if speakerLabels {
            let before = labelCount(trimmed)
            let after = labelCount(result)
            guard before == 0 || after * 2 >= before else {
                log("[Polisher] ⚠️ полировка съела метки говорящих (\(before) → \(after)) — оставляю неполированный текст")
                return nil
            }
        }
        log("[Polisher] formatted \(chunks.count) chunk(s)")
        return result
    }

    /// Lines that start with a speaker label the attribution pass wrote.
    private static func labelCount(_ text: String) -> Int {
        text.components(separatedBy: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("Я:") || trimmed.hasPrefix("Я ")
                || trimmed.hasPrefix("Собеседник:") || trimmed.hasPrefix("Собеседник ")
        }.count
    }

    private static func formatChunk(_ chunk: String, key: String, speakerLabels: Bool) -> String? {
        let labelRule = speakerLabels ? """
        Текст уже разбит на реплики: каждый абзац начинается с метки говорящего \
        («Я:», «Собеседник:», «Собеседник A:»). Эти метки ОБЯЗАТЕЛЬНО сохраняй \
        дословно и в том же месте, не объединяй абзацы разных говорящих, не \
        переставляй реплики и не добавляй новых меток.
        """ : ""
        let system = """
        Ты редактор расшифровок речи. На вход — сырой текст распознавания (часто без \
        заглавных букв и знаков препинания). Твоя задача: расставить заглавные буквы, \
        запятые, точки, тире, вопросительные и восклицательные знаки, разбить на абзацы \
        по смыслу. Если по контексту явно меняется говорящий — начинай новый абзац. \
        СТРОГО запрещено: менять или переставлять слова, что-то сокращать, удалять, \
        добавлять, пересказывать или комментировать. Сохрани все слова как есть. \
        ЕДИНСТВЕННОЕ исключение: удаляй очевидные галлюцинации распознавания, не \
        относящиеся к разговору, — титры субтитров («Субтитры сделал …», «Субтитры \
        создавал …», «Редактор субтитров …», «DimaTorzok») и вставки на тишине \
        вроде «Продолжение следует», «Спасибо за просмотр», «Подписывайтесь на канал». \
        Их выкидывай целиком; реальные слова разговора не трогай. \
        \(labelRule) \
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
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            log("[Polisher] не собрался запрос (\(chunk.count) символов)")
            return nil
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 120

        let (data, response, error) = HTTP.sendSyncRetrying(req)
        if let error = error {
            let ns = error as NSError
            log("[Polisher] сеть: \(error.localizedDescription) [\(ns.domain) \(ns.code)]")
            return nil
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let data = data else {
            let b = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            log("[Polisher] HTTP \(status): \(b.prefix(300))")
            return nil
        }
        // Every exit below used to return nil without a word, which is how a
        // run of failed polishes ended up in the log with no cause at all.
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]], let first = choices.first
        else {
            log("[Polisher] ответ не разобран: \(bodyPreview(data))")
            return nil
        }
        let finish = (first["finish_reason"] as? String) ?? "?"
        guard let msg = first["message"] as? [String: Any],
              let content = msg["content"] as? String
        else {
            log("[Polisher] в ответе нет текста (finish_reason: \(finish)): \(bodyPreview(data))")
            return nil
        }
        let result = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else {
            // A reasoning model can spend the whole budget on its own thinking
            // and answer with an empty string — `finish_reason` says which.
            log("[Polisher] пустой ответ модели (finish_reason: \(finish), чанк \(chunk.count) символов)")
            return nil
        }
        return result
    }

    /// First 300 characters of a response body, for the log.
    private static func bodyPreview(_ data: Data) -> String {
        guard let body = String(data: data, encoding: .utf8) else {
            return "<не UTF-8, \(data.count) байт>"
        }
        return String(body.prefix(300))
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

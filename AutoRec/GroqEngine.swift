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
        field("response_format", "text")
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
        // response_format=text → body is the raw transcript.
        return text
    }
}

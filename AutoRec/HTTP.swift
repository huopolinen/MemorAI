import Foundation

/// Minimal synchronous HTTP helper for the transcription engines, which run on
/// `Transcriber`'s background serial queue and therefore may block.
enum HTTP {
    static func sendSync(_ request: URLRequest) -> (Data?, URLResponse?, Error?) {
        let semaphore = DispatchSemaphore(value: 0)
        var result: (Data?, URLResponse?, Error?) = (nil, nil, nil)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            result = (data, response, error)
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        return result
    }

    /// Like `sendSync`, but retries transient failures (network errors, HTTP 429,
    /// and 5xx — e.g. Gemini's "503 model overloaded") with exponential backoff.
    /// Safe to block: callers run on a background queue.
    static func sendSyncRetrying(_ request: URLRequest, maxAttempts: Int = 6) -> (Data?, URLResponse?, Error?) {
        var attempt = 0
        while true {
            attempt += 1
            let (data, response, error) = sendSync(request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let retriable = error != nil || status == 429 || (500...599).contains(status)
            if !retriable || attempt >= maxAttempts {
                return (data, response, error)
            }
            // Honour the server's suggested wait (e.g. Gemini 429 "Please retry in 39s"
            // / RetryInfo retryDelay) — fixed backoff is too short for per-minute limits.
            let serverDelay = data.flatMap { suggestedRetrySeconds(from: $0) }
            let backoff = pow(2.0, Double(attempt)) // 2,4,8,16,32…
            let wait = min(max(serverDelay ?? backoff, backoff), 65)
            let what = error != nil ? "network error" : "HTTP \(status)"
            log("[HTTP] \(what) (attempt \(attempt)/\(maxAttempts)) — retry in \(Int(wait))s\(serverDelay != nil ? " (server hint)" : "")")
            Thread.sleep(forTimeInterval: wait)
        }
    }

    /// Extract a retry delay (seconds) from a Google API error body, from either
    /// `"retryDelay": "39s"` or `Please retry in 39.7s`. Adds a 1s safety margin.
    private static func suggestedRetrySeconds(from data: Data) -> Double? {
        guard let body = String(data: data, encoding: .utf8) else { return nil }
        let patterns = [#"retryDelay"\s*:\s*"(\d+(?:\.\d+)?)s"#, #"retry in (\d+(?:\.\d+)?)s"#]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p),
               let m = re.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
               let r = Range(m.range(at: 1), in: body),
               let secs = Double(body[r]) {
                return secs + 1
            }
        }
        return nil
    }
}

extension Data {
    /// Append a string as UTF-8 — convenience for building multipart bodies.
    mutating func append(_ string: String) {
        if let d = string.data(using: .utf8) { append(d) }
    }
}

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
    static func sendSyncRetrying(_ request: URLRequest, maxAttempts: Int = 5) -> (Data?, URLResponse?, Error?) {
        var attempt = 0
        while true {
            attempt += 1
            let (data, response, error) = sendSync(request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let retriable = error != nil || status == 429 || (500...599).contains(status)
            if !retriable || attempt >= maxAttempts {
                return (data, response, error)
            }
            let backoff = min(pow(2.0, Double(attempt)), 30) // 2,4,8,16,30s
            let what = error != nil ? "network error" : "HTTP \(status)"
            log("[HTTP] \(what) (attempt \(attempt)/\(maxAttempts)) — retry in \(Int(backoff))s")
            Thread.sleep(forTimeInterval: backoff)
        }
    }
}

extension Data {
    /// Append a string as UTF-8 — convenience for building multipart bodies.
    mutating func append(_ string: String) {
        if let d = string.data(using: .utf8) { append(d) }
    }
}

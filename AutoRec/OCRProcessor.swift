import Foundation
import Vision
import ImageIO

class OCRProcessor {
    private let queue = DispatchQueue(label: "com.memorai.ocr", qos: .background)

    func process(imageURL: URL, jsonlURL: URL, baseMeta: [String: Any]) {
        queue.async {
            var record = baseMeta

            if let src = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(src, 0, nil) {

                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["ru", "en"]
                request.usesLanguageCorrection = true
                request.revision = VNRecognizeTextRequestRevision3

                let handler = VNImageRequestHandler(cgImage: image)
                if (try? handler.perform([request])) != nil,
                   let results = request.results {
                    let text = results.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                    record["ocr_text"] = text

                    let extracted = Self.extractStructuredData(from: text)
                    if !extracted.urls.isEmpty { record["urls"] = extracted.urls }
                    if !extracted.emails.isEmpty { record["emails"] = extracted.emails }
                    if !extracted.phones.isEmpty { record["phones"] = extracted.phones }
                    if !extracted.paths.isEmpty { record["file_paths"] = extracted.paths }
                }
            }

            JSONLWriter.shared.append(record, to: jsonlURL)
        }
    }

    // MARK: - Structured Extraction

    private struct ExtractedData {
        var urls: [String] = []
        var emails: [String] = []
        var phones: [String] = []
        var paths: [String] = []
    }

    private static func extractStructuredData(from text: String) -> ExtractedData {
        var result = ExtractedData()

        // URLs
        if let urlRegex = try? NSRegularExpression(pattern: #"https?://[^\s<>\"\']+"#, options: .caseInsensitive) {
            let matches = urlRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            result.urls = matches.compactMap { Range($0.range, in: text).map { String(text[$0]) } }
        }

        // Also catch localhost URLs
        if let localRegex = try? NSRegularExpression(pattern: #"localhost:\d+[^\s<>\"\']*"#, options: .caseInsensitive) {
            let matches = localRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            let locals = matches.compactMap { Range($0.range, in: text).map { "http://\(String(text[$0]))" } }
            result.urls.append(contentsOf: locals)
        }

        // Catch domain-based URLs without protocol (e.g. from browser address bars)
        if let domainRegex = try? NSRegularExpression(pattern: #"[\w-]+\.[\w.-]+/[^\s<>\"\']*"#) {
            let matches = domainRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            let domains = matches.compactMap { Range($0.range, in: text).map { String(text[$0]) } }
                .filter { $0.contains("/") && !$0.hasPrefix("http") }
                .map { "https://\($0)" }
            result.urls.append(contentsOf: domains)
        }

        // Emails
        if let emailRegex = try? NSRegularExpression(pattern: #"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}"#) {
            let matches = emailRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            result.emails = matches.compactMap { Range($0.range, in: text).map { String(text[$0]) } }
        }

        // Phone numbers (international format)
        if let phoneRegex = try? NSRegularExpression(pattern: #"\+?\d[\d\s\-()]{7,}\d"#) {
            let matches = phoneRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            result.phones = matches.compactMap { Range($0.range, in: text).map { String(text[$0]) } }
                .filter { $0.filter(\.isNumber).count >= 7 }
        }

        // File paths
        if let pathRegex = try? NSRegularExpression(pattern: #"(?:/[\w.-]+){2,}"#) {
            let matches = pathRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            result.paths = matches.compactMap { Range($0.range, in: text).map { String(text[$0]) } }
                .filter { $0.count > 5 }
        }

        // Deduplicate
        result.urls = Array(Set(result.urls))
        result.emails = Array(Set(result.emails))
        result.phones = Array(Set(result.phones))
        result.paths = Array(Set(result.paths))

        return result
    }
}

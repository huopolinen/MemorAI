import Foundation

final class JSONLWriter {
    static let shared = JSONLWriter()
    private let queue = DispatchQueue(label: "com.memorai.jsonl-writer")

    private init() {}

    func append(_ record: [String: Any], to fileURL: URL) {
        queue.async {
            guard var data = try? JSONSerialization.data(
                withJSONObject: record,
                options: [.sortedKeys, .withoutEscapingSlashes]
            ) else { return }
            data.append(0x0A)

            let fm = FileManager.default
            if !fm.fileExists(atPath: fileURL.path) {
                try? data.write(to: fileURL, options: .atomic)
                return
            }
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {}
        }
    }
}

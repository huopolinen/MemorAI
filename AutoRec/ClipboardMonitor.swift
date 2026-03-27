import AppKit
import Foundation

struct ClipboardEntry {
    let timestamp: Date
    let appName: String
    let bundleId: String
    let type: String  // text, image, url, file, other
    let content: String
}

class ClipboardMonitor {
    private var lastChangeCount: Int = 0
    private var storageURL: URL?
    private let pasteboard = NSPasteboard.general

    /// In-memory buffer of recent entries for the menu
    private(set) var recentEntries: [ClipboardEntry] = []
    private let maxEntries = 100

    func start(storageURL: URL) {
        self.storageURL = storageURL
        lastChangeCount = pasteboard.changeCount
        loadRecentEntries()
    }

    /// Called periodically. Checks if clipboard changed and saves if so.
    func checkAndSave(excludedBundleIds: [String]) {
        guard let storage = storageURL else { return }
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        // Skip excluded apps
        let frontApp = NSWorkspace.shared.frontmostApplication
        if let bundleId = frontApp?.bundleIdentifier,
           excludedBundleIds.contains(bundleId) {
            return
        }

        let now = Date()
        let appName = frontApp?.localizedName ?? ""
        let bundleId = frontApp?.bundleIdentifier ?? ""

        var entry: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: now),
            "app_name": appName,
            "app_bundle_id": bundleId,
        ]

        var type = "other"
        var content = ""

        // Try multiple text types
        let pb = self.pasteboard
        let textTypes: [NSPasteboard.PasteboardType] = [.string, .rtf, .html]
        let text = textTypes.lazy.compactMap { pb.string(forType: $0) }.first { !$0.isEmpty }

        if let text = text {
            type = "text"
            content = text
        } else if let tiffData = pasteboard.data(forType: .tiff),
                  let image = NSImage(data: tiffData),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let dayDir = storage.appendingPathComponent("screen").appendingPathComponent(dayString(now))
            try? FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
            let filename = "clipboard-\(timeString(now)).jpg"
            let imageURL = dayDir.appendingPathComponent(filename)
            if let dest = CGImageDestinationCreateWithURL(imageURL as CFURL, "public.jpeg" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
                CGImageDestinationFinalize(dest)
            }
            type = "image"
            content = filename
        } else if let url = pasteboard.string(forType: .URL) {
            type = "url"
            content = url
        } else if let files = pasteboard.propertyList(forType: .fileURL) as? String {
            type = "file"
            content = files
        } else {
            let types = pasteboard.types?.map { $0.rawValue } ?? []
            content = types.joined(separator: ", ")
        }

        entry["type"] = type
        entry["content"] = content

        // Add to in-memory buffer
        let clipEntry = ClipboardEntry(timestamp: now, appName: appName, bundleId: bundleId, type: type, content: content)
        recentEntries.insert(clipEntry, at: 0)
        if recentEntries.count > maxEntries {
            recentEntries.removeLast()
        }

        // Append to clipboard.jsonl
        guard let jsonData = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
              var line = String(data: jsonData, encoding: .utf8) else { return }
        line += "\n"

        let logURL = storage.appendingPathComponent("clipboard.jsonl")
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let fh = try? FileHandle(forWritingTo: logURL) {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    fh.closeFile()
                }
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    /// Load recent entries from clipboard.jsonl
    func loadRecentEntries() {
        let storage = storageURL ?? URL(fileURLWithPath: SettingsManager.shared.outputPath)
        let logURL = storage.appendingPathComponent("clipboard.jsonl")

        guard let data = try? String(contentsOf: logURL, encoding: .utf8) else { return }

        let lines = data.components(separatedBy: "\n").filter { !$0.isEmpty }
        let tail = Array(lines.suffix(maxEntries))

        var loaded: [ClipboardEntry] = []
        for line in tail.reversed() {
            guard let jsonData = line.data(using: .utf8),
                  let d = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }
            loaded.append(ClipboardEntry(
                timestamp: ISO8601DateFormatter().date(from: d["timestamp"] as? String ?? "") ?? Date(),
                appName: d["app_name"] as? String ?? "",
                bundleId: d["app_bundle_id"] as? String ?? "",
                type: d["type"] as? String ?? "",
                content: d["content"] as? String ?? ""
            ))
        }
        recentEntries = loaded
    }

    private func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH-mm-ss"
        return f.string(from: date)
    }
}

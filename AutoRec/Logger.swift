import Foundation
import os

private let osLogger = os.Logger(subsystem: "com.local.memorai", category: "main")

private let logQueue = DispatchQueue(label: "com.local.memorai.log", qos: .utility)
private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    return f
}()

private var cachedHandle: FileHandle?
private var cachedPath: String?

func log(_ message: String) {
    osLogger.info("\(message, privacy: .public)")
    let ts = isoFormatter.string(from: Date())
    let line = "\(ts) \(message)\n"
    logQueue.async {
        guard let data = line.data(using: .utf8) else { return }
        let path = SettingsManager.shared.outputPath + "/memorai.log"
        if cachedPath != path {
            try? cachedHandle?.close()
            cachedHandle = nil
            cachedPath = path
        }
        if cachedHandle == nil {
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            cachedHandle = FileHandle(forWritingAtPath: path)
            if let handle = cachedHandle {
                _ = try? handle.seekToEnd()
            }
        }
        if let handle = cachedHandle {
            try? handle.write(contentsOf: data)
        }
    }
}

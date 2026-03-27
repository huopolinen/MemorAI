import Foundation
import os

private let logger = os.Logger(subsystem: "com.local.memorai", category: "main")

func log(_ message: String) {
    logger.info("\(message, privacy: .public)")
    let logDir = SettingsManager.shared.outputPath
    let logPath = "\(logDir)/memorai.log"
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logPath) {
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: logPath, contents: data)
        }
    }
}

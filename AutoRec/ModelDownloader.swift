import CryptoKit
import Foundation

/// One downloader for every local-engine model file (Whisper ggml, GigaAM GGUF).
///
/// Deliberately a single mechanism: both engines fetch one large file into a
/// cache directory and both need the same three things — a progress fraction
/// for the setup window, an atomic move so a half-finished file is never
/// mistaken for a usable model, and a plain-Russian error when it goes wrong.
/// A second, subtly different copy of this would drift.
///
/// Integrity checking is optional because the two sources differ: the GigaAM
/// GGUF is pinned to one Hugging Face revision, so its size and SHA-256 are
/// known in advance and worth enforcing; the whisper.cpp ggml models are
/// fetched from a moving `main` ref, where a pinned hash would break the
/// download every time upstream republishes.
enum ModelDownloader {

    /// What a finished file must weigh and hash. Nil = accept whatever arrives.
    struct Integrity {
        let expectedBytes: Int64
        let sha256: String
    }

    enum Failure: LocalizedError {
        case badHTTPStatus(Int)
        case missingFile
        case sizeMismatch(expected: Int64, actual: Int64)
        case hashMismatch

        var errorDescription: String? {
            switch self {
            case .badHTTPStatus(let code):
                return "сервер ответил HTTP \(code)"
            case .missingFile:
                return "загрузка не создала файл"
            case .sizeMismatch(let expected, let actual):
                return "размер файла \(actual) байт вместо \(expected) — скачалось не полностью"
            case .hashMismatch:
                return "контрольная сумма не сошлась — файл повреждён, попробуй ещё раз"
            }
        }
    }

    /// Keeps the URLSession and its delegate alive for the duration of the
    /// transfer. Callers store it; dropping it cancels nothing by itself, but
    /// `cancel()` does.
    final class Handle {
        private let session: URLSession
        fileprivate init(session: URLSession) { self.session = session }
        func cancel() { session.invalidateAndCancel() }
    }

    /// Download `url` into `destPath`, verifying it before it takes the final
    /// name. `progress` and `completion` are delivered on the main queue.
    @discardableResult
    static func download(from url: URL,
                         to destPath: String,
                         integrity: Integrity? = nil,
                         progress: @escaping (Double) -> Void,
                         completion: @escaping (Error?) -> Void) -> Handle {
        let destDir = (destPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)

        let delegate = Delegate(destPath: destPath, integrity: integrity,
                                progress: progress, completion: completion)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: .main)
        let handle = Handle(session: session)
        delegate.onFinish = { session.finishTasksAndInvalidate() }
        session.downloadTask(with: url).resume()
        return handle
    }

    /// True when the file at `path` already matches `integrity`. Used by the
    /// stores to tell "model is installed" from "a truncated file is lying
    /// around" without re-downloading first.
    static func verify(path: String, integrity: Integrity) -> Failure? {
        let url = URL(fileURLWithPath: path)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
        guard size == integrity.expectedBytes else {
            return .sizeMismatch(expected: integrity.expectedBytes, actual: size)
        }
        guard let digest = sha256(of: url), digest == integrity.sha256.lowercased() else {
            return .hashMismatch
        }
        return nil
    }

    /// Streaming SHA-256 — a model file is hundreds of megabytes, so it never
    /// gets read into memory whole.
    private static func sha256(of url: URL) -> String? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try? file.read(upToCount: 1_048_576), !data.isEmpty {
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Delegate

    private final class Delegate: NSObject, URLSessionDownloadDelegate {
        private let destPath: String
        private let integrity: Integrity?
        private let progressHandler: (Double) -> Void
        private let completionHandler: (Error?) -> Void
        private var finished = false
        var onFinish: (() -> Void)?

        init(destPath: String, integrity: Integrity?,
             progress: @escaping (Double) -> Void, completion: @escaping (Error?) -> Void) {
            self.destPath = destPath
            self.integrity = integrity
            self.progressHandler = progress
            self.completionHandler = completion
        }

        private func finish(_ error: Error?) {
            guard !finished else { return }
            finished = true
            onFinish?()
            DispatchQueue.main.async { self.completionHandler(error) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData _: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite total: Int64) {
            // The server may not send Content-Length; fall back to the expected
            // size we already know rather than showing a stuck 0 %.
            let denominator = total > 0 ? total : (integrity?.expectedBytes ?? 0)
            let fraction = denominator > 0 ? Double(totalBytesWritten) / Double(denominator) : 0
            DispatchQueue.main.async { self.progressHandler(min(1, fraction)) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            if let http = downloadTask.response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                finish(Failure.badHTTPStatus(http.statusCode))
                return
            }
            // URLSession deletes `location` the moment this method returns, so
            // the file is moved out first and verified in place afterwards —
            // under a `.partial` name, so a failed check never leaves something
            // that looks like an installed model.
            let dest = URL(fileURLWithPath: destPath)
            let partial = URL(fileURLWithPath: destPath + ".partial")
            do {
                try? FileManager.default.removeItem(at: partial)
                try FileManager.default.moveItem(at: location, to: partial)
            } catch {
                finish(error)
                return
            }
            // Hashing hundreds of megabytes must not block the main queue.
            DispatchQueue.global(qos: .utility).async {
                if let integrity = self.integrity,
                   let failure = ModelDownloader.verify(path: partial.path, integrity: integrity) {
                    try? FileManager.default.removeItem(at: partial)
                    self.finish(failure)
                    return
                }
                do {
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: partial, to: dest)
                    self.finish(nil)
                } catch {
                    try? FileManager.default.removeItem(at: partial)
                    self.finish(error)
                }
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error = error { finish(error) }
        }
    }
}

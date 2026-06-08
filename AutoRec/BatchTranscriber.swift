import Foundation

/// Headless batch mode: transcribe recorded call sessions that don't yet have a
/// transcript, using the engine selected in Settings. Reuses `Transcriber` and
/// the same pipeline as live recording.
///
/// Run via:  MemorAI --transcribe-pending [--date YYYY-MM-DD] [--force]
/// (run the binary inside the .app bundle so it reads the app's settings/keys.)
enum BatchTranscriber {
    static func run(dateFilter: String?, force: Bool) -> Never {
        let dir = URL(fileURLWithPath: SettingsManager.shared.outputPath)
        let engine = TranscriptionEngineFactory.current()

        print("MemorAI batch transcription")
        print("  folder : \(dir.path)")
        print("  engine : \(engine.kind.displayName)")
        if let d = dateFilter { print("  date   : \(d)") }

        guard engine.isAvailable else {
            print("❌ Engine not ready: \(engine.unavailableReason ?? "unknown"). Configure it in Settings.")
            exit(1)
        }

        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []

        // Group audio files into sessions by their timestamp tag.
        var tags = Set<String>()
        for f in files where f.hasPrefix("call_") && (f.hasSuffix("_mic.m4a") || f.hasSuffix("_system.m4a")) {
            if let d = dateFilter, !f.contains(d) { continue }
            let tag = f.replacingOccurrences(of: "_mic.m4a", with: "")
                       .replacingOccurrences(of: "_system.m4a", with: "")
            tags.insert(tag)
        }

        let sessions = tags.sorted()
        guard !sessions.isEmpty else {
            print("Nothing to do — no matching sessions found.")
            exit(0)
        }
        print("Found \(sessions.count) session(s).\n")

        DispatchQueue.global(qos: .userInitiated).async {
            var done = 0, skipped = 0, failed = 0
            for (i, tag) in sessions.enumerated() {
                let transcript = dir.appendingPathComponent("\(tag)_transcript.txt")
                if !force && fm.fileExists(atPath: transcript.path) {
                    print("[\(i+1)/\(sessions.count)] \(tag) — transcript exists, skipping")
                    skipped += 1
                    continue
                }
                if force { try? fm.removeItem(at: transcript) }

                let micURL = dir.appendingPathComponent("\(tag)_mic.m4a")
                let sysURL = dir.appendingPathComponent("\(tag)_system.m4a")
                let mic = fm.fileExists(atPath: micURL.path) ? micURL : nil
                let sys = fm.fileExists(atPath: sysURL.path) ? sysURL : nil

                print("[\(i+1)/\(sessions.count)] \(tag) — transcribing…")
                let sem = DispatchSemaphore(value: 0)
                Transcriber.shared.transcribeSession(micURL: mic, systemURL: sys) { sem.signal() }
                sem.wait()

                if fm.fileExists(atPath: transcript.path) {
                    let size = ((try? fm.attributesOfItem(atPath: transcript.path))?[.size] as? Int) ?? 0
                    print("    ✅ saved \(transcript.lastPathComponent) (\(size) bytes)")
                    done += 1
                } else {
                    print("    ⚠️ no transcript produced (too short or engine error — see log)")
                    failed += 1
                }
            }
            print("\nDone. transcribed=\(done) skipped=\(skipped) failed=\(failed)")
            exit(Int32(failed > 0 && done == 0 ? 1 : 0))
        }

        // Service the main run loop so Transcriber's main-queue completions fire.
        RunLoop.main.run()
        exit(0)
    }
}

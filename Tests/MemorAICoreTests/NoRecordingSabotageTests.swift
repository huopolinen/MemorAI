import XCTest

/// The app has no way to switch recording off or spoil it — no environment
/// variables, DEBUG branches, hidden defaults or launch flags in the recording
/// code (docs/decisions.md, 2026-11-17). The rule lives in
/// `tools/check-no-recording-sabotage.sh`, which the build scripts run; these
/// tests run it too, so `swift test` goes red as soon as such a hook appears.
final class NoRecordingSabotageTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // MemorAICoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root

    private static var script: String {
        repoRoot.appendingPathComponent("tools/check-no-recording-sabotage.sh").path
    }

    private func runCheck(_ dirs: [String] = []) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [Self.script] + dirs
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func sandbox(_ files: [String: String]) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("memorai-sabotage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        for (name, body) in files {
            try body.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return dir.path
    }

    func testAppSourcesHaveNoRecordingOffHooks() throws {
        let r = try runCheck()
        XCTAssertEqual(r.status, 0, r.output)
    }

    /// The exact hook that cost the 17.11 call must be caught.
    func testTheEnvironmentDropoutHookIsCaught() throws {
        let dir = try sandbox(["SystemAudioRecorder.swift": """
            private static let testDropout: Double? = {
                guard let raw = ProcessInfo.processInfo.environment["MEMORAI_TEST_SYSTEM_DROPOUT"] else { return nil }
                return Double(raw)
            }()
            """])
        let r = try runCheck([dir])
        XCTAssertEqual(r.status, 1, r.output)
        XCTAssertTrue(r.output.contains("MEMORAI_TEST"), r.output)
        XCTAssertTrue(r.output.contains("environment"), r.output)
    }

    func testOtherShapesOfTheSameHookAreCaught() throws {
        let cases: [String: String] = [
            "debug branch": "#if DEBUG\nlet muteFarEnd = true\n#endif\n",
            "getenv": "let v = getenv(\"SOME_SWITCH\")\n",
            "simulated silence": "var simulateSilence = false\n",
            "launch flag in recorder": "let off = CommandLine.arguments.contains(\"--no-system\")\n",
            "defaults outside settings": "let off = UserDefaults.standard.bool(forKey: \"x\")\n",
        ]
        for (label, body) in cases {
            let dir = try sandbox(["Recorder.swift": body])
            let r = try runCheck([dir])
            XCTAssertEqual(r.status, 1, "\(label) not caught: \(r.output)")
        }
    }

    func testHiddenSettingsKeyIsCaught() throws {
        let dir = try sandbox(["SettingsManager.swift": """
            var recordScreen: Bool { defaults.bool(forKey: "recordScreen") }
            var muteSystem: Bool { defaults.bool(forKey: "debugMuteSystem") }
            """])
        let r = try runCheck([dir])
        XCTAssertEqual(r.status, 1, r.output)
        XCTAssertTrue(r.output.contains("debugMuteSystem"), r.output)
        XCTAssertFalse(r.output.contains("key not in the allowlist: recordScreen"), r.output)
    }

    func testLaunchFlagsInMainAreAllowed() throws {
        let dir = try sandbox(["main.swift": "if CommandLine.arguments.contains(\"--audit-gaps\") { exit(0) }\n"])
        let r = try runCheck([dir])
        XCTAssertEqual(r.status, 0, r.output)
    }
}

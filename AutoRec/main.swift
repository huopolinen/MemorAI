import Cocoa

// Headless batch transcription mode (no GUI, no single-instance guard).
if CommandLine.arguments.contains("--transcribe-pending") {
    func value(after flag: String) -> String? {
        guard let i = CommandLine.arguments.firstIndex(of: flag),
              i + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[i + 1]
    }
    let dateFilter = value(after: "--date")
    let force = CommandLine.arguments.contains("--force")
    BatchTranscriber.run(dateFilter: dateFilter, force: force)
}

// Prevent multiple instances
let runningApps = NSWorkspace.shared.runningApplications.filter {
    $0.bundleIdentifier == "com.local.memorai"
}
if runningApps.count > 1 {
    // Another instance is already running — activate it and exit
    runningApps.first { $0 != NSRunningApplication.current }?.activate()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
withExtendedLifetime(delegate) {
    app.run()
}

import Cocoa

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

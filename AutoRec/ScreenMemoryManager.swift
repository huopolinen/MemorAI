import AppKit
import Foundation

class ScreenMemoryManager {
    private let capturer = ScreenCapturer()
    private let ocrProcessor = OCRProcessor()
    private let metadata = MetadataCollector()
    let clipboard = ClipboardMonitor()

    private var captureThread: Thread?
    private var lastSavedHash: UInt64 = 0
    private var keyPressCount = 0
    private var lastActiveAppBundleId: String = ""
    private var eventTap: CFMachPort?

    private let hashThreshold = 10
    private let keyPressThreshold = 30

    private(set) var isRunning = false

    func start() {
        guard !isRunning else { return }
        let settings = SettingsManager.shared
        let outputURL = URL(fileURLWithPath: settings.outputPath)

        isRunning = true
        lastSavedHash = 0
        keyPressCount = 0
        lastActiveAppBundleId = ""

        clipboard.start(storageURL: outputURL)
        startClipboardPolling()
        startKeyboardMonitoring()

        let thread = Thread { [weak self] in
            while let self = self, self.isRunning {
                self.tick()
                Thread.sleep(forTimeInterval: SettingsManager.shared.captureInterval)
            }
        }
        thread.qualityOfService = .userInitiated
        thread.start()
        captureThread = thread
    }

    func stop() {
        isRunning = false
        captureThread = nil
        clipboardSource?.cancel()
        clipboardSource = nil
        stopKeyboardMonitoring()
    }

    // MARK: - Capture Tick

    private func tick() {
        let settings = SettingsManager.shared
        let outputURL = URL(fileURLWithPath: settings.outputPath)

        guard settings.screenMemoryEnabled else { return }

        // Check if current app is excluded
        let currentApp = metadata.activeAppBundleID() ?? ""
        if settings.excludedBundleIds.contains(currentApp) { return }

        guard let image = capturer.capture() else { return }

        let currentHash = capturer.dhash(image)
        let distance = capturer.hammingDistance(currentHash, lastSavedHash)
        let appChanged = !lastActiveAppBundleId.isEmpty && currentApp != lastActiveAppBundleId
        let keyThreshold = keyPressCount >= keyPressThreshold

        lastActiveAppBundleId = currentApp

        let shouldSave = distance > hashThreshold || appChanged || keyThreshold
        guard shouldSave else { return }

        lastSavedHash = currentHash
        keyPressCount = 0

        let now = Date()
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH-mm-ss"

        let dayDir = outputURL.appendingPathComponent("screen").appendingPathComponent(dayFormatter.string(from: now))
        try? FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)

        let base = timeFormatter.string(from: now)
        let imageURL = dayDir.appendingPathComponent("\(base).heif")
        let jsonURL = dayDir.appendingPathComponent("\(base).json")

        guard !FileManager.default.fileExists(atPath: imageURL.path) else { return }

        let meta = metadata.collect()
        let savedURL = capturer.saveImage(image, to: imageURL)
        guard let savedURL = savedURL else { return }

        var json = meta
        json["timestamp"] = ISO8601DateFormatter().string(from: now)
        json["image_file"] = savedURL.lastPathComponent
        json["ocr_text"] = ""

        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: jsonURL)
        }

        ocrProcessor.process(imageURL: savedURL, jsonURL: jsonURL)
    }

    // MARK: - Clipboard Polling (separate thread)

    private var clipboardSource: DispatchSourceTimer?

    private func startClipboardPolling() {
        // Use a GCD timer on the main queue — NSPasteboard.changeCount
        // only updates reliably on the main thread
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + 2, repeating: 2)
        source.setEventHandler { [weak self] in
            guard let self = self, self.isRunning, SettingsManager.shared.saveClipboard else { return }
            self.clipboard.checkAndSave(excludedBundleIds: SettingsManager.shared.excludedBundleIds)
        }
        source.resume()
        clipboardSource = source
    }

    // MARK: - Keyboard Monitoring

    private func startKeyboardMonitoring() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: screenMemoryKeyboardCallback,
            userInfo: refcon
        )

        guard let eventTap = eventTap else { return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func stopKeyboardMonitoring() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
    }

    func incrementKeyCount() {
        keyPressCount += 1
    }

    func reenableEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }
}

// C-function keyboard callback
private func screenMemoryKeyboardCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
    let mgr = Unmanaged<ScreenMemoryManager>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .tapDisabledByTimeout {
        mgr.reenableEventTap()
    } else {
        mgr.incrementKeyCount()
    }
    return Unmanaged.passUnretained(event)
}

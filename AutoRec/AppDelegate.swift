import AVFoundation
import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var recordingManager: RecordingManager!
    private var callDetector: CallDetector!
    private var screenMemory: ScreenMemoryManager!
    private let settings = SettingsManager.shared
    private var whisperAlertShown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        requestPermissions()
        settings.ensureOutputDirectory()

        // --- Screen Memory (init before menu so clipboard history is available) ---
        screenMemory = ScreenMemoryManager()
        screenMemory.start()

        setupStatusItem()

        // --- Call Recording ---
        recordingManager = RecordingManager()
        recordingManager.onStateChange = { [weak self] state in
            DispatchQueue.main.async { self?.updateStatusIcon(state) }
        }
        recordingManager.onRecordingActiveChanged = { [weak self] active in
            guard let self = self else { return }
            if active {
                if self.settings.autoDetect { self.callDetector.enterRecordingMode() }
            } else {
                if self.settings.autoDetect { self.callDetector.exitRecordingMode() }
            }
        }
        recordingManager.onSilenceChanged = { [weak self] silent in
            self?.callDetector.reportSystemAudioSilence(silent)
        }
        recordingManager.onMicSilenceChanged = { [weak self] silent in
            self?.callDetector.reportMicSilence(silent)
        }
        recordingManager.onSystemAudioUnavailable = { [weak self] in
            self?.callDetector.reportSystemAudioUnavailable()
        }

        callDetector = CallDetector()
        callDetector.onCallStarted = { [weak self] in self?.recordingManager.startRecording(source: "auto-detect") }
        callDetector.onCallEnded = { [weak self] in self?.recordingManager.stopRecording(source: "auto-detect") }
        if settings.autoDetect {
            callDetector.startMonitoring()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.checkTranscriptionSetup()
        }
    }

    private func checkTranscriptionSetup() {
        guard !whisperAlertShown else { return }
        guard settings.autoTranscribe else { return }
        guard !Transcriber.shared.isAvailable else { return }
        whisperAlertShown = true

        let t = Transcriber.shared
        let alert = NSAlert()
        alert.addButton(withTitle: "Open Setup")
        alert.addButton(withTitle: "Dismiss")
        if t.resolvedWhisperPath == nil {
            alert.messageText = "whisper-cpp not installed"
            alert.informativeText = "Auto-transcription requires whisper-cpp.\n\nIn Setup you can install it automatically via Homebrew, or set a custom path."
        } else {
            alert.messageText = "Whisper model not found"
            alert.informativeText = "whisper-cli is ready but no model file was found.\n\nIn Setup you can download ggml-base (~150 MB) in one click."
        }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            WhisperSetupWindowController.shared.show()
        }
    }

    // MARK: - Permissions

    private func requestPermissions() {
        // Microphone
        AVCaptureDevice.requestAccess(for: .audio) { _ in }

        // Accessibility (for window titles, keyboard monitoring)
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Status Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = makeCircleIcon(.systemGray)
        }
        updateMenu()
    }

    private func makeCircleIcon(_ color: NSColor) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        updateMenu()
    }

    private func updateMenu() {
        let menu = NSMenu()
        menu.delegate = self

        // --- Call Recording Section ---
        let state = recordingManager?.state ?? .idle
        let stateItem = NSMenuItem(title: stateLabel(state), action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)

        menu.addItem(.separator())

        switch state {
        case .recording:
            addMenuItem(menu, "Pause", #selector(pauseRecording))
            addMenuItem(menu, "Stop Recording", #selector(stopRecording))
        case .paused:
            addMenuItem(menu, "Resume", #selector(resumeRecording))
            addMenuItem(menu, "Stop Recording", #selector(stopRecording))
        default:
            addMenuItem(menu, "Start Recording", #selector(startRecording))
        }

        let autoItem = addMenuItem(menu, "Auto-detect Calls", #selector(toggleAutoDetect))
        autoItem.state = settings.autoDetect ? .on : .off

        let videoItem = addMenuItem(menu, "Record Screen (Calls)", #selector(toggleRecordScreen))
        videoItem.state = settings.recordScreen ? .on : .off

        let t = Transcriber.shared
        let transcribeItem = NSMenuItem(title: "Auto-transcribe (Whisper)", action: #selector(toggleAutoTranscribe), keyEquivalent: "")
        transcribeItem.target = self
        if t.isAvailable {
            transcribeItem.state = settings.autoTranscribe ? .on : .off
        } else {
            transcribeItem.state = .off
            transcribeItem.isEnabled = false
            if t.resolvedWhisperPath == nil {
                transcribeItem.title = "Auto-transcribe (whisper-cpp not installed)"
            } else {
                transcribeItem.title = "Auto-transcribe (model not found)"
            }
        }
        menu.addItem(transcribeItem)

        let setupItem = NSMenuItem(title: "Whisper Setup…", action: #selector(openWhisperSetup), keyEquivalent: "")
        setupItem.target = self
        menu.addItem(setupItem)

        // --- Screen Memory Section ---
        menu.addItem(.separator())

        let screenItem = addMenuItem(menu, "Screen Memory", #selector(toggleScreenMemory))
        screenItem.state = settings.screenMemoryEnabled ? .on : .off

        let clipItem = addMenuItem(menu, "Save Clipboard", #selector(toggleClipboard))
        clipItem.state = settings.saveClipboard ? .on : .off

        // --- Clipboard History Submenu ---
        let clipHistoryItem = NSMenuItem(title: "Clipboard History", action: nil, keyEquivalent: "")
        let clipSubmenu = NSMenu()
        let entries = screenMemory?.clipboard.recentEntries ?? []
        if entries.isEmpty {
            let emptyItem = NSMenuItem(title: "Empty", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            clipSubmenu.addItem(emptyItem)
        } else {
            let outputURL = URL(fileURLWithPath: settings.outputPath)
            let mainFont = NSFont.menuFont(ofSize: 13)
            let dimAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.menuFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]

            for (i, entry) in entries.prefix(100).enumerated() {
                let timeStr = formatTime(entry.timestamp)
                let item = NSMenuItem(title: "", action: #selector(clipboardItemClicked(_:)), keyEquivalent: "")

                if entry.type == "image" {
                    let imagePath = outputURL.appendingPathComponent("screen")
                        .appendingPathComponent(dayString(entry.timestamp))
                        .appendingPathComponent(entry.content)
                    let label = entry.content.hasPrefix("clipboard-") ? "Screenshot" : "Image"

                    let str = NSMutableAttributedString()
                    str.append(NSAttributedString(string: "📷 \(label)  ", attributes: [.font: mainFont]))
                    str.append(NSAttributedString(string: timeStr, attributes: dimAttrs))
                    item.attributedTitle = str

                    if let nsImage = NSImage(contentsOf: imagePath) {
                        item.image = resizeImage(nsImage, to: NSSize(width: 32, height: 20))
                    }
                } else {
                    let preview = String(entry.content
                        .replacingOccurrences(of: "\n", with: " ")
                        .prefix(50))

                    let str = NSMutableAttributedString()
                    str.append(NSAttributedString(string: "\(preview)  ", attributes: [.font: mainFont]))
                    str.append(NSAttributedString(string: timeStr, attributes: dimAttrs))
                    item.attributedTitle = str
                    item.toolTip = String(entry.content.prefix(500))
                }

                item.target = self
                item.tag = i
                clipSubmenu.addItem(item)
            }
        }
        clipHistoryItem.submenu = clipSubmenu
        menu.addItem(clipHistoryItem)

        // --- Excluded Apps ---
        let excludedItem = NSMenuItem(title: "Excluded Apps…", action: nil, keyEquivalent: "")
        let excludedSubmenu = NSMenu()
        for bundleId in settings.excludedBundleIds {
            let name = appName(for: bundleId)
            let item = NSMenuItem(title: name, action: #selector(removeExcludedApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = bundleId
            excludedSubmenu.addItem(item)
        }
        excludedSubmenu.addItem(.separator())
        let addExcluded = NSMenuItem(title: "Add App…", action: #selector(addExcludedApp(_:)), keyEquivalent: "")
        addExcluded.target = self
        excludedSubmenu.addItem(addExcluded)
        excludedItem.submenu = excludedSubmenu
        menu.addItem(excludedItem)

        // --- General ---
        menu.addItem(.separator())

        let folderItem = NSMenuItem(title: "Output: \(shortenPath(settings.outputPath))", action: #selector(chooseFolder), keyEquivalent: "")
        folderItem.target = self
        menu.addItem(folderItem)

        addMenuItem(menu, "Open Folder", #selector(openFolder))

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @discardableResult
    private func addMenuItem(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    // MARK: - State Display

    private func stateLabel(_ state: RecordingState) -> String {
        if recordingManager?.isTranscribing == true && state == .idle {
            return "📝 Transcribing..."
        }
        switch state {
        case .idle: return "⏹ Not Recording"
        case .recording: return "🔴 Recording..."
        case .paused: return "⏸ Paused"
        case .starting: return "⏳ Starting..."
        case .stopping: return "⏳ Stopping..."
        }
    }

    private func updateStatusIcon(_ state: RecordingState) {
        if let button = statusItem.button {
            let color: NSColor
            switch state {
            case .recording: color = NSColor(red: 1.0, green: 0.1, blue: 0.1, alpha: 1.0)
            case .paused: color = .systemOrange
            case .starting, .stopping: color = .systemYellow
            case .idle: color = .systemGray
            }
            button.image = makeCircleIcon(color)
        }
        updateMenu()
    }

    // MARK: - Call Recording Actions

    @objc private func startRecording() { recordingManager.startRecording() }
    @objc private func pauseRecording() { recordingManager.pauseRecording() }
    @objc private func resumeRecording() { recordingManager.resumeRecording() }
    @objc private func stopRecording() { recordingManager.stopRecording() }

    @objc private func toggleAutoDetect() {
        settings.autoDetect.toggle()
        if settings.autoDetect { callDetector.startMonitoring() }
        else { callDetector.stopMonitoring() }
        updateMenu()
    }

    @objc private func toggleRecordScreen() {
        settings.recordScreen.toggle()
        updateMenu()
    }

    @objc private func toggleAutoTranscribe() {
        settings.autoTranscribe.toggle()
        updateMenu()
    }

    @objc private func openWhisperSetup() {
        WhisperSetupWindowController.shared.show()
    }

    // MARK: - Screen Memory Actions

    @objc private func toggleScreenMemory() {
        settings.screenMemoryEnabled.toggle()
        updateMenu()
    }

    @objc private func toggleClipboard() {
        settings.saveClipboard.toggle()
        updateMenu()
    }

    @objc private func clipboardItemClicked(_ sender: NSMenuItem) {
        let entries = screenMemory.clipboard.recentEntries
        guard sender.tag < entries.count else { return }
        let entry = entries[sender.tag]
        let pb = NSPasteboard.general
        pb.clearContents()

        if entry.type == "image" {
            let outputURL = URL(fileURLWithPath: settings.outputPath)
            let imagePath = outputURL.appendingPathComponent("screen")
                .appendingPathComponent(dayString(entry.timestamp))
                .appendingPathComponent(entry.content)
            if let image = NSImage(contentsOf: imagePath) {
                pb.writeObjects([image])
            }
        } else {
            pb.setString(entry.content, forType: .string)
        }
    }

    // MARK: - Excluded Apps

    @objc private func addExcludedApp(_ sender: NSMenuItem) {
        let menu = NSMenu()
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }

        for app in apps {
            guard let bundleId = app.bundleIdentifier else { continue }
            if settings.excludedBundleIds.contains(bundleId) { continue }
            let title = "\(app.localizedName ?? bundleId)"
            let item = NSMenuItem(title: title, action: #selector(appSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = bundleId
            if let icon = app.icon {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            menu.addItem(item)
        }

        if let event = NSApp.currentEvent, let view = sender.menu?.highlightedItem?.view ?? statusItem.button {
            menu.popUp(positioning: nil, at: .zero, in: view)
        }
    }

    @objc private func appSelected(_ sender: NSMenuItem) {
        guard let bundleId = sender.representedObject as? String else { return }
        var excluded = settings.excludedBundleIds
        excluded.append(bundleId)
        settings.excludedBundleIds = excluded
        updateMenu()
    }

    @objc private func removeExcludedApp(_ sender: NSMenuItem) {
        guard let bundleId = sender.representedObject as? String else { return }
        var excluded = settings.excludedBundleIds
        excluded.removeAll { $0 == bundleId }
        settings.excludedBundleIds = excluded
        updateMenu()
    }

    // MARK: - General Actions

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Select"
        panel.message = "Choose folder for recordings"
        if panel.runModal() == .OK, let url = panel.url {
            settings.outputPath = url.path
            updateMenu()
        }
    }

    @objc private func openFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: settings.outputPath))
    }

    @objc private func quit() {
        screenMemory.stop()
        recordingManager.stopRecording()
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        if Calendar.current.isDateInToday(date) {
            f.dateFormat = "HH:mm"
        } else {
            f.dateFormat = "dd.MM HH:mm"
        }
        return f.string(from: date)
    }

    private func shortenPath(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func appName(for bundleId: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId),
           let bundle = Bundle(url: url),
           let name = bundle.infoDictionary?["CFBundleName"] as? String {
            return "\(name) ✕"
        }
        return "\(bundleId) ✕"
    }

    private func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func resizeImage(_ image: NSImage, to size: NSSize) -> NSImage {
        let ratio = min(size.width / image.size.width, size.height / image.size.height)
        let newSize = NSSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let resized = NSImage(size: newSize)
        resized.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy, fraction: 1.0)
        resized.unlockFocus()
        return resized
    }
}

import AVFoundation
import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var recordingManager: RecordingManager!
    private var callDetector: CallDetector!
    private var screenMemory: ScreenMemoryManager!
    private let settings = SettingsManager.shared
    private var whisperAlertShown = false

    /// Signal sources are retained for the process's lifetime; a released
    /// DispatchSource stops delivering.
    private var signalSources: [DispatchSourceSignal] = []
    /// Set once shutdown has begun, so a second Quit (or a second SIGTERM from
    /// an impatient `memorai stop`) doesn't start the whole dance again.
    private var isTerminating = false
    private var hasRepliedToTermination = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupMainMenu()
        requestPermissions()
        settings.ensureOutputDirectory()

        // A crash leaves the audio tracks intact but nothing pointing at them:
        // no stop, no transcription, just two orphaned files. Adopt those
        // sessions before anything else touches the folder. Off the main thread
        // because repairing headers and starting a transcription must not hold
        // up the menu bar icon appearing.
        let recordingsDir = URL(fileURLWithPath: settings.outputPath)
        DispatchQueue.global(qos: .utility).async {
            CrashRecovery.recoverPending(in: recordingsDir, queueTranscription: true)
        }

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

        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: .memorAISettingsChanged, object: nil)

        installSignalHandlers()

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.checkTranscriptionSetup()
        }
    }

    // MARK: - Shutdown

    /// `memorai stop`, a `kill`, a logout — all arrive as signals, and without
    /// a handler they end the process instantly, mid-call, with the track files
    /// never closed. PCM means the audio survives that (see `AudioFormats`),
    /// but surviving it and ending cleanly are not the same thing: a clean end
    /// leaves files that need no repair and a marker that says so.
    ///
    /// DispatchSourceSignal rather than `signal()`: a C signal handler may only
    /// call async-signal-safe functions, and stopping an AVAudioEngine is about
    /// as far from that as it gets. The dispatch source turns the signal into
    /// an ordinary callback on the main queue instead.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            // The default disposition kills us before the source ever runs.
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                log("[AppDelegate] Получен сигнал \(sig) — корректно завершаюсь")
                // Route through the normal quit path so there is exactly one
                // shutdown sequence to reason about.
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Hold termination open until the tracks are on disk.
    ///
    /// Quitting used to be a race: `quit()` asked the recorder to stop (which
    /// does its work asynchronously) and then terminated the process
    /// immediately, so the documented way to leave the app could truncate the
    /// call you had just finished.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminating { return .terminateLater }

        screenMemory?.stop()

        guard let manager = recordingManager, manager.isRecordingInProgress else {
            // Transcription may still be running; it is interruptible by design
            // — the audio is on disk and the next launch resumes the session
            // from its marker.
            if recordingManager?.isTranscribing == true {
                log("[AppDelegate] Выхожу во время расшифровки — она продолжится при следующем запуске")
            }
            return .terminateNow
        }

        isTerminating = true
        log("[AppDelegate] Идёт запись — не выхожу, пока дорожки не дописаны")

        manager.finishForTermination { [weak self] in
            self?.replyToTermination(finished: true)
        }

        // A hung recorder must not make the app unquittable. Closing two audio
        // files takes well under a second (the stop path drains in-flight
        // buffers for 300 ms, then rewrites a CAF header); 20 s is generous
        // enough that only a genuinely stuck device hits it, and short enough
        // that a user waiting on the Dock does not conclude the app has hung.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.replyToTermination(finished: false)
        }

        return .terminateLater
    }

    private func replyToTermination(finished: Bool) {
        guard !hasRepliedToTermination else { return }
        hasRepliedToTermination = true
        if finished {
            log("[AppDelegate] Дорожки дописаны — выхожу")
        } else {
            log("[AppDelegate] ⚠️ Не дождался остановки записи за 20 с — выхожу. Запись на диске цела, при следующем запуске её подхватит восстановление.")
        }
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    /// Re-sync live behaviour after the Settings window changes something.
    @objc private func settingsChanged() {
        if settings.autoDetect { callDetector.startMonitoring() }
        else { callDetector.stopMonitoring() }
        updateMenu()
    }

    private func checkTranscriptionSetup() {
        guard !whisperAlertShown else { return }
        guard settings.autoTranscribe else { return }
        // Cloud engines are configured in Settings, not via this alert.
        let kind = TranscriptionEngineKind(rawValue: settings.transcriptionEngine) ?? .whisperLocal
        guard kind == .whisperLocal else { return }
        let engine = WhisperLocalEngine.shared
        guard !engine.isAvailable else { return }
        whisperAlertShown = true

        let alert = NSAlert()
        alert.addButton(withTitle: "Open Setup")
        alert.addButton(withTitle: "Dismiss")
        if engine.resolvedWhisperPath == nil {
            alert.messageText = "whisper-cpp not installed"
            alert.informativeText = "Auto-transcription requires whisper-cpp.\n\nIn Setup you can install it automatically via Homebrew, or pick a free cloud engine (Groq / Gemini) in Settings."
        } else {
            alert.messageText = "Whisper model not found"
            alert.informativeText = "whisper-cli is ready but no model file was found.\n\nIn Setup you can download a model in one click, or pick a free cloud engine in Settings."
        }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            WhisperSetupWindowController.shared.show()
        }
    }

    // MARK: - Main Menu

    /// Accessory apps have no menu bar, so standard text-editing key equivalents
    /// (⌘C/⌘V/⌘X/⌘A) never reach text fields. Installing a minimal Edit menu
    /// restores them in windows like Settings.
    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = mainMenu
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

        let engine = TranscriptionEngineFactory.current()
        let transcribeItem = NSMenuItem(title: "Auto-transcribe (\(engine.kind.shortName))", action: #selector(toggleAutoTranscribe), keyEquivalent: "")
        transcribeItem.target = self
        if engine.isAvailable {
            transcribeItem.state = settings.autoTranscribe ? .on : .off
        } else {
            transcribeItem.state = .off
            transcribeItem.isEnabled = false
            transcribeItem.title = "Auto-transcribe (\(engine.kind.shortName): \(engine.unavailableReason ?? "не настроено"))"
        }
        menu.addItem(transcribeItem)

        let settingsItem = NSMenuItem(title: "Настройки…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

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

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
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

    /// Stopping the recording and stopping screen memory both happen in
    /// `applicationShouldTerminate`, which is also where a signal ends up — one
    /// shutdown path, whether you chose Quit or something killed us politely.
    @objc private func quit() {
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

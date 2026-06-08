import Cocoa

extension Notification.Name {
    /// Posted when the user changes anything in the Settings window so the
    /// AppDelegate can re-sync live behaviour (call detection, menu state).
    static let memorAISettingsChanged = Notification.Name("memorAISettingsChanged")
}

/// Single Settings window with three sections: call recording, screen memory,
/// and transcription. Hand-laid-out AppKit, matching the app's existing style.
class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    static let shared = SettingsWindowController()

    private let settings = SettingsManager.shared
    private let engineKinds = TranscriptionEngineKind.allCases

    // Recording
    private var autoDetectCheck: NSButton!
    private var recordScreenCheck: NSButton!
    private var folderLabel: NSTextField!

    // Screen memory
    private var screenMemoryCheck: NSButton!
    private var clipboardCheck: NSButton!
    private var intervalSlider: NSSlider!
    private var intervalValue: NSTextField!
    private var qualitySlider: NSSlider!
    private var qualityValue: NSTextField!
    private var sensitivitySlider: NSSlider!
    private var sensitivityValue: NSTextField!

    // Transcription
    private var autoTranscribeCheck: NSButton!
    private var enginePopup: NSPopUpButton!
    private var languagePopup: NSPopUpButton!
    private var groqRow: [NSView] = []
    private var groqKeyField: NSSecureTextField!
    private var geminiRow: [NSView] = []
    private var geminiKeyField: NSSecureTextField!
    private var geminiModelField: NSTextField!
    private var whisperRow: [NSView] = []
    private var engineStatusLabel: NSTextField!

    private let langCodes = ["ru", "en", "auto"]

    private convenience init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 740),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Настройки MemorAI"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        buildUI()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible == false { window?.center() }
        showWindow(self)
        loadFromSettings()
        refresh()
    }

    // MARK: - Layout

    private let W: CGFloat = 520
    private let pad: CGFloat = 20
    private var fw: CGFloat { W - pad * 2 }
    private var y: CGFloat = 0

    private func buildUI() {
        guard let content = window?.contentView else { return }
        y = 740 - 36

        // ───────── Section: Запись звонков ─────────
        addHeader(content, "Запись звонков")
        autoDetectCheck = addCheckbox(content, "Авто-детект звонков (старт записи при разговоре)")
        recordScreenCheck = addCheckbox(content, "Записывать видео экрана во время звонка")
        addFolderRow(content)
        addSectionGap()

        // ───────── Section: Скриншоты экрана ─────────
        addHeader(content, "Скриншоты экрана (Screen Memory)")
        screenMemoryCheck = addCheckbox(content, "Снимать скриншоты экрана")
        clipboardCheck = addCheckbox(content, "Сохранять буфер обмена")
        (intervalSlider, intervalValue) = addSliderRow(content, "Интервал захвата", min: 1, max: 30)
        (qualitySlider, qualityValue) = addSliderRow(content, "Качество скриншота", min: 0.1, max: 1.0)
        (sensitivitySlider, sensitivityValue) = addSliderRow(content, "Порог изменения (меньше = чаще)", min: 2, max: 25)
        addSectionGap()

        // ───────── Section: Расшифровка ─────────
        addHeader(content, "Расшифровка речи")
        autoTranscribeCheck = addCheckbox(content, "Авто-расшифровка после записи")
        enginePopup = addPopupRow(content, "Движок", items: engineKinds.map { $0.displayName })
        languagePopup = addPopupRow(content, "Язык", items: ["Русский", "English", "Авто-определение"])

        // Groq row
        groqKeyField = NSSecureTextField()
        groqRow = addKeyRow(content, "Groq API-ключ", field: groqKeyField, getKeyTitle: "Получить ключ")

        // Gemini rows
        geminiKeyField = NSSecureTextField()
        geminiRow = addKeyRow(content, "Gemini API-ключ", field: geminiKeyField, getKeyTitle: "Получить ключ")
        geminiModelField = NSTextField()
        geminiRow += addPlainFieldRow(content, "Модель Gemini", field: geminiModelField,
                                      hint: "по умолчанию gemini-2.5-flash")

        // Whisper row
        whisperRow = addButtonRow(content, "Локальный Whisper", buttonTitle: "Настроить / скачать модель…",
                                  action: #selector(openWhisperSetup))

        engineStatusLabel = makeLabel("", size: 11)
        engineStatusLabel.frame = NSRect(x: pad, y: y, width: fw, height: 16)
        content.addSubview(engineStatusLabel)
        y -= 24

        let closeBtn = NSButton(title: "Готово", target: self, action: #selector(closeWindow))
        closeBtn.keyEquivalent = "\r"
        closeBtn.frame = NSRect(x: W - pad - 100, y: 12, width: 100, height: 30)
        content.addSubview(closeBtn)
    }

    // MARK: - Layout helpers

    private func makeLabel(_ text: String, size: CGFloat = 12, bold: Bool = false) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        f.lineBreakMode = .byTruncatingTail
        return f
    }

    private func addHeader(_ content: NSView, _ text: String) {
        let h = makeLabel(text, size: 13, bold: true)
        h.frame = NSRect(x: pad, y: y, width: fw, height: 20)
        content.addSubview(h)
        y -= 26
    }

    private func addSectionGap() {
        let sepView = NSBox(frame: NSRect(x: pad, y: y + 4, width: fw, height: 1))
        sepView.boxType = .separator
        window?.contentView?.addSubview(sepView)
        y -= 16
    }

    private func addCheckbox(_ content: NSView, _ title: String) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: #selector(controlChanged))
        b.frame = NSRect(x: pad, y: y, width: fw, height: 20)
        content.addSubview(b)
        y -= 28
        return b
    }

    private func addFolderRow(_ content: NSView) {
        let lbl = makeLabel("Папка:", size: 12)
        lbl.frame = NSRect(x: pad, y: y, width: 50, height: 20)
        content.addSubview(lbl)
        folderLabel = makeLabel("", size: 12)
        folderLabel.textColor = .secondaryLabelColor
        folderLabel.frame = NSRect(x: pad + 54, y: y, width: fw - 54 - 100, height: 20)
        content.addSubview(folderLabel)
        let btn = NSButton(title: "Изменить…", target: self, action: #selector(chooseFolder))
        btn.controlSize = .small
        btn.frame = NSRect(x: W - pad - 96, y: y - 2, width: 96, height: 24)
        content.addSubview(btn)
        y -= 30
    }

    private func addSliderRow(_ content: NSView, _ title: String, min: Double, max: Double) -> (NSSlider, NSTextField) {
        let lbl = makeLabel(title, size: 12)
        lbl.frame = NSRect(x: pad, y: y, width: 280, height: 20)
        content.addSubview(lbl)
        let valueLbl = makeLabel("", size: 12)
        valueLbl.alignment = .right
        valueLbl.textColor = .secondaryLabelColor
        valueLbl.frame = NSRect(x: W - pad - 70, y: y, width: 70, height: 20)
        content.addSubview(valueLbl)
        y -= 24
        let slider = NSSlider(value: min, minValue: min, maxValue: max, target: self, action: #selector(controlChanged))
        slider.frame = NSRect(x: pad, y: y, width: fw, height: 20)
        content.addSubview(slider)
        y -= 30
        return (slider, valueLbl)
    }

    private func addPopupRow(_ content: NSView, _ title: String, items: [String]) -> NSPopUpButton {
        let lbl = makeLabel(title, size: 12)
        lbl.frame = NSRect(x: pad, y: y, width: 110, height: 20)
        content.addSubview(lbl)
        let popup = NSPopUpButton(frame: NSRect(x: pad + 114, y: y - 2, width: fw - 114, height: 26))
        popup.addItems(withTitles: items)
        popup.target = self
        popup.action = #selector(controlChanged)
        content.addSubview(popup)
        y -= 32
        return popup
    }

    /// Secure key field + "Получить ключ" button row. Returns the views (for show/hide).
    private func addKeyRow(_ content: NSView, _ title: String, field: NSSecureTextField, getKeyTitle: String) -> [NSView] {
        let lbl = makeLabel(title, size: 12)
        lbl.frame = NSRect(x: pad, y: y, width: 110, height: 20)
        content.addSubview(lbl)
        field.frame = NSRect(x: pad + 114, y: y - 2, width: fw - 114 - 130, height: 24)
        field.placeholderString = "вставь ключ"
        field.delegate = self
        field.target = self
        field.action = #selector(controlChanged)
        content.addSubview(field)
        let btn = NSButton(title: getKeyTitle, target: self, action: #selector(openGetKey(_:)))
        btn.controlSize = .small
        btn.frame = NSRect(x: W - pad - 124, y: y - 2, width: 124, height: 24)
        btn.identifier = NSUserInterfaceItemIdentifier(title)
        content.addSubview(btn)
        y -= 30
        return [lbl, field, btn]
    }

    private func addPlainFieldRow(_ content: NSView, _ title: String, field: NSTextField, hint: String) -> [NSView] {
        let lbl = makeLabel(title, size: 12)
        lbl.frame = NSRect(x: pad, y: y, width: 110, height: 20)
        content.addSubview(lbl)
        field.frame = NSRect(x: pad + 114, y: y - 2, width: 200, height: 24)
        field.delegate = self
        field.target = self
        field.action = #selector(controlChanged)
        content.addSubview(field)
        let hintLbl = makeLabel(hint, size: 11)
        hintLbl.textColor = .tertiaryLabelColor
        hintLbl.frame = NSRect(x: pad + 114 + 208, y: y, width: fw - 114 - 208, height: 20)
        content.addSubview(hintLbl)
        y -= 30
        return [lbl, field, hintLbl]
    }

    private func addButtonRow(_ content: NSView, _ title: String, buttonTitle: String, action: Selector) -> [NSView] {
        let lbl = makeLabel(title, size: 12)
        lbl.frame = NSRect(x: pad, y: y, width: 110, height: 20)
        content.addSubview(lbl)
        let btn = NSButton(title: buttonTitle, target: self, action: action)
        btn.frame = NSRect(x: pad + 114, y: y - 4, width: fw - 114, height: 28)
        content.addSubview(btn)
        y -= 32
        return [lbl, btn]
    }

    // MARK: - Load / Save

    private func loadFromSettings() {
        autoDetectCheck.state = settings.autoDetect ? .on : .off
        recordScreenCheck.state = settings.recordScreen ? .on : .off
        folderLabel.stringValue = settings.outputPath.replacingOccurrences(of: NSHomeDirectory(), with: "~")

        screenMemoryCheck.state = settings.screenMemoryEnabled ? .on : .off
        clipboardCheck.state = settings.saveClipboard ? .on : .off
        intervalSlider.doubleValue = settings.captureInterval
        qualitySlider.doubleValue = settings.screenshotQuality
        sensitivitySlider.doubleValue = Double(settings.screenshotChangeThreshold)

        autoTranscribeCheck.state = settings.autoTranscribe ? .on : .off
        let kind = TranscriptionEngineKind(rawValue: settings.transcriptionEngine) ?? .whisperLocal
        enginePopup.selectItem(at: engineKinds.firstIndex(of: kind) ?? 0)
        languagePopup.selectItem(at: langCodes.firstIndex(of: settings.whisperLanguage) ?? 2)
        groqKeyField.stringValue = settings.groqApiKey
        geminiKeyField.stringValue = settings.geminiApiKey
        geminiModelField.stringValue = settings.geminiModel
    }

    private func applyToSettings() {
        settings.autoDetect = autoDetectCheck.state == .on
        settings.recordScreen = recordScreenCheck.state == .on

        settings.screenMemoryEnabled = screenMemoryCheck.state == .on
        settings.saveClipboard = clipboardCheck.state == .on
        settings.captureInterval = intervalSlider.doubleValue.rounded()
        settings.screenshotQuality = qualitySlider.doubleValue
        settings.screenshotChangeThreshold = Int(sensitivitySlider.doubleValue.rounded())

        settings.autoTranscribe = autoTranscribeCheck.state == .on
        settings.transcriptionEngine = engineKinds[enginePopup.indexOfSelectedItem].rawValue
        settings.whisperLanguage = langCodes[max(0, languagePopup.indexOfSelectedItem)]
        settings.groqApiKey = groqKeyField.stringValue
        settings.geminiApiKey = geminiKeyField.stringValue
        settings.geminiModel = geminiModelField.stringValue

        NotificationCenter.default.post(name: .memorAISettingsChanged, object: nil)
    }

    private func refresh() {
        intervalValue.stringValue = "\(Int(intervalSlider.doubleValue.rounded())) сек"
        qualityValue.stringValue = String(format: "%.2f", qualitySlider.doubleValue)
        sensitivityValue.stringValue = "\(Int(sensitivitySlider.doubleValue.rounded()))"

        let kind = engineKinds[max(0, enginePopup.indexOfSelectedItem)]
        setHidden(groqRow, kind != .groq)
        setHidden(geminiRow, kind != .gemini)
        setHidden(whisperRow, kind != .whisperLocal)

        let engine = TranscriptionEngineFactory.engine(for: kind)
        if engine.isAvailable {
            engineStatusLabel.stringValue = "✅ Готово к расшифровке"
            engineStatusLabel.textColor = .systemGreen
        } else {
            engineStatusLabel.stringValue = "⚠️ \(engine.unavailableReason ?? "не настроено")"
            engineStatusLabel.textColor = .systemOrange
        }
    }

    private func setHidden(_ views: [NSView], _ hidden: Bool) {
        views.forEach { $0.isHidden = hidden }
    }

    // MARK: - Actions

    @objc private func controlChanged() {
        applyToSettings()
        refresh()
    }

    func controlTextDidChange(_ obj: Notification) {
        applyToSettings()
        refresh()
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Выбрать"
        panel.message = "Папка для записей"
        if panel.runModal() == .OK, let url = panel.url {
            settings.outputPath = url.path
            folderLabel.stringValue = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            NotificationCenter.default.post(name: .memorAISettingsChanged, object: nil)
        }
    }

    @objc private func openGetKey(_ sender: NSButton) {
        let which = sender.identifier?.rawValue ?? ""
        let urlString = which.contains("Groq")
            ? "https://console.groq.com/keys"
            : "https://aistudio.google.com/app/apikey"
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }

    @objc private func openWhisperSetup() {
        WhisperSetupWindowController.shared.show()
    }

    @objc private func closeWindow() {
        applyToSettings()
        close()
    }
}

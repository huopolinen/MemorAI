import Cocoa

/// Setup window for the local GigaAM engine. Much smaller than the Whisper one
/// because there is nothing to install: the runtime ships inside the app, so
/// the only moving part is the model file.
class GigaAMSetupWindowController: NSWindowController {
    static let shared = GigaAMSetupWindowController()

    private let store = GigaAMModelStore.shared

    private var statusLabel: NSTextField!
    private var pathLabel: NSTextField!
    private var downloadButton: NSButton!
    private var deleteButton: NSButton!
    private var progressBar: NSProgressIndicator!
    private var progressLabel: NSTextField!

    private convenience init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 490, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "GigaAM — русская модель (офлайн)"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        buildUI()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible == false { window?.center() }
        showWindow(self)
        refresh()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let W: CGFloat = 490, pad: CGFloat = 20, fw = W - pad * 2

        func label(_ text: String, size: CGFloat = 12, bold: Bool = false) -> NSTextField {
            let f = NSTextField(labelWithString: text)
            f.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
            f.lineBreakMode = .byWordWrapping
            f.maximumNumberOfLines = 3
            return f
        }

        let title = label("GigaAM v3 — распознавание русской речи", size: 14, bold: true)
        title.frame = NSRect(x: pad, y: 242, width: fw, height: 20)
        content.addSubview(title)

        let blurb = label(
            "Модель Сбера, работает полностью на твоём Маке: ничего не уходит в облако "
            + "и не нужен ни Homebrew, ни API-ключ. В отличие от Whisper не выдумывает "
            + "«Субтитры сделал…» на паузах. Понимает только русский.", size: 11)
        blurb.textColor = .secondaryLabelColor
        blurb.frame = NSRect(x: pad, y: 194, width: fw, height: 46)
        content.addSubview(blurb)

        let mHead = label("Файл модели:", size: 11)
        mHead.textColor = .secondaryLabelColor
        mHead.frame = NSRect(x: pad, y: 170, width: fw, height: 16)
        content.addSubview(mHead)

        statusLabel = label("", size: 12)
        statusLabel.maximumNumberOfLines = 1
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.frame = NSRect(x: pad, y: 150, width: fw, height: 16)
        content.addSubview(statusLabel)

        pathLabel = label("", size: 11)
        pathLabel.maximumNumberOfLines = 1
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.textColor = .tertiaryLabelColor
        pathLabel.frame = NSRect(x: pad, y: 132, width: fw, height: 14)
        content.addSubview(pathLabel)

        downloadButton = NSButton(title: "Скачать модель  (\(GigaAMModelStore.sizeLabel))",
                                  target: self, action: #selector(startDownload))
        downloadButton.frame = NSRect(x: pad, y: 96, width: fw - 130, height: 28)
        content.addSubview(downloadButton)

        deleteButton = NSButton(title: "Удалить", target: self, action: #selector(deleteModel))
        deleteButton.frame = NSRect(x: W - pad - 122, y: 96, width: 122, height: 28)
        content.addSubview(deleteButton)

        progressBar = NSProgressIndicator(frame: NSRect(x: pad, y: 72, width: fw, height: 14))
        progressBar.minValue = 0; progressBar.maxValue = 1
        progressBar.isIndeterminate = false; progressBar.style = .bar
        progressBar.isHidden = true
        content.addSubview(progressBar)

        progressLabel = label("", size: 11)
        progressLabel.maximumNumberOfLines = 1
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.frame = NSRect(x: pad, y: 52, width: fw, height: 14)
        progressLabel.isHidden = true
        content.addSubview(progressLabel)

        let choose = NSButton(title: "Выбрать свой GGUF…", target: self, action: #selector(changeModelPath))
        choose.controlSize = .small
        choose.frame = NSRect(x: pad, y: 12, width: 180, height: 24)
        content.addSubview(choose)

        let closeBtn = NSButton(title: "Готово", target: self, action: #selector(closeWindow))
        closeBtn.frame = NSRect(x: W - pad - 100, y: 10, width: 100, height: 28)
        content.addSubview(closeBtn)
    }

    func refresh() {
        let path = store.modelPath
        pathLabel.stringValue = path.replacingOccurrences(of: NSHomeDirectory(), with: "~")

        if store.isInstalled {
            statusLabel.stringValue = "✅ Готово — \(store.bytesOnDisk / 1_048_576) МБ на диске"
            statusLabel.textColor = .labelColor
        } else if let reason = store.unavailableReason {
            statusLabel.stringValue = "❌ \(reason)"
            statusLabel.textColor = .systemRed
        }
        downloadButton.isEnabled = !store.isInstalled
        downloadButton.title = store.isInstalled
            ? "Модель скачана ✓"
            : "Скачать модель  (\(GigaAMModelStore.sizeLabel))"
        deleteButton.isEnabled = FileManager.default.fileExists(
            atPath: (GigaAMModelStore.defaultModelDir as NSString)
                .appendingPathComponent(GigaAMModelStore.fileName))
    }

    // MARK: - Actions

    @objc private func startDownload() {
        downloadButton.isEnabled = false
        deleteButton.isEnabled = false
        progressBar.doubleValue = 0
        progressBar.isHidden = false
        progressLabel.stringValue = "Соединяюсь…"
        progressLabel.isHidden = false

        store.download(
            progress: { [weak self] fraction in
                self?.progressBar.doubleValue = fraction
                self?.progressLabel.stringValue = fraction > 0
                    ? "Скачано \(Int(fraction * 100))% из \(GigaAMModelStore.sizeLabel)"
                    : "Соединяюсь…"
            },
            completion: { [weak self] error in
                self?.progressBar.isHidden = true
                if let error = error {
                    self?.progressLabel.stringValue = "❌ \(error.localizedDescription)"
                    self?.progressLabel.isHidden = false
                } else {
                    // The bar only ever reached 100 % of the transfer; the
                    // checksum ran after it, so say the model is actually usable.
                    self?.progressLabel.stringValue = "✅ Модель проверена и готова"
                    self?.progressLabel.isHidden = false
                }
                self?.refresh()
            })
    }

    @objc private func deleteModel() {
        // Freeing the loaded weights first: deleting a file the runtime still
        // has mapped leaves the next transcription running against a model
        // nobody can see on disk.
        GigaAMEngine.shared.releaseResources()
        do {
            try store.deleteManagedModel()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Не удалось удалить модель"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        progressLabel.isHidden = true
        refresh()
    }

    @objc private func changeModelPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Выбери файл модели GigaAM (*.gguf)"
        panel.prompt = "Выбрать"
        if panel.runModal() == .OK, let url = panel.url {
            GigaAMEngine.shared.releaseResources()
            SettingsManager.shared.gigaamModelPath = url.path
            refresh()
        }
    }

    @objc private func closeWindow() { close() }
}

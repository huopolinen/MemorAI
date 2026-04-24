import Cocoa

class WhisperSetupWindowController: NSWindowController {
    static let shared = WhisperSetupWindowController()

    private var whisperStatusLabel: NSTextField!
    private var installWhisperButton: NSButton!
    private var modelStatusLabel: NSTextField!
    private var downloadButton: NSButton!
    private var progressBar: NSProgressIndicator!
    private var progressLabel: NSTextField!

    private convenience init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 490, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Whisper Transcription Setup"
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
            f.lineBreakMode = .byTruncatingMiddle
            return f
        }
        func sep(y: CGFloat) -> NSBox {
            let b = NSBox(frame: NSRect(x: pad, y: y, width: fw, height: 1))
            b.boxType = .separator; return b
        }

        // ── Title ────────────────────────────────────────────────────────────
        let title = label("Whisper Transcription Setup", size: 14, bold: true)
        title.frame = NSRect(x: pad, y: 282, width: fw, height: 20)
        content.addSubview(title)

        // ── whisper-cli section ──────────────────────────────────────────────
        let wHead = label("whisper-cli binary:", size: 11)
        wHead.textColor = .secondaryLabelColor
        wHead.frame = NSRect(x: pad, y: 258, width: fw, height: 16)
        content.addSubview(wHead)

        whisperStatusLabel = label("", size: 12)
        whisperStatusLabel.frame = NSRect(x: pad, y: 236, width: fw - 100, height: 16)
        content.addSubview(whisperStatusLabel)

        let wChangeBtn = NSButton(title: "Change…", target: self, action: #selector(changeWhisperPath))
        wChangeBtn.frame = NSRect(x: W - pad - 90, y: 232, width: 90, height: 24)
        wChangeBtn.controlSize = .small
        content.addSubview(wChangeBtn)

        installWhisperButton = NSButton(
            title: "Install whisper-cpp via Homebrew…",
            target: self, action: #selector(installWhisperCpp))
        installWhisperButton.frame = NSRect(x: pad, y: 198, width: fw, height: 28)
        content.addSubview(installWhisperButton)

        let hint = label("Opens Terminal and runs: brew install whisper-cpp", size: 11)
        hint.textColor = .tertiaryLabelColor
        hint.frame = NSRect(x: pad, y: 182, width: fw, height: 14)
        content.addSubview(hint)

        content.addSubview(sep(y: 168))

        // ── Model section ────────────────────────────────────────────────────
        let mHead = label("Model file:", size: 11)
        mHead.textColor = .secondaryLabelColor
        mHead.frame = NSRect(x: pad, y: 148, width: fw, height: 16)
        content.addSubview(mHead)

        modelStatusLabel = label("", size: 12)
        modelStatusLabel.frame = NSRect(x: pad, y: 126, width: fw - 100, height: 16)
        content.addSubview(modelStatusLabel)

        let mChangeBtn = NSButton(title: "Change…", target: self, action: #selector(changeModelPath))
        mChangeBtn.frame = NSRect(x: W - pad - 90, y: 122, width: 90, height: 24)
        mChangeBtn.controlSize = .small
        content.addSubview(mChangeBtn)

        content.addSubview(sep(y: 108))

        downloadButton = NSButton(
            title: "Download ggml-base.bin  (~150 MB)",
            target: self, action: #selector(downloadModel))
        downloadButton.frame = NSRect(x: pad, y: 74, width: fw, height: 28)
        content.addSubview(downloadButton)

        progressBar = NSProgressIndicator(frame: NSRect(x: pad, y: 54, width: fw, height: 14))
        progressBar.minValue = 0; progressBar.maxValue = 1
        progressBar.isIndeterminate = false; progressBar.style = .bar
        progressBar.isHidden = true
        content.addSubview(progressBar)

        progressLabel = label("", size: 11)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.frame = NSRect(x: pad, y: 36, width: fw, height: 14)
        progressLabel.isHidden = true
        content.addSubview(progressLabel)

        // ── Close ────────────────────────────────────────────────────────────
        let closeBtn = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        closeBtn.frame = NSRect(x: W - pad - 80, y: 8, width: 80, height: 28)
        content.addSubview(closeBtn)
    }

    func refresh() {
        let t = Transcriber.shared
        let brewFound = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew")
                     || FileManager.default.fileExists(atPath: "/usr/local/bin/brew")

        if let wp = t.resolvedWhisperPath {
            whisperStatusLabel.stringValue = "✅ \(shorten(wp))"
            whisperStatusLabel.textColor = .labelColor
            installWhisperButton.isEnabled = false
            installWhisperButton.title = "whisper-cpp already installed"
        } else {
            whisperStatusLabel.stringValue = "❌ Not found"
            whisperStatusLabel.textColor = .systemRed
            installWhisperButton.isEnabled = brewFound
            installWhisperButton.title = brewFound
                ? "Install whisper-cpp via Homebrew…"
                : "Install whisper-cpp via Homebrew…  (Homebrew not found)"
        }

        let mp = t.resolvedModelPath
        if FileManager.default.fileExists(atPath: mp) {
            modelStatusLabel.stringValue = "✅ \(shorten(mp))"
            modelStatusLabel.textColor = .labelColor
            downloadButton.isEnabled = false
            downloadButton.title = "Model already downloaded"
        } else {
            modelStatusLabel.stringValue = "❌ Not found  (default: ~/.local/share/whisper-models/)"
            modelStatusLabel.textColor = .systemRed
            downloadButton.isEnabled = true
            downloadButton.title = "Download ggml-base.bin  (~150 MB)"
        }
    }

    // MARK: - Actions

    @objc private func installWhisperCpp() {
        let brew = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew")
            ? "/opt/homebrew/bin/brew"
            : "/usr/local/bin/brew"

        let cmd = "\(brew) install whisper-cpp"
        let script = """
        tell application "Terminal"
            activate
            do script "\(cmd)"
        end tell
        """
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)

        if let err {
            // Terminal AppleScript failed — copy command to clipboard instead
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
            let alert = NSAlert()
            alert.messageText = "Could not open Terminal"
            alert.informativeText = "Command copied to clipboard:\n\(cmd)\n\nPaste it in Terminal to install."
            alert.runModal()
        } else {
            // Poll until whisper-cli appears, then refresh
            checkForWhisperAfterInstall()
        }
    }

    private func checkForWhisperAfterInstall() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
            let found = Transcriber.shared.resolvedWhisperPath != nil
            DispatchQueue.main.async {
                if found {
                    self?.refresh()
                } else {
                    self?.checkForWhisperAfterInstall()
                }
            }
        }
    }

    @objc private func changeWhisperPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select whisper-cli binary"
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            SettingsManager.shared.whisperPath = url.path
            refresh()
        }
    }

    @objc private func changeModelPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select Whisper model file  (ggml-*.bin)"
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            SettingsManager.shared.modelPath = url.path
            refresh()
        }
    }

    @objc private func downloadModel() {
        downloadButton.isEnabled = false
        progressBar.doubleValue = 0
        progressBar.isHidden = false
        progressLabel.stringValue = "Connecting…"
        progressLabel.isHidden = false

        Transcriber.shared.downloadBaseModel(
            progress: { [weak self] p in
                self?.progressBar.doubleValue = p
                self?.progressLabel.stringValue = p > 0 ? "\(Int(p * 100))% downloaded" : "Connecting…"
            },
            completion: { [weak self] error in
                self?.progressBar.isHidden = true
                if let error = error {
                    self?.progressLabel.stringValue = "❌ \(error.localizedDescription)"
                    self?.progressLabel.isHidden = false
                    self?.downloadButton.isEnabled = true
                } else {
                    self?.progressLabel.isHidden = true
                }
                self?.refresh()
            }
        )
    }

    @objc private func closeWindow() { close() }

    private func shorten(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

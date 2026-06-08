import Cocoa

/// Setup window for the local Whisper engine: install whisper-cpp via Homebrew
/// and download a ggml model (medium for quality, or base for size).
class WhisperSetupWindowController: NSWindowController {
    static let shared = WhisperSetupWindowController()

    private let engine = WhisperLocalEngine.shared

    private var whisperStatusLabel: NSTextField!
    private var installBrewButton: NSButton!
    private var installBrewHint: NSTextField!
    private var installWhisperButton: NSButton!
    private var installWhisperHint: NSTextField!
    private var modelStatusLabel: NSTextField!
    private var downloadMediumButton: NSButton!
    private var downloadBaseButton: NSButton!
    private var progressBar: NSProgressIndicator!
    private var progressLabel: NSTextField!

    private convenience init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 490, height: 410),
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
        let title = label("Локальный Whisper", size: 14, bold: true)
        title.frame = NSRect(x: pad, y: 372, width: fw, height: 20)
        content.addSubview(title)

        // ── whisper-cli section ──────────────────────────────────────────────
        let wHead = label("whisper-cli binary:", size: 11)
        wHead.textColor = .secondaryLabelColor
        wHead.frame = NSRect(x: pad, y: 348, width: fw, height: 16)
        content.addSubview(wHead)

        whisperStatusLabel = label("", size: 12)
        whisperStatusLabel.frame = NSRect(x: pad, y: 326, width: fw - 100, height: 16)
        content.addSubview(whisperStatusLabel)

        let wChangeBtn = NSButton(title: "Change…", target: self, action: #selector(changeWhisperPath))
        wChangeBtn.frame = NSRect(x: W - pad - 90, y: 322, width: 90, height: 24)
        wChangeBtn.controlSize = .small
        content.addSubview(wChangeBtn)

        installBrewButton = NSButton(title: "1.  Install Homebrew…", target: self, action: #selector(installHomebrew))
        installBrewButton.frame = NSRect(x: pad, y: 288, width: fw, height: 28)
        content.addSubview(installBrewButton)

        installBrewHint = label("Opens Terminal: /bin/bash -c \"$(curl … Homebrew/install)\"", size: 11)
        installBrewHint.textColor = .tertiaryLabelColor
        installBrewHint.frame = NSRect(x: pad, y: 272, width: fw, height: 14)
        content.addSubview(installBrewHint)

        installWhisperButton = NSButton(title: "Install whisper-cpp via Homebrew…", target: self, action: #selector(installWhisperCpp))
        installWhisperButton.frame = NSRect(x: pad, y: 250, width: fw, height: 28)
        content.addSubview(installWhisperButton)

        installWhisperHint = label("Opens Terminal and runs: brew install whisper-cpp", size: 11)
        installWhisperHint.textColor = .tertiaryLabelColor
        installWhisperHint.frame = NSRect(x: pad, y: 234, width: fw, height: 14)
        content.addSubview(installWhisperHint)

        content.addSubview(sep(y: 220))

        // ── Model section ────────────────────────────────────────────────────
        let mHead = label("Model file:", size: 11)
        mHead.textColor = .secondaryLabelColor
        mHead.frame = NSRect(x: pad, y: 200, width: fw, height: 16)
        content.addSubview(mHead)

        modelStatusLabel = label("", size: 12)
        modelStatusLabel.frame = NSRect(x: pad, y: 178, width: fw - 100, height: 16)
        content.addSubview(modelStatusLabel)

        let mChangeBtn = NSButton(title: "Change…", target: self, action: #selector(changeModelPath))
        mChangeBtn.frame = NSRect(x: W - pad - 90, y: 174, width: 90, height: 24)
        mChangeBtn.controlSize = .small
        content.addSubview(mChangeBtn)

        let dlHead = label("Скачать модель (medium — заметно точнее base):", size: 11)
        dlHead.textColor = .secondaryLabelColor
        dlHead.frame = NSRect(x: pad, y: 150, width: fw, height: 14)
        content.addSubview(dlHead)

        let halfW = (fw - 8) / 2
        downloadMediumButton = NSButton(title: "medium  (~1.5 GB)", target: self, action: #selector(downloadMedium))
        downloadMediumButton.frame = NSRect(x: pad, y: 120, width: halfW, height: 28)
        content.addSubview(downloadMediumButton)

        downloadBaseButton = NSButton(title: "base  (~150 MB)", target: self, action: #selector(downloadBase))
        downloadBaseButton.frame = NSRect(x: pad + halfW + 8, y: 120, width: halfW, height: 28)
        content.addSubview(downloadBaseButton)

        progressBar = NSProgressIndicator(frame: NSRect(x: pad, y: 92, width: fw, height: 14))
        progressBar.minValue = 0; progressBar.maxValue = 1
        progressBar.isIndeterminate = false; progressBar.style = .bar
        progressBar.isHidden = true
        content.addSubview(progressBar)

        progressLabel = label("", size: 11)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.frame = NSRect(x: pad, y: 72, width: fw, height: 14)
        progressLabel.isHidden = true
        content.addSubview(progressLabel)

        content.addSubview(sep(y: 56))

        let hint = label("Совет: для приватности — локальный Whisper; для лучшего качества выбери Groq или Gemini в Настройках.", size: 11)
        hint.textColor = .tertiaryLabelColor
        hint.lineBreakMode = .byWordWrapping
        hint.frame = NSRect(x: pad, y: 40, width: fw, height: 14)
        content.addSubview(hint)

        let closeBtn = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        closeBtn.frame = NSRect(x: W - pad - 80, y: 8, width: 80, height: 28)
        content.addSubview(closeBtn)
    }

    func refresh() {
        let fm = FileManager.default
        let brewPath = resolvedBrewPath()

        // ── whisper status ───────────────────────────────────────────────────
        if let wp = engine.resolvedWhisperPath {
            whisperStatusLabel.stringValue = "✅ \(shorten(wp))"
            whisperStatusLabel.textColor = .labelColor
            installBrewButton.isHidden = true
            installBrewHint.isHidden = true
            installWhisperButton.isHidden = true
            installWhisperHint.isHidden = true
        } else if brewPath != nil {
            whisperStatusLabel.stringValue = "❌ Not found"
            whisperStatusLabel.textColor = .systemRed
            installBrewButton.isHidden = true
            installBrewHint.isHidden = true
            installWhisperButton.isHidden = false
            installWhisperButton.isEnabled = true
            installWhisperButton.title = "Install whisper-cpp via Homebrew…"
            installWhisperHint.isHidden = false
        } else {
            whisperStatusLabel.stringValue = "❌ Not found  (Homebrew required)"
            whisperStatusLabel.textColor = .systemRed
            installBrewButton.isHidden = false
            installBrewButton.isEnabled = true
            installBrewHint.isHidden = false
            installWhisperButton.isHidden = false
            installWhisperButton.isEnabled = false
            installWhisperButton.title = "2.  Install whisper-cpp via Homebrew…"
            installWhisperHint.isHidden = false
        }

        // ── model status ─────────────────────────────────────────────────────
        let mp = engine.resolvedModelPath
        if fm.fileExists(atPath: mp) {
            modelStatusLabel.stringValue = "✅ \(shorten(mp))"
            modelStatusLabel.textColor = .labelColor
        } else {
            modelStatusLabel.stringValue = "❌ Not found  (default: ~/.local/share/whisper-models/)"
            modelStatusLabel.textColor = .systemRed
        }
        let mediumPresent = fm.fileExists(atPath: (WhisperLocalEngine.defaultModelDir as NSString).appendingPathComponent("ggml-medium.bin"))
        let basePresent = fm.fileExists(atPath: (WhisperLocalEngine.defaultModelDir as NSString).appendingPathComponent("ggml-base.bin"))
        downloadMediumButton.isEnabled = !mediumPresent
        downloadMediumButton.title = mediumPresent ? "medium ✓" : "medium  (~1.5 GB)"
        downloadBaseButton.isEnabled = !basePresent
        downloadBaseButton.title = basePresent ? "base ✓" : "base  (~150 MB)"
    }

    // MARK: - Actions

    @objc private func installHomebrew() {
        let cmd = "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        runInTerminal(cmd) {
            self.pollUntil(condition: { self.resolvedBrewPath() != nil }, then: { self.refresh() })
        }
    }

    @objc private func installWhisperCpp() {
        guard let brew = resolvedBrewPath() else { return }
        runInTerminal("\(brew) install whisper-cpp") {
            self.pollUntil(condition: { self.engine.resolvedWhisperPath != nil }, then: { self.refresh() })
        }
    }

    private func runInTerminal(_ cmd: String, onSuccess: @escaping () -> Void) {
        let script = """
        tell application "Terminal"
            activate
            do script "\(cmd.replacingOccurrences(of: "\"", with: "\\\""))"
        end tell
        """
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if err != nil {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
            let alert = NSAlert()
            alert.messageText = "Could not open Terminal automatically"
            alert.informativeText = "Command copied to clipboard — paste it in Terminal:\n\n\(cmd)"
            alert.runModal()
        } else {
            onSuccess()
        }
    }

    private func pollUntil(condition: @escaping () -> Bool, then: @escaping () -> Void) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
            guard self != nil else { return }
            if condition() {
                DispatchQueue.main.async { then() }
            } else {
                self?.pollUntil(condition: condition, then: then)
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

    @objc private func downloadMedium() { startDownload(named: "ggml-medium.bin") }
    @objc private func downloadBase() { startDownload(named: "ggml-base.bin") }

    private func startDownload(named modelName: String) {
        downloadMediumButton.isEnabled = false
        downloadBaseButton.isEnabled = false
        progressBar.doubleValue = 0
        progressBar.isHidden = false
        progressLabel.stringValue = "Connecting…"
        progressLabel.isHidden = false

        engine.downloadModel(
            named: modelName,
            progress: { [weak self] p in
                self?.progressBar.doubleValue = p
                self?.progressLabel.stringValue = p > 0 ? "\(modelName): \(Int(p * 100))% downloaded" : "Connecting…"
            },
            completion: { [weak self] error in
                self?.progressBar.isHidden = true
                if let error = error {
                    self?.progressLabel.stringValue = "❌ \(error.localizedDescription)"
                    self?.progressLabel.isHidden = false
                } else {
                    self?.progressLabel.isHidden = true
                }
                self?.refresh()
            }
        )
    }

    @objc private func closeWindow() { close() }

    // MARK: - Helpers

    private func resolvedBrewPath() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first {
            FileManager.default.fileExists(atPath: $0)
        }
    }

    private func shorten(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

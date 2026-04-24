import Cocoa

class WhisperSetupWindowController: NSWindowController {
    static let shared = WhisperSetupWindowController()

    private var whisperStatusLabel: NSTextField!
    private var installBrewButton: NSButton!
    private var installBrewHint: NSTextField!
    private var installWhisperButton: NSButton!
    private var installWhisperHint: NSTextField!
    private var modelStatusLabel: NSTextField!
    private var downloadButton: NSButton!
    private var progressBar: NSProgressIndicator!
    private var progressLabel: NSTextField!

    private convenience init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 490, height: 358),
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
        title.frame = NSRect(x: pad, y: 320, width: fw, height: 20)
        content.addSubview(title)

        // ── whisper-cli section ──────────────────────────────────────────────
        let wHead = label("whisper-cli binary:", size: 11)
        wHead.textColor = .secondaryLabelColor
        wHead.frame = NSRect(x: pad, y: 296, width: fw, height: 16)
        content.addSubview(wHead)

        whisperStatusLabel = label("", size: 12)
        whisperStatusLabel.frame = NSRect(x: pad, y: 274, width: fw - 100, height: 16)
        content.addSubview(whisperStatusLabel)

        let wChangeBtn = NSButton(title: "Change…", target: self, action: #selector(changeWhisperPath))
        wChangeBtn.frame = NSRect(x: W - pad - 90, y: 270, width: 90, height: 24)
        wChangeBtn.controlSize = .small
        content.addSubview(wChangeBtn)

        // Step 1 — Install Homebrew (shown only when brew is missing)
        installBrewButton = NSButton(
            title: "1.  Install Homebrew…",
            target: self, action: #selector(installHomebrew))
        installBrewButton.frame = NSRect(x: pad, y: 236, width: fw, height: 28)
        content.addSubview(installBrewButton)

        installBrewHint = label("Opens Terminal: /bin/bash -c \"$(curl … Homebrew/install)\"", size: 11)
        installBrewHint.textColor = .tertiaryLabelColor
        installBrewHint.frame = NSRect(x: pad, y: 220, width: fw, height: 14)
        content.addSubview(installBrewHint)

        // Step 2 — Install whisper-cpp
        installWhisperButton = NSButton(
            title: "Install whisper-cpp via Homebrew…",
            target: self, action: #selector(installWhisperCpp))
        installWhisperButton.frame = NSRect(x: pad, y: 198, width: fw, height: 28)  // shifts up when brew row hidden
        content.addSubview(installWhisperButton)

        installWhisperHint = label("Opens Terminal and runs: brew install whisper-cpp", size: 11)
        installWhisperHint.textColor = .tertiaryLabelColor
        installWhisperHint.frame = NSRect(x: pad, y: 182, width: fw, height: 14)
        content.addSubview(installWhisperHint)

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
        let fm = FileManager.default
        let brewPath = resolvedBrewPath()

        // ── whisper status ───────────────────────────────────────────────────
        if let wp = t.resolvedWhisperPath {
            whisperStatusLabel.stringValue = "✅ \(shorten(wp))"
            whisperStatusLabel.textColor = .labelColor
            // whisper is installed — hide both install steps
            installBrewButton.isHidden = true
            installBrewHint.isHidden = true
            installWhisperButton.isHidden = true
            installWhisperHint.isHidden = true
        } else if let _ = brewPath {
            // Homebrew found, whisper missing → show step 2 only
            whisperStatusLabel.stringValue = "❌ Not found"
            whisperStatusLabel.textColor = .systemRed
            installBrewButton.isHidden = true
            installBrewHint.isHidden = true
            installWhisperButton.isHidden = false
            installWhisperButton.isEnabled = true
            installWhisperButton.title = "Install whisper-cpp via Homebrew…"
            installWhisperHint.isHidden = false
        } else {
            // No Homebrew at all → show both steps
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
        let mp = t.resolvedModelPath
        if fm.fileExists(atPath: mp) {
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

    @objc private func installHomebrew() {
        let cmd = "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        runInTerminal(cmd) {
            // After Homebrew installs, poll until brew binary appears
            self.pollUntil(
                condition: { self.resolvedBrewPath() != nil },
                then: { self.refresh() }
            )
        }
    }

    @objc private func installWhisperCpp() {
        guard let brew = resolvedBrewPath() else { return }
        runInTerminal("\(brew) install whisper-cpp") {
            self.pollUntil(
                condition: { Transcriber.shared.resolvedWhisperPath != nil },
                then: { self.refresh() }
            )
        }
    }

    // Opens Terminal with `cmd`. Calls `onSuccess` if AppleScript succeeded; copies to clipboard otherwise.
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

    /// Polls every 5 s (background) until `condition` is true, then calls `then` on main thread.
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

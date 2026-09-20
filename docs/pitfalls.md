# Pitfalls

Grabbed from reading `amanu` (github.com/gsamat/amanu, MIT) — a more mature
macOS meeting recorder that hit and wrote down two dozen of these. Each entry
below is amanu's lesson, checked against our own code, with a verdict:

- **У нас есть эта проблема** — verified against our files, present now.
- **У нас закрыто** — verified, we don't have it, and where/why.
- **Не применимо** — the mechanism amanu describes doesn't exist in our
  architecture, so the pitfall has nothing to attach to.
- **Не проверено** — plausible but not checked against running behaviour;
  said explicitly rather than guessed.

Where amanu's text is the source of a claim and we haven't independently
measured it for MemorAI, that's said outright.

## Three different code-signing recipes for one bundle identifier

**У нас есть эта проблема.** amanu's write-up: TCC grants are keyed to the
*code signature identity* plus the bundle id; change either and macOS
re-prompts, leaving stale rows in System Settings. We have three build
scripts that each sign `com.local.memorai` differently:

| script | identity | hardened runtime | entitlements |
|---|---|---|---|
| `bundle.sh:8-19` | auto: `Developer ID Application` → `Apple Development` → ad-hoc `-` | on (`--options runtime`, line 44) | `audio-input` only (lines 31-40) |
| `release-notarized.sh:20` | hardcoded `Developer ID Application: NEO, OOO` | on, with `--timestamp` (lines 57-61) | `audio-input` + `screen-capture` (lines 33-44) |
| `install.sh:35` | always ad-hoc (`--sign -`) | **off** — no `--options runtime` | **none at all** |

`install.sh:16-19` unconditionally runs `tccutil reset ScreenCapture
Microphone Accessibility ListenEvent com.local.memorai` on every single
install. That line is itself evidence of the problem this section is about —
it's a standing workaround for TCC state that the project's own signing
inconsistency keeps invalidating, not a deliberate UX choice.

On *this* machine right now, `bundle.sh`'s auto-detection happens to resolve
to the same `Developer ID Application: NEO, OOO (Z97S2HH3V5)` identity as
`release-notarized.sh` (checked with `security find-identity -v -p
codesigning` — both a Developer ID and several Apple Development certs are
present). So the risk is currently latent on this machine, not actively
firing. It would fire the moment that certificate is absent, expired, or a
different machine builds it — `bundle.sh` silently falls back to ad-hoc
signing with only an `echo "⚠️ ... TCC will reset on every rebuild"` warning,
easy to miss in a long build log.

`README.md:39` documents `bash bundle.sh && open MemorAI.app` as *the* build
path — this isn't a theoretical dev-only script, it's what a person cloning
the repo is told to run.

## Starting the app from a terminal gives its permissions to the terminal

**У нас закрыто**, for every path we actually document and ship, verified by
reading the exact launch commands:

- `memorai` CLI, `cmd_start` (`memorai:245`): `open "$APP_PATH"`.
- `install.sh:57`: `open /Applications/MemorAI.app`.
- `README.md:40`: `open MemorAI.app`.

All three go through `open(1)`, which hands off to LaunchServices rather than
exec'ing the binary as a child of the shell — this is the same distinction
amanu's own fix relies on (`Run hands over to LaunchServices ... which is
what lets amanu setup out of the README be safe`). None of our shipped or
documented flows exec the raw binary from a shell.

**Latent risk, not part of any shipped flow:** running `.build/release/MemorAI`
directly (`swift run`, or executing the built binary by hand) during
day-to-day Swift development *is* exactly the shell-exec pattern amanu
measured as dangerous — no bundle, no `CFBundleIdentifier`, responsible
process is Terminal. A developer testing mic/screen capture that way could
see a false "it works" because Terminal already holds those grants, while
the packaged `.app` has none. Worth a line in `CLAUDE.md`/README for whoever
iterates on audio/screen code, not worth changing any shipped script for.

## The hardened runtime closes what isn't declared, and does it silently

**У нас есть эта проблема** as a verified divergence; **не проверено**
whether it currently breaks anything at runtime.

`bundle.sh`'s entitlements (lines 31-40) declare only
`com.apple.security.device.audio-input`. `release-notarized.sh` (lines
33-44) and the older `build-app.sh` (lines 21-32) both also declare
`com.apple.security.device.screen-capture`. We have not built and run a
`bundle.sh`-signed binary to see whether `SCShareableContent`/`SCStream`
(`SystemAudioRecorder.swift:74`) actually needs that entitlement outside App
Sandbox — Screen Recording is primarily TCC-gated via
`NSScreenCaptureUsageDescription` (already in `Info.plist:25-26`), and it's
possible this entitlement key does nothing for a non-sandboxed app. amanu's
own EventKit story is the reason to take the divergence seriously rather
than dismiss it: a missing hardened-runtime resource entitlement fails
*before* TCC is even consulted, with no prompt and no log line — indistinguishable
from "user hasn't granted it yet." Cheap to close by just matching the three
scripts; expensive to debug later if it turns out to matter.

`install.sh` doesn't enable hardened runtime at all, so entitlements are
moot for that path specifically — but that's its own problem (see above).

## Nested code is signed innermost first

**Не применимо сейчас.** `Package.swift:8-27` links system frameworks only
(`Cocoa`, `AVFoundation`, `ScreenCaptureKit`, `CoreAudio`, `Vision`,
`ApplicationServices`, `UniformTypeIdentifiers`); none of the three bundle
scripts embed any framework or dylib into `Contents/Frameworks`. There is
nothing to sign in the wrong order today.

**Nearest risk, not hypothetical:** a sibling worktree/branch
`feat/local-ru-engine` exists in this repo right now (`git worktree list`).
A "local" transcription engine that isn't `whisper-cli` shelled out to
(`WhisperLocalEngine.swift:14-16`, which just execs a Homebrew binary — no
embedded code today) strongly suggests a bundled model runtime or compiled
framework is about to show up. Whoever lands that needs to sign it before
`MemorAI.app` itself in **all three** `*.sh` scripts, not just the one they
touch — otherwise two of the three build paths will produce an app whose
seal `codesign --verify` can still pass locally on but Gatekeeper rejects
elsewhere, exactly the failure shape amanu describes.

## Asking macOS what it has granted, in a redraw loop

**У нас закрыто — by absence of the feature, not by a cache.** Grepped the
whole of `AutoRec/` for `authorizationStatus`, `CGPreflightScreenCaptureAccess`,
`AXIsProcessTrusted` (read form), `SMAppService`: the only permission-status
call anywhere is `AXIsProcessTrustedWithOptions` in
`AppDelegate.swift:126`, inside `requestPermissions()`, called exactly once
from `applicationDidFinishLaunching` (`AppDelegate.swift:16`). `updateMenu()`
(`AppDelegate.swift:156`, called from `menuWillOpen` on every menu open) reads
only in-process state (`recordingManager?.state`) — no syscalls, no XPC round
trips. There is no equivalent of amanu's `doctor`/setup-window status polling
at all, so this specific perf pitfall can't occur — but see the actions doc
for the gap that leaves (no cheap self-diagnostic exists either).

## `NSColor`/`CGColor` and dark mode

**Не применимо.** Grepped for `cgColor`, `CALayer`, `.layer.` across
`AutoRec/`: the only `NSColor` uses are `AppDelegate.swift:139` (fills an
`NSBezierPath` for the menu-bar dot icon — drawn fresh every state change via
`NSImage(size:flipped:)`, not cached into a layer), `AppDelegate.swift:223`
(a `NSAttributedString` foreground color), and `AppDelegate.swift:326` (sets
a local `NSColor` variable, same icon-drawing path). Nothing reads
`.cgColor` and hands it to a `CALayer`, so there's no stale-color-across-
appearance-change surface for amanu's pitfall to land on. `SettingsWindowController.swift`
and `WhisperSetupWindowController.swift` use plain AppKit controls with no
custom layer painting.

## A capture restart is where the fixes amanu made for AEC and timing live — we don't have the mechanism they're fixing

**У нас есть a related but different problem.** We never call
`setVoiceProcessingEnabled` anywhere (grepped `AutoRec/` for
`VoiceProcessing`/`voiceProcessing`: zero matches), so amanu's specific
failure — echo cancellation silently dropping on a route-change restart and
recording the far end back into the mic track — has nothing to attach to;
we never turn AEC on in the first place, so it can't be turned off by a
restart.

What *is* structurally present, read from `MicRecorder.swift`:

- `handleConfigChange()` (`MicRecorder.swift:168-179`) tears the engine down
  and restarts it on `.AVAudioEngineConfigurationChange`, and is *also* the
  function the watchdog calls on a stall (`checkWatchdog` →
  `handleConfigChange`, `MicRecorder.swift:190-197`). There is no attempt
  anywhere to tell "our own change" apart from a genuinely dead engine — amanu's
  5-second liveness-before-blaming window has no counterpart here.
- No storm guard: three rapid restarts (AirPods connecting, then
  disconnecting, then reconnecting inside a minute — an ordinary sequence)
  each tear down and rebuild the whole `AVAudioEngine` with no backoff.
- No gap marking or silence padding at all across a restart. amanu measured
  a mis-timed pad as a half-second-scale error against a reference
  recording; we don't even attempt the pad, so whatever the real gap is (engine
  restart takes real wall-clock time) is just missing from the file, with
  nothing recorded anywhere that it happened.

This file is currently owned by a parallel agent, so no patch is proposed
here — this is a description for whoever picks it up next, per the task
that requested this audit.

## Silent system-audio failure only being caught at setup

**Частично закрыто, по-другому, чем у amanu.** amanu's Core Audio process
tap (`AudioHardwareCreateProcessTap`) returns `noErr` and delivers
well-formed, all-zero buffers when unauthorized — no error at any layer,
caught only by amanu's own later-added level check. We use ScreenCaptureKit
(`SystemAudioRecorder.swift:74`, `SCShareableContent.excludingDesktopWindows`)
instead of the raw process tap. ScreenCaptureKit's documented behavior is to
throw when the process lacks Screen Recording authorization, rather than
start and deliver silence — **not independently verified by us against a
revoked grant**, but if true it means our failure mode is fail-fast rather
than fail-silent at the API layer, which is the better of the two shapes.

That said, we do have our own version of "silent to the user": `RecordingManager.startRecording`
(`RecordingManager.swift:53-91`) catches `sysRec.start()` throwing, logs it
(`RecordingManager.swift:87`), resets state to idle, and stops — **with no
`NSAlert`, no notification, nothing in the menu beyond the dot staying
gray.** The only `NSAlert` in the whole app (`AppDelegate.swift:81`,
`checkTranscriptionSetup`) is about missing whisper-cpp/model, unrelated. A
person whose Screen Recording grant gets revoked (OS update, `tccutil`,
System Settings) would see recording silently never start, discoverable only
by opening `memorai.log`.

We do have a mid-recording level check amanu's team added *after* the fact
(their `rca-002`/`010`): `SystemAudioRecorder`'s warmup timer
(`onSystemAudioUnavailable`, `SystemAudioRecorder.swift:41-53`) fires if no
non-silent buffer arrives within 30s of starting — this runs on every
recording, not only at setup, so it's ahead of where amanu started rather
than behind. Whether it also fires correctly is **не проверено**.

## No SIGTERM handling, and no crash recovery

**У нас есть эта проблема, шире, чем у amanu на момент их находки.** amanu's
`006`/`009` describe a daemon that (eventually) does handle `SIGTERM`
cleanly and does recover an interrupted session on next launch, with a
crash-tolerant CAF audio format specifically chosen because AAC produces
`estimated duration: 0.000000 sec` when killed mid-write. We have none of
those three layers:

- **No signal handler at all.** Grepped `AutoRec/` for `SIGTERM`, `signal(`:
  nothing. `main.swift` installs no `DispatchSource` signal handlers.
- **The graceful path has an unguarded race.** `AppDelegate.quit()`
  (`AppDelegate.swift:458-461`) calls `recordingManager.stopRecording()`
  then immediately `NSApp.terminate(nil)`. But `stopRecording()`
  (`RecordingManager.swift:116-125`) fires off `Task { ... }` and *returns
  immediately* — the actual `micRecorder?.stop()`, `await
  systemAudioRecorder?.stop()` (which itself has a 300ms drain sleep plus
  two separate `await ... finishWriting` calls — `SystemAudioRecorder.swift:236-244`)
  run asynchronously, with nothing holding termination open for them.
  `applicationShouldTerminate` isn't implemented, so nothing tells AppKit
  to wait. Read straight from the code, this is a real race: quitting via
  the menu item during an active call recording can plausibly kill the
  process before the `AVAssetWriter`s for the system-audio `.m4a` and
  screen `.mp4` finish writing.
- **Our audio containers don't tolerate a mid-write kill the way amanu's CAF
  does.** Both the mic track (`MicRecorder.makeAudioFile`,
  `MicRecorder.swift:130-141`, AAC via `AVAudioFile`) and the system track
  (`SystemAudioRecorder`, AAC via `AVAssetWriter` into `.m4a`) are exactly
  the container/codec combination amanu's own README documents killing and
  getting `afinfo` to report zero duration on — the mp4/m4a container needs
  its index finalized by `finishWriting`/a clean close, or it isn't just
  truncated, it can be unreadable.
- **No recovery on next launch.** Grepped for `recover`, `interrupted`,
  `crash`: nothing. A folder left behind by an abrupt kill sits there
  looking like nothing ever happened; there's no manifest-writing/adoption
  step the way `RecordingSession.recoverInterrupted` does for amanu.

`memorai stop`/`restart` make this reachable without any OS-level event at
all: `cmd_stop` (`memorai:251`) is `pkill -f "MemorAI"` — plain `SIGTERM`,
default disposition since nothing traps it, so it's an unconditional
immediate kill of whatever `MemorAI` process is running, mid-call or not.

## No App Nap protection

**У нас есть эта проблема; не измерено.** amanu holds a `userInitiated`
activity for its whole life and a sleep-blocking one while recording,
specifically because the symptom of losing either is "confusing rather than
obvious: IPC that answers seconds late, timers that drift." Grepped
`AutoRec/` for `ProcessInfo`, `beginActivity`, `NSActivity`: no matches
anywhere. MemorAI is `LSUIElement` (`Info.plist:19-20`, no Dock icon, never
frontmost) and runs several continuous timers the whole time it's open —
`CallDetector`'s 2s poll (`CallDetector.swift:23,41`), `MicRecorder`'s 5s
watchdog (`MicRecorder.swift:19,181-189`), the configurable screenshot
interval in `ScreenMemoryManager`. We have not measured timer drift or
delayed callbacks under App Nap on a real machine — flagging this as
unverified, not as a confirmed bug, but there is zero mitigating code where
amanu has explicit code for exactly this reason.

## CallDetector uses a macOS-14.2-only API with no floor guard

**У нас есть эта проблема, вероятно некритично.** amanu's `old-macs.md`
documents per-process microphone detection as a macOS 14.4 API used behind
an `@available` check, with an explicit degraded message ("recording still
works, but automatic call detection is less precise"). Our
`CallDetector.swift:8-9` says in its own doc comment "Uses the per-process
CoreAudio API (macOS 14.2+)" and then calls
`kAudioHardwarePropertyProcessObjectList` / `kAudioProcessPropertyIsRunningInput`
/ `kAudioProcessPropertyPID` (`CallDetector.swift:143,195,209`) with **no**
`@available`/`#available` guard anywhere in the file, while `Package.swift:6`
declares `.macOS(.v14)` — i.e. 14.0, not 14.2, as our floor. These are
runtime `AudioObjectPropertySelector` lookups rather than compile-time-bound
symbols, so the likely failure mode on 14.0/14.1 is the call returning an
error rather than a crash — but nothing in `CallDetector` surfaces that as a
user-facing message the way amanu's does; on an affected Mac, auto-detect
would most likely just silently never fire. Not tested on real 14.0/14.1
hardware — we don't have one, same caveat amanu makes about Intel.

## Nothing writes to shared key files

**У нас закрыто, by construction.** API keys (`GroqEngine.swift:13`,
`GeminiEngine.swift:10`) are read from `SettingsManager.shared.groqApiKey`
/`.geminiApiKey`, which is backed by `UserDefaults.standard`
(`SettingsManager.swift:6`) under our own bundle id — not a shared
dotfile like `~/.config/anthropic` that other unrelated tools could also
write to. amanu's failure mode (a working key overwritten to two bytes by
an unrelated tool) has no path into our code.

## Bonus, not from amanu's list: a private-API screenshot path

Noticed while reading `ScreenCapturer.swift`, unrelated to anything in
amanu's document, so flagged separately rather than folded into the count
above. `ScreenCapturer.swift:6-12` binds `CGWindowListCreateImage` directly
by symbol name (`@_silgen_name`) specifically to route around Swift marking
the modern SDK's declaration unavailable — this is what "Screen Memory"'s
periodic screenshots use, not `ScreenCaptureKit` (which the app already
links and uses elsewhere, in `SystemAudioRecorder`). This works today. It is
exactly the shape of thing Apple has been actively removing across recent
macOS releases, with no fallback path to `SCScreenshotManager`/`SCStream` if
it stops resolving or starts returning empty images on a future OS. Not a
crash risk in the way described elsewhere in this document — a silent
feature regression risk instead.

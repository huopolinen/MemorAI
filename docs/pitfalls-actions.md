# Pitfalls — actions

Companion to `docs/pitfalls.md`. Each item names the file/symptom, why it
matters, and a rough size. Sizes are guesses from reading the code, not
measured by doing the work.

## Чинить до следующего релиза

### 1. Quitting during an active call can ship a truncated recording

**Where:** `AutoRec/AppDelegate.swift:458-461` (`quit()`) calls
`recordingManager.stopRecording()` then immediately `NSApp.terminate(nil)`.
`RecordingManager.stopRecording()` (`RecordingManager.swift:116-125`) is
fire-and-forget — it kicks off a `Task` and returns before that task's
`await systemAudioRecorder?.stop()` (which itself needs ~300ms+finishWriting
for two `AVAssetWriter`s, `SystemAudioRecorder.swift:236-244`) has run.

**Symptom now:** clicking Quit from the menu bar while a call is recording
can plausibly kill the process mid-`finishWriting`, leaving the system-audio
`.m4a` and (if screen recording is on) the `.mp4` truncated or unreadable —
the exact failure amanu's own README describes measuring for AAC/mp4-family
containers killed mid-write. Not reproduced with a stopwatch here, but the
race is structural, not hypothetical: nothing in the code holds termination
open for the async cleanup.

**Why it matters now, not later:** this is the *normal, documented* way to
quit the app, not an edge case like a forced kill. Any user quitting during
a real call is exposed.

**Fix shape:** implement `applicationShouldTerminate(_:)` returning
`.terminateLater`, run the existing stop sequence, call
`NSApp.reply(toApplicationShouldTerminate: true)` when the awaited `Task`
completes. Small-to-medium — mostly plumbing, the stop logic already exists
and already awaits the right things internally.

### 2. `memorai stop` / `memorai restart` kill the app with zero cleanup

**Where:** `memorai:251` (`cmd_stop`): `pkill -f "MemorAI"`. No signal
handler exists anywhere in the app (`AutoRec/main.swift` installs none), so
this is a bare `SIGTERM` with default disposition — immediate death, no
graceful path reached at all, not even the racy one in #1.

**Symptom now:** running `memorai restart` (e.g. to pick up a settings
change) while a call happens to be recording will kill it outright,
mid-write, same corruption risk as #1 but guaranteed rather than raced.
`pkill -f "MemorAI"` is also a substring match against the full command
line, not a name match — a low-probability but real chance of hitting an
unrelated process whose command line happens to contain "MemorAI".

**Fix shape:** add a `SIGTERM`/`SIGINT` `DispatchSource` handler in
`main.swift` that runs the same stop path as `AppDelegate.quit()` and then
exits — this is the same underlying fix as #1, one handler covers both the
menu Quit path and any external kill/logout/shutdown. Medium — needs the
handler plus making sure the async stop can be awaited from a synchronous
signal-source callback (a semaphore or a nested run loop, the way amanu's
`DispatchSource` + `controller.shutdown()` does it).

**Note:** `feat/pcm-crash-recovery` (a sibling worktree already in this
repo, per `git worktree list`) sounds like it's targeting exactly this class
of problem from the format side — switching the audio containers to
something crash-tolerant (PCM/CAF-style, like amanu did) would shrink the
blast radius of #1 and #2 considerably for the audio tracks. It would
**not** by itself fix the screen-recording `.mp4` track (still an
`AVAssetWriter`/mp4 container needing `finishWriting`) or the underlying
lack of a signal handler / termination race — check for overlap before
starting either fix, and keep the mp4 track and the signal-handling gap in
scope even if the audio-format switch lands first.

### 3. `bundle.sh` is missing the `screen-capture` entitlement the other two build scripts have

**Where:** `bundle.sh:31-40` declares only
`com.apple.security.device.audio-input`; `release-notarized.sh:33-44` and
the legacy `build-app.sh:21-32` both also declare
`com.apple.security.device.screen-capture`.

**Symptom now:** unverified — we have not built and run a `bundle.sh`
binary to see if this entitlement's absence actually changes
`ScreenCaptureKit` behavior under hardened runtime for a non-sandboxed app.
It may be inert. It may not.

**Why fix it anyway:** it's a one-line addition, `bundle.sh` is the
documented build path in `README.md:39`, and the downside of *not* matching
is a class of bug (hardened runtime silently closing a resource with no
prompt and no log line, per amanu's EventKit story) that's expensive to
diagnose after the fact and free to rule out now. Trivial — copy four lines
from `release-notarized.sh`.

## Стоит сделать

### 4. One signing recipe, not three

**Where:** `bundle.sh` (auto-detected identity, hardened runtime on,
`audio-input` only), `release-notarized.sh` (hardcoded identity, hardened
runtime on, both entitlements), `install.sh:35` (always ad-hoc, hardened
runtime **off**, **no entitlements at all**), for the same
`com.local.memorai`.

**Why it matters:** amanu's whole "TCC is keyed to the signature" section is
about exactly this — the divergence itself is the risk, independent of
whether any single script is individually correct. `install.sh:16-19`'s
unconditional `tccutil reset` on every install is the project's own
admission that this is unstable: it wipes and re-demands Screen Recording,
Microphone, Accessibility and Listen Event permission on *every plain
reinstall*, whether or not the signature actually changed.

**Fix shape:** either have `install.sh` call `bundle.sh` for the actual
build+sign step instead of duplicating it with weaker settings, or extract
the signing logic (identity selection, entitlements, `--options runtime`)
into one shared script all three source. Then make the `tccutil reset` in
`install.sh` conditional (or remove it) once the signature is actually
stable across runs. Medium — mostly consolidation, not new logic.

### 5. Silent recording-start failures never reach the user

**Where:** `RecordingManager.swift:87` logs `"❌ Failed to start: \(error)"`
and resets to idle; nothing else happens. The only `NSAlert` in the app
(`AppDelegate.swift:81`) is unrelated (missing whisper setup).

**Symptom now:** if Screen Recording (or Microphone) authorization is
revoked — OS update, `tccutil`, a slip in System Settings, or the identity
churn in #4 — the app just never records, silently, discoverable only by
reading `memorai.log`.

**Fix shape:** an `NSAlert` or `UNUserNotificationCenter` banner on a
start failure, mirroring the existing whisper-setup alert pattern already in
`AppDelegate.swift`. Small-to-medium.

### 6. `CallDetector` uses a macOS 14.2 API with no floor guard or fallback message

**Where:** `CallDetector.swift:8-9,143,195,209` — no `@available` anywhere
in the file; `Package.swift:6` declares `.macOS(.v14)`.

**Why it matters:** on a Mac running exactly macOS 14.0/14.1 (in range per
our declared floor, out of range per the API amanu documents for this exact
selector family), auto-detect most likely just never fires, with nothing
telling the person why — manual recording still works, but nobody's told to
use it. Low real-world likelihood (most users are on far newer macOS by
now), not zero.

**Fix shape:** either bump `Package.swift`'s floor to `.v14_2` and stop
worrying about it, or add an `@available`/manual version check plus a
status string the settings window can surface. Small once a direction is
picked.

### 7. No interrupted-session recovery on next launch

**Where:** nothing in `AutoRec/` matches `recover`/`interrupted`/`crash`.

**Why it matters:** even after #1/#2/#6 above are fixed for the paths we
control, a genuine crash or `SIGKILL` (Activity Monitor "Force Quit", OOM
kill) still leaves a folder with partial audio and no way for the app to
notice, clean up, or offer to salvage it on the next launch.

**Fix shape:** on launch, scan the output directory for a call folder with
audio files newer than the last clean session marker and no matching
transcript/completion marker; at minimum log it, ideally offer to attempt
finalization. Medium-to-large — check for overlap with
`feat/pcm-crash-recovery` first, this may already be the point of that
branch.

## К сведению

### 8. `MicRecorder`'s restart path has amanu's sibling problems, not its exact one

**Where:** `MicRecorder.swift:168-179` (`handleConfigChange`), reused by the
5s watchdog (`MicRecorder.swift:190-197`). We never call
`setVoiceProcessingEnabled` anywhere in the codebase, so amanu's specific
"echo cancellation drops on restart" bug can't happen to us — but the same
function has no self-vs-external-change distinction, no restart storm
guard, and no gap-padding/marking across a restart. Currently owned by
another agent per this task's instructions — not patched here, just
described for whoever picks the file up next.

### 9. No App Nap mitigation anywhere

**Where:** zero matches for `ProcessInfo`/`beginActivity`/`NSActivity` in
`AutoRec/`, despite `LSUIElement` (`Info.plist:19-20`) plus several
continuous timers (`CallDetector` 2s poll, `MicRecorder` 5s watchdog,
periodic screenshot capture). Not measured — no observed drift — just
noting the total absence of code amanu holds for exactly this reason.

### 10. Nested-framework signing order — no problem yet, but likely soon

**Where:** none of the three build scripts embed a framework today
(`Package.swift:8-27` links system frameworks only). `feat/local-ru-engine`
(sibling worktree, `git worktree list`) is a strong signal a bundled local
engine — and likely an embedded framework/dylib — is about to land. Whoever
does that needs to sign it before `MemorAI.app` in all three scripts, not
just the one being edited for that feature.

### 11. Bonus, outside amanu's list: private-API screenshot capture

**Where:** `ScreenCapturer.swift:6-12`, `CGWindowListCreateImage` bound by
raw symbol name to bypass Swift's availability check. Works today; is
exactly the kind of thing Apple has been quietly breaking across recent
macOS versions, with `SCStream`/`SCScreenshotManager` (already linked, used
elsewhere in the app for calls) as the natural fallback if it ever stops
working. Not urgent, just worth knowing before it silently regresses
"Screen Memory" on some future OS update.

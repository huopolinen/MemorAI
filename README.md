# MemorAI

Remembers everything you do on your computer for AI.

MemorAI sits in your menu bar and silently captures your digital life — screen activity, clipboard history, and phone calls. Everything stays local on your machine: screenshots are OCR'd via Apple Vision, calls are transcribed offline by GigaAM (Russian) or whisper.cpp. The result is a structured, searchable archive of your workday that's ready for AI-powered retrieval.

## Features

### Screen Memory
- **Periodic screenshots** — captures screen every N seconds (configurable 1–30s)
- **Smart change detection** — only saves when something actually changed (perceptual hash)
- **OCR** — Apple Vision extracts text from every screenshot (Russian + English)
- **Structured extraction** — URLs, emails, phone numbers parsed from OCR text
- **Metadata** — active app, window title, browser URL saved with each capture
- **App exclusions** — skip recording for specific apps (Telegram, YouTube, etc.)

### Clipboard History
- **Auto-capture** — saves every clipboard change (text, images, URLs, files)
- **Menu bar access** — last 100 entries in a dropdown, click to re-copy
- **Image previews** — thumbnails for screenshot/image clipboard entries
- **Persistent** — survives app restarts, stored as JSONL

### Call Recording
- **Auto-detection** — monitors mic usage, starts recording when a call begins (Zoom, Teams, FaceTime, etc.)
- **Dual-track audio** — system audio + microphone as separate files
- **Screen recording** — optional 10 fps H.264 capture during calls
- **Local transcription** — GigaAM v3 (Russian, bundled runtime) or whisper.cpp, offline; Groq/Gemini optional
- **Who said what** — each phrase is credited to you or the other side by comparing
  the two tracks' loudness (GigaAM, Whisper and Groq; Gemini returns no timings)
- **Efficient codecs** — HE-AAC keeps files small (~5 MB/hour per track)

### General
- **Menu bar only** — colored dot: gray = idle, red = recording call
- **CLI tool** — `memorai` command for status, history, settings
- **All local** — nothing leaves your machine

## Build & Run

```bash
cd side-projects/memorAI
bash bundle.sh
open MemorAI.app
```

macOS 14+ required. On first launch, grant **Screen Recording**, **Microphone**, and **Accessibility** permissions.

## CLI

```bash
./memorai status              # app status, settings, today's stats
./memorai screenshots [date]  # list captures for a day
./memorai clipboard [count]   # show clipboard history
./memorai ocr [date] [count]  # show OCR text from screenshots
./memorai model status        # is the GigaAM model downloaded?
./memorai model download      # fetch it (~260 MB, checksum-verified)
./memorai set engine gigaam   # gigaam | whisper_local | groq | gemini
./memorai set <key> <value>   # change settings
./memorai exclude add|remove|list  # manage excluded apps
./memorai start|stop|restart  # control the app
```

## Menu Bar

- Start/Stop/Pause call recording
- Auto-detect Calls (on/off)
- Record Screen during calls (on/off)
- Auto-transcribe (on/off), showing the selected engine
- Screen Memory (on/off)
- Save Clipboard (on/off)
- Clipboard History (last 100 entries)
- Excluded Apps (add/remove from running apps)
- Output folder selection

## Data Structure

```
~/Downloads/MemorAI/
  memorai.log                        # app log
  clipboard.jsonl                    # clipboard history
  screen/
    2026-03-22/
      14-30-05.jpg                   # screenshot
      14-30-05.json                  # {app, window_title, ocr_text, urls, ...}
  call_<timestamp>_system.m4a       # system audio
  call_<timestamp>_mic.m4a          # microphone
  call_<timestamp>_screen.mp4       # screen (if enabled)
  call_<timestamp>_transcript.txt   # transcription, "Я:" / "Собеседник:" (if enabled)
  call_<timestamp>_transcript.json  # same, with timings + per-phrase speaker & confidence
```

## Transcription Setup

`ffmpeg` is required for every engine:

```bash
brew install ffmpeg
```

### GigaAM — Russian, offline (default)

Sber's GigaAM v3, run by the `transcribe.cpp` runtime that ships inside the app.
No Homebrew package, no API key, and none of Whisper's YouTube-subtitle
hallucinations ("Субтитры сделал…") on pauses. Russian only.

Settings → Расшифровка → GigaAM → *Настроить / скачать модель…*, or:

```bash
./memorai model download     # ~260 MB into ~/.local/share/gigaam-models/
./memorai set engine gigaam
```

The model is pinned to one Hugging Face revision and verified by size and
SHA-256 before it is used.

GigaAM is a CTC model, so it times every token it emits; MemorAI assembles
those into phrases, which is what the "Я" / "Собеседник" labels are built on.
Switching to it does not cost you the labels.

### Whisper — multilingual, offline

```bash
brew install whisper-cpp
mkdir -p ~/.local/share/whisper-models
curl -L "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin" \
  -o ~/.local/share/whisper-models/ggml-base.bin
```

For better Russian recognition, use `ggml-medium.bin` instead — though on
Russian, GigaAM beats it at a fifth of the size.

### Groq / Gemini — cloud

Paste an API key in Settings. Audio leaves the machine; everything else here
does not.

Groq returns segment times, so it keeps the speaker labels. **Gemini does not**
— it answers in prose with no timings at all, and a transcript made with it has
no "Я" / "Собеседник" labels and no `_transcript.json`.

A Groq key is also what the optional transcript polisher uses (punctuation,
capitalization and paragraphs, wording untouched); it runs after any engine
except Gemini and is told to keep the speaker labels it finds.

## Who said what

When both tracks exist and the engine gives timings, each call gets two files:

- `call_<ts>_transcript.txt` — readable, one paragraph per speaker turn
- `call_<ts>_transcript.json` — the engine's exact wording, times, the side
  (`me` / `them`) and how confident the attribution was

Attribution is loudness-based: whichever of the two tracks was loud under a
phrase is the one who said it. Talking over each other lowers the confidence on
those segments rather than dropping them.

## License

MIT

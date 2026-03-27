# MemorAI

Remembers everything you do on your computer for AI.

MemorAI sits in your menu bar and silently captures your digital life — screen activity, clipboard history, and phone calls. Everything stays local on your machine: screenshots are OCR'd via Apple Vision, calls are transcribed via whisper.cpp. The result is a structured, searchable archive of your workday that's ready for AI-powered retrieval.

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
- **Local transcription** — whisper.cpp transcribes after each call, no cloud needed
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
./memorai set <key> <value>   # change settings
./memorai exclude add|remove|list  # manage excluded apps
./memorai start|stop|restart  # control the app
```

## Menu Bar

- Start/Stop/Pause call recording
- Auto-detect Calls (on/off)
- Record Screen during calls (on/off)
- Auto-transcribe via Whisper (on/off)
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
  call_<timestamp>_transcript.txt   # transcription (if enabled)
```

## Transcription Setup

```bash
brew install ffmpeg whisper-cpp
mkdir -p ~/.local/share/whisper-models
curl -L "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin" \
  -o ~/.local/share/whisper-models/ggml-base.bin
```

For better Russian recognition, use `ggml-medium.bin` instead.

## License

MIT

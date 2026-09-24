# Roomtone — agent / contributor map

Local-first macOS meeting recorder. Privacy-first. No required subscription.
Keep this file current: it is the fastest way for a new chat to get up to speed.

## Layers (replaceable)

```
UI → Recording → Audio Processing → Transcription → Speakers → Storage → Summarization → Export
```

Protocols live in `Roomtone/Services/Protocols/`. Prefer new impls over editing callers.

| Protocol | Role |
|----------|------|
| `AudioCapturing` | Dual-track mic + system/app audio |
| `MeetingStoring` | Filesystem meeting folders |
| `Transcribing` | Offline ASR |
| `Summarizing` | Provider-agnostic summaries |
| `TranscriptExporting` | MD / TXT / JSON / SRT / VTT |

## Meeting folder

```
~/Documents/Roomtone/
  names.txt           # optional; names for name-call handoff fixes (not in repo)
~/Documents/Roomtone/<date> <title>/
  meeting.json
  system.wav          # remote participants
  microphone.wav      # me
  combined.wav
  asr-raw.json        # {language, segments:[{start,end,speaker,text}]}
  asr-system-words.json   # cached word times (tuning; safe to delete)
  transcript.*
  summary.md
  backup-before-reprocess-*/   # created before any reprocess
```

## Hard rules

- Transcription must work offline
- Cloud AI is opt-in; UI must warn when data leaves the machine
- Do not couple transcription to summarization
- macOS first; keep layers portable for a future Windows line
- Diarization changes must be measured on **every** meeting in `~/Documents/Roomtone`, not the one being debugged. Every tuning attempt so far that fixed one meeting broke another.

## Commands

```bash
xcodegen generate && open Roomtone.xcodeproj   # after adding/removing files
bash Scripts/asr/setup.sh                      # creates Scripts/asr/.venv

# Diagnose a meeting: turn timeline, least-confident turns, threshold grid
Scripts/asr/.venv/bin/python Scripts/asr/tune_diarization.py \
  --meeting-dir "~/Documents/Roomtone/<meeting>" [--sweep] \
  [--cluster 0.32 --merge 0.23 --min-speech 15]

# Re-run ASR/diarization on a recorded meeting (back up asr-raw.json first)
Scripts/asr/.venv/bin/python Scripts/asr/reprocess_meeting.py \
  --meeting-dir "<dir>" --me-from "<backup>/asr-raw.json" --reuse-words
```

`--reuse-words` skips Whisper and reuses cached word times — use it for every
diarization experiment, it turns a 100s run into 10s.

## Current state (2026-09-23)

Working: dual-track capture, offline ASR, voice-embedding diarization, echo/bleed
filter, export, recording HUD. Summarization is provider-agnostic and opt-in.

Log: `~/Library/Logs/Roomtone/roomtone.log` (rotates at 2 MB, also goes to stdout).
Recording start writes a preflight line with both audio devices and their sample
rates *before* the call that can fail — check this first for capture bugs.

## Diarization (the part that needs care)

System track only; `Me` comes from the mic track. Entry point:
`diarize_system_by_voice` in `Scripts/asr/transcribe.py`. Pipeline order, tuned
constants (`SPEAKER_CLUSTER_DISTANCE` 0.32, `CENTROID_MERGE_DISTANCE` 0.23, …) and
the evidence behind them live in `docs/diarization.md`. Do not change a constant
or reorder steps without re-measuring every meeting.

## Open problems

- **Merged speakers (partial).** Cue-triggered local split now separates the merged
  pairs on 08-18 and 08-25 when a name-call sits between two long turns of
  the same cluster and local centroids are ≥ 0.20 apart. Still will not invent
  a second centroid if the two voices never separate acoustically.
- Backchannels ("Oh", "Uh-huh") sit 0.5+ from every centroid — acoustic ceiling.
- `WAVWriter` opens at `settings.sampleRate` while the mic tap delivers the device
  rate. Unverified whether a 32kHz mic against a 48kHz setting resamples correctly.
- Mic bleed filter is unvalidated on recent meetings (they had almost no `Me` audio,
  so it dropped 0 segments).

## Gotchas

- **Python env is required, never optional.** Swift resolves `Scripts/asr/.venv/bin/python`
  and throws if missing — it must not fall back to a system `python3`, because a
  stray numpy can segfault on import (`SIGSEGV` in `libopenblas`), which no
  `except ImportError` can survive. Override with `ROOMTONE_ASR_PYTHON`.
- **Offline is a hard rule.** Load models via `load_whisper_model` (tries
  `local_files_only=True` first). Bare `WhisperModel(...)` hits the network even
  when the model is cached.
- **The HUD panel outlives a recording.** `RecordingHUDPanelController` is a
  singleton that reuses its `NSHostingView`, so SwiftUI `@State` can survive into
  the next recording. A latch there once left Stop permanently disabled. Put
  reentrancy guards in `AppModel` keyed on `recordingState`, not in the view.
- **Mic dead in every app** (not just Roomtone) usually means macOS audio is stuck:
  `sudo killall coreaudiod`. Seen after ~38 days of daemon uptime.
- Numba/librosa in scripts: `NUMBA_CACHE_DIR=/tmp/numba_cache` avoids cache-write
  crashes.
- `xcodebuild` needs `-derivedDataPath /tmp/roomtone-build` when sandboxed.

## Pointers

- `README.md` — build/run; `docs/architecture.md` — protocol impls; `docs/diarization.md` — pipeline + tuning evidence; `docs/asr-bakeoff.md`; `CONTRIBUTING.md`.

## Log

Append newest first, one line each.

- 2026-09-23 — Pre-public cleanup: `VOCATIVE_NAMES` moved from code to
  `<Roomtone folder>/names.txt` (loaded by `load_vocative_names`; same 23 names,
  so behaviour unchanged here). Script lookup uses `RoomtoneSourceRoot`
  (`$(SRCROOT)`) in Info.plist instead of a hardcoded checkout path. Delete-recordings
  setting now works; cloud warning is based on the base URL's host; a failed summary no
  longer marks the meeting failed. Real names scrubbed from docs/comments.
- 2026-09-02 — Zoom two-remote collapse: two remotes' centroids 0.213, shipped
  merge 0.23 folded them. Guard: do not merge the last two leftover clusters
  when both are real voices and distance ≥ 0.20. Slack set unchanged. Headphones
  isolated Me (mic voiced RMS −17.5 vs Slack −29 to −34); system level matched
  Slack. Do not auto-search 0.32/0.23.
- 2026-08-27 — Pause-only cuts (`snap_abutted_changes_to_pauses`) + cue-triggered
  local split (`split_merged_at_vocative`, runs before vocative). Measured on
  six cached meetings: 08-13/19/20/26 voice counts unchanged; 08-18 4→5;
  08-25 4→5. Do not auto-tune 0.32/0.23.
- 2026-08-27 — `keep_vocative_with_caller`: name-call at start of B moves back
  onto A when the answer is a greeting (or a two-name pause). Measured on all
  six cached meetings: voice counts unchanged. Fixes 08-26 and 08-20 name-call
  handoffs. 08-25 pair still one cluster. Do not auto-tune merge.
- 2026-08-24 — Added `RoomtoneLog` + recording preflight (device names/rates before
  `engine.start()`); error text now reports causes without asserting one.
- 2026-08-24 — Fixed HUD Stop stuck disabled: removed view-level `isStopping` latch,
  guard moved into `AppModel.stopRecording()`.
- 2026-08-22 — `MIN_SPEAKER_TURN_SEC` added; recovered a real speaker who was being
  deleted for brevity on 08-19 and 08-20. Reprocessed 08-18/19/20.
- 2026-08-21 — Added `Scripts/asr/tune_diarization.py`.
- 2026-08-13 — Rewrote system diarization (window embeddings + clustering),
  acoustic echo bleed filter, handoff boundary refinement.

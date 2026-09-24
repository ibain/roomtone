# ASR bakeoff — WhisperKit vs faster-whisper

Decision status: **faster-whisper sidecar for MVP**, WhisperKit kept as future native option.

## Criteria

| Criterion | faster-whisper | WhisperKit |
|-----------|----------------|------------|
| Transcription quality | Excellent (OpenAI Whisper parity) | Good / improving |
| Apple Silicon | Fast via CTranslate2 | Native ANE path |
| Memory | Model-size dependent; int8 helps | Often better ANE residency |
| Maintenance | Mature Python ecosystem | Swift package; younger |
| Deployment | Python venv sidecar (`Scripts/asr`) | SPM dependency inside app |
| Speaker workflow | Easy to pair with WhisperX/pyannote later | Custom diarization still needed |
| Offline | Yes | Yes |

## MVP choice

**faster-whisper** via `Scripts/asr/transcribe.py`

Why:

1. Matches PRD recommendation and WhisperX upgrade path
2. Dual-track speaker heuristic ships without pyannote weights/licensing friction
3. App stays thin; ASR swappable behind `Transcribing`

## Speaker strategy (current)

1. Dual-track ASR: `microphone.wav` → `Me`; `system.wav` → remote
2. System track: Resemblyzer embeddings + agglomerative clustering → `Speaker 2`, `Speaker 3`, …
3. Mic track stays `Me` for now (multi-local / speakerphone later)
4. User renames speakers in UI; transcript + exports update
5. Combined-WAV energy heuristic only if a track is missing/silent

## Next bakeoff steps

1. Run same 30–60 min Zoom fixture through both engines
2. Score WER on a short labeled clip
3. Measure peak RSS + wall time on M-series
4. Revisit WhisperKit if packaging Python becomes painful for distribution

## WhisperX / pyannote

Deferred. pyannote model licenses need explicit audit before bundling.
Document any accepted weights in `NOTICE` when added.

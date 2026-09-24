# Architecture

See also root `AGENTS.md`.

## Replaceable protocols

- `AudioCapturing` → `DualTrackAudioCapturer` (ScreenCaptureKit + AVAudioEngine)
- `MeetingStoring` → `FileMeetingStore`
- `Transcribing` → `FasterWhisperTranscriber`
- `Summarizing` → `ProviderSummarizer` (`generateSummary(transcript:)`)
- `TranscriptExporting` → `MultiFormatExporter`

## Long transcript summary

```
transcript → chunk → summarize chunks → merge → MeetingSummary
```

Works for OpenAI API and local OpenAI-compatible endpoints (Ollama, LM Studio, llama.cpp).

# Diarization

See also root `AGENTS.md`. Code: `Scripts/asr/transcribe.py`.

System track only; `Me` comes from the mic track. Order in `diarize_system_by_voice`:

Name-call steps (7, 8) only fire for names in `names.txt` in the Roomtone
folder (one per line, lowercase, include Whisper misspellings). No file: they
are skipped.

1. Whisper with word timestamps
2. 3s voiced windows, hop 0.5s → resemblyzer embeddings → smooth
3. Agglomerative cluster → merge by centroid → mode-filter labels
4. `reattribute_small_clusters` — a stray cluster spanning a handoff is split per
   utterance instead of folded into one speaker wholesale
5. `refine_handoff_boundaries` — snaps a speaker change into the *pause* between
   utterances (duration-weighted). No pause: leave the clustering cut. Do not
   slide a probe inside an island — that chopped sentences.
6. `attribute_words_by_island` — words with no window coverage, decided per run of
   adjacent words, never per word (per-word decisions shred phrases)
7. `split_merged_at_vocative` — **before** vocative. Same-label run with a name
   then a greeting + long answer, and local centroids ≥ 0.20 apart: mint a new
   label from the greeting through the rest of that run, then re-home later
   islands. Split must run first — vocative would move the name onto the caller and
   leave the answer's "Hey there" with no cue. Fixed two merged pairs on 08-18 and 08-25.
8. `keep_vocative_with_caller` — if B's run starts with a name-call (thanks /
   fillers / names) and the answer is a greeting or a pause after two names,
   move the call back onto A. Does not mint a voice. Single-name "thank you
   Blake" from the incoming speaker is left alone.
9. `snap_abutted_changes_to_pauses` — speaker change with gap < 0.25s moves to
   the nearest pause (4s search), else the whole clause takes the heavier
   label. Vocative `name | hello` cuts stay. Fixes "I think what I'm" / "going
   to do is".
10. `absorb_small_voices` — fold clustering noise into real voices

Tuned values and the evidence behind them (do not change without re-measuring):

| Constant | Value | Why |
|---|---|---|
| `SPEAKER_CLUSTER_DISTANCE` | 0.32 | Within-speaker distance ~0.17 median, cross-speaker ~0.31+. Plateau 0.26–0.38 on 4 meetings |
| `CENTROID_MERGE_DISTANCE` | 0.23 | Plateau 0.21–0.25. At 0.19 speakers split; at 0.27 they collapse. Do not drop globally — 0.21 mints a phantom on 08-26. Zoom two-remote mixes can sit at 0.213; `merge_clusters_by_centroid` refuses that last merge when both leftover clusters are real voices (`≥ MIN_SPEAKER_SPEECH_SEC`) and distance `≥ 0.20`. |
| `MIN_SPEAKER_SPEECH_SEC` | 15.0 | Total-speech floor for a real voice |
| `MIN_SPEAKER_TURN_SEC` | 7.0 | A single held turn also marks a real voice. Plateau 6–8. Total alone deleted real short standups (one person, 8s) while keeping phantoms built from scattered "Okay"s |
| `ORPHAN_MIN_MARGIN` | 0.03 | Below this, keep the existing label rather than guess |

Notes that cost time to learn:

- Whisper word timestamps are padded loosely — "All right" is stamped 1.76s but
  holds 0.30s of speech. Always measure the real voiced span before embedding.
- Voiced "islands" split on every inter-word breath, so they are 0.2–2s fragments,
  **not** utterances. Fragments that short score near-tied against all centroids
  (0.45–0.52 away) and cannot be attributed reliably on their own.
- Ambiguous short words: keep the label time-proximity implied. Copying the
  previous word's label pulls the next speaker's opener into the wrong block.

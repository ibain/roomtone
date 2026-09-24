#!/usr/bin/env python3
"""Roomtone offline ASR sidecar using faster-whisper.

True dual-track (headphones optional — speaker bleed expected):
- system.wav → Whisper words + voice-window clustering → Speaker 2, 3, …
  Voices are clustered from 2s windows and applied per word, so a handoff
  inside one Whisper segment ("Alright Blake" → Blake talking) still splits.
- microphone.wav → Whisper words → Me when not an echo of system at same t
- Bleed is rejected two ways: same-clock text compare, plus a lag-compensated
  envelope correlation against the system track (volume alone never decides)

Falls back to energy islands if the embedding stack is unavailable, and to
combined.wav + energy heuristic if a track is missing/silent.
"""
from __future__ import annotations

import argparse
import json
import re
import wave
from pathlib import Path

# Collapse Whisper fragments (Me pauses; remotes = whole video turns).
MERGE_GAP_SEC = 2.0
REMOTE_MERGE_GAP_SEC = 3.0
MIN_TRACK_SECONDS = 0.5
REMOTE_SPEAKER = "Speaker 2"
# System speech islands (silence gaps) → one Speaker per continuous remote turn.
ISLAND_FRAME_SEC = 0.25
ISLAND_GAP_SEC = 1.5
ISLAND_MIN_SEC = 0.8

# --- Voice-window diarization (primary system-track path) ------------------
# Thresholds measured against hand-labeled speakers in the 2026-08-13 standup
# (5 remote voices). With 3s windows and neighbour-averaged embeddings:
#   same voice    : median 0.17, p90 0.26, p95 0.31
#   different voice: p1 0.31, p5 0.35, median 0.45
# Cutting at 0.32 costs ~4% same-voice splits for ~2% cross-voice merges, and
# average-linkage clustering absorbs most of that. Windows below ~2s are not
# usable at all: one speaker measured 0.28 against himself across two 1.5s
# clips, as wide as a genuine speaker change.
EMBED_WINDOW_SEC = 3.0
EMBED_HOP_SEC = 0.5
EMBED_VOICED_FRACTION = 0.6
EMBED_BATCH = 64
VOICED_FRAME_SEC = 0.02
# Brief asides in a silence hole ("All right", "Blake") never fill a 3s window,
# so they get no cluster and would otherwise inherit whoever speaks next. They
# are too short to cluster, but ranking them against settled centroids works:
# measured 0.30s–0.70s islands still put the right speaker first by 0.04–0.06.
ORPHAN_MIN_ISLAND_SEC = 0.25
ORPHAN_MIN_MARGIN = 0.03
ORPHAN_RUN_GAP_SEC = 0.6
# Average each window with its immediate neighbours before comparing. Single
# windows carry breath/noise variance that reads like a different person.
EMBED_SMOOTH_WINDOWS = 3
SPEAKER_CLUSTER_DISTANCE = 0.32
# Second pass on cluster centroids. Averaging cancels the per-window noise that
# inflates average-linkage distances, so the same voice split across two
# clusters lands much closer here (measured 0.20) than the nearest genuinely
# different pair (0.26) — hence a tighter cut than the linkage threshold.
CENTROID_MERGE_DISTANCE = 0.23
# Median-filter width (in windows) over the per-window speaker labels.
SPEAKER_SMOOTH_WINDOWS = 3
# Clusters holding less speech than this get folded into their nearest voice.
# Sign-offs ("see you guys later") cluster apart from the same person's main
# turn, so the floor has to sit above a few seconds of clipped speech.
MIN_SPEAKER_SPEECH_SEC = 15.0
# A single held turn this long marks a real speaker even when their total is
# small — a standup answer can be under ten seconds.
MIN_SPEAKER_TURN_SEC = 7.0
# Gap that ends a same-speaker run when regrouping labeled words.
WORD_REGROUP_GAP_SEC = 1.0
# Handoff refinement: how far either side of a speaker change to re-examine at
# word resolution, and how finely to slide the probe window across it.
BOUNDARY_SEARCH_SEC = 3.0
BOUNDARY_SEARCH_HOP_SEC = 0.2
BOUNDARY_MAX_GAP_SEC = 5.0
# Utterances considered when snapping a handoff into a pause. Long ones get
# sampled from the middle rather than embedded whole.
BOUNDARY_MIN_ISLAND_SEC = 0.25
BOUNDARY_ISLAND_MAX_SEC = 4.0
# A centroid needs enough windows behind it to be worth comparing against.
BOUNDARY_MIN_WINDOWS = 4

# Vocative handoff: host says a name, then the named person starts. Whisper
# often abuts the name onto "hello", so the next cluster eats the call. Names
# stay with the caller; the cut is the first word of the answer. Do not treat
# this as a new voice — clustering already has both centroids. "in" is only
# filler (a short name misheard after "thanks"); the preposition in "in the
# sense" never looks like a name-call because no name follows.
VOCATIVE_MAX_PREFIX_WORDS = 16
VOCATIVE_MIN_LEFTOVER_WORDS = 2
VOCATIVE_MIN_GAP_SEC = 0.35
# Names people call on in your meetings, from names.txt in the Roomtone folder
# (one per line, lowercase; add Whisper misspellings too). Empty turns the
# name-call fixes off. Set by load_vocative_names().
VOCATIVE_NAMES: frozenset[str] = frozenset()
# After labels exist: never leave a speaker change between two words with no
# pause, except a vocative greeting cut. The sliding probe used to cut inside
# an island and produced "I think what I'm" / "going to do is".
SNAP_MIN_PAUSE_SEC = 0.25
SNAP_SEARCH_SEC = 4.0
# Same-label vocative: host calls a name, then a long answer, but clustering
# gave both the same centroid. Split only when the two sides' local centroids
# actually separate — otherwise "Hey Alex, so I…" from one person would mint
# a phantom.
SPLIT_MIN_AFTER_SEC = 7.0
SPLIT_MIN_CENTROID_DISTANCE = 0.20
SPLIT_MIN_WINDOWS = 4
SPLIT_BEFORE_SPEECH_SEC = 25.0
# Same-label word gap with no other speaker in between is silence, not a
# standup handoff. Don't leap 2 min of quiet to old speech for the before
# centroid (that smears 08-18 host+guest to 0.16 and blocks the split).
SPLIT_SILENCE_BREAK_SEC = 8.0
VOCATIVE_LEADING_FILLER = frozenset(
    {
        "all",
        "right",
        "alright",
        "ok",
        "okay",
        "cool",
        "excellent",
        "perfect",
        "thanks",
        "thank",
        "you",
        "and",
        "uh",
        "um",
        "well",
        "yeah",
        "yep",
        "please",
        "also",
        "in",  # short name misheard after thanks; harmless as filler before a name
    }
)
VOCATIVE_BETWEEN_FILLER = frozenset({"and", "uh", "um", "you", "in"})
VOCATIVE_TAIL = frozenset({"you're", "youre", "your", "next", "up", "go", "ahead"})
VOCATIVE_GREETING = frozenset({"hello", "hey", "hi", "yo", "hiya"})

# --- Legacy island fallback (used only when embeddings are unavailable) ----
ISLAND_EMBED_MERGE_DISTANCE = 0.20
VOICE_CHANGE_DIST = 0.30
# Ignore voice-change cuts that would mint a crumb (short / few-word) new side.
VOICE_CHANGE_MIN_WORDS = 5
VOICE_CHANGE_MIN_SEC = 1.2
# After labeling, fold remote labels with fewer than this many words into a neighbor.
REMOTE_CRUMB_MAX_WORDS = 15
# Embeddings need real speech behind them — never mint a voice from a crumb.
DIARIZE_MIN_SEC = 2.0

MIC_WORD_GAP_SEC = 1.25
MIN_ME_SEGMENT_SEC = 0.45
# Mic near-silence only — never used to pick Me vs bleed by loudness.
MIC_SILENCE_RMS = 35.0
# Same-clock bleed: content-word overlap vs system text covering this word.
BLEED_SIMILARITY = 0.45
# Whisper segment times drift seconds from the words they contain, so the text
# comparison needs a wide window to find the system copy of a bled phrase.
BLEED_TIME_PAD_SEC = 3.0

# --- Acoustic bleed (mic re-recording the speaker output) ------------------
# Without headphones the mic envelope tracks the system envelope. Measured on
# 2026-08-13: 25 bled fragments scored 0.56 – 0.90, real local speech scored
# 0.04 / 0.31 / 0.45, at a consistent 40 – 60ms system lag.
# Scoring every Me line of that meeting gave a bimodal split: 76 segments below
# 0.30 (4791 words, all genuine) and 61 above 0.75 (302 words, all bleed). The
# middle band is mixed, because talking over a remote also correlates. Length
# breaks the tie — bleed arrives as fragments, genuine overlap runs long.
ECHO_HOP_SEC = 0.02
ECHO_MAX_LAG_SEC = 0.30
ECHO_CORR_STRONG = 0.75
ECHO_CORR_THRESHOLD = 0.50
ECHO_FRAGMENT_MAX_WORDS = 15
ECHO_MIN_SPAN_SEC = 0.6
_ECHO_STOP = frozenset(
    """
    a an the and or but if in on at to for of as is are was were be been being
    this that these those it its i you he she we they me my your our their
    with from by not no so just like about into out up all can will would
    have has had do does did am
    """.split()
)


def load_whisper_model(model: str):
    """Prefer the local cache so transcription still runs with no network.

    faster-whisper resolves the model through the Hugging Face hub even when it
    is already cached, and a blocked or offline network raises instead of
    falling back — which would break the offline guarantee.
    """
    from faster_whisper import WhisperModel

    try:
        return WhisperModel(
            model, device="auto", compute_type="int8", local_files_only=True
        )
    except Exception:
        return WhisperModel(model, device="auto", compute_type="int8")


def resolve_language(raw: str | None) -> str | None:
    """Whisper language code, or None for auto-detect."""
    if not raw:
        return None
    value = raw.strip().lower()
    if value in ("", "auto", "detect", "none"):
        return None
    return value


def load_vocative_names(meeting_dir: str | Path) -> None:
    """Read names.txt from the folder that holds the meeting folders."""
    global VOCATIVE_NAMES
    path = Path(meeting_dir).expanduser().parent / "names.txt"
    if not path.is_file():
        VOCATIVE_NAMES = frozenset()
        return
    lines = path.read_text(encoding="utf-8").splitlines()
    VOCATIVE_NAMES = frozenset(
        n.strip().lower() for n in lines if n.strip() and not n.lstrip().startswith("#")
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio", required=True, help="combined.wav")
    parser.add_argument("--mic", required=False)
    parser.add_argument("--system", required=False)
    parser.add_argument("--output", required=True)
    parser.add_argument("--language", default="en")
    parser.add_argument("--model", default="small.en")
    args = parser.parse_args()
    load_vocative_names(Path(args.output).parent)

    model = load_whisper_model(args.model)
    language = resolve_language(args.language)

    mic_ok = has_usable_audio(args.mic)
    sys_ok = has_usable_audio(args.system)

    segments: list[dict]
    info_language = language or "en"

    if mic_ok or sys_ok:
        segments = []
        sys_segs: list[dict] = []
        if sys_ok:
            sys_words, whisper_segs, lang = transcribe_system_track(
                model, args.system, language, speaker=REMOTE_SPEAKER
            )
            by_voice = diarize_system_by_voice(args.system, sys_words, name_start=2)
            sys_segs = (
                by_voice
                if by_voice is not None
                else diarize_by_speech_islands(args.system, whisper_segs, name_start=2)
            )
            segments.extend(sys_segs)
            if lang:
                info_language = lang
        if mic_ok:
            if sys_ok:
                mic_segs, lang = transcribe_mic_same_clock(
                    model, args.mic, language, system_segments=sys_segs
                )
                mic_segs = drop_echoed_me_segments(mic_segs, args.mic, args.system)
            else:
                mic_segs, lang = transcribe_track(
                    model, args.mic, language, speaker="Me"
                )
            mic_segs = drop_tiny_me_segments(mic_segs)
            segments.extend(mic_segs)
            if lang:
                info_language = lang
        segments.sort(key=lambda s: (s["start"], s["end"]))
        if not segments:
            segments, info_language = transcribe_combined_fallback(
                model, args.audio, args.mic, args.system, language
            )
    else:
        segments, info_language = transcribe_combined_fallback(
            model, args.audio, args.mic, args.system, language
        )

    segments = merge_segments_by_speaker(segments)
    # Interruptions cut remote turns in time order (Sp2 | Me | Sp2), not one blob then Me.
    segments = split_remotes_around_me_interruptions(segments)
    segments = drop_tiny_me_segments(segments)
    segments = merge_segments_by_speaker(segments)
    # Crumb remotes (few words) → nearest real remote; then renumber 2…N with no gaps.
    segments = absorb_tiny_remote_speakers(segments)
    segments = densify_remote_speakers(segments, name_start=2)
    segments = merge_segments_by_speaker(segments)

    payload = {
        "language": info_language,
        "segments": segments,
    }
    Path(args.output).write_text(json.dumps(payload, indent=2), encoding="utf-8")


def transcribe_track(
    model,
    path: str,
    language: str | None,
    speaker: str,
) -> tuple[list[dict], str | None]:
    segments_iter, info = model.transcribe(
        path,
        language=language,
        vad_filter=True,
        word_timestamps=False,
        condition_on_previous_text=True,
    )
    out = []
    for seg in segments_iter:
        text = seg.text.strip()
        if not text:
            continue
        out.append(
            {
                "start": float(seg.start),
                "end": float(seg.end),
                "text": text,
                "speaker": speaker,
            }
        )
    return out, getattr(info, "language", None)


def transcribe_system_track(
    model,
    path: str,
    language: str | None,
    speaker: str,
) -> tuple[list[tuple[float, float, str]], list[dict], str | None]:
    """System track with word times, so voices can be split mid-segment.

    Segment-level times drift seconds away from the words they contain, which
    both hides handoffs and makes the mic bleed comparison miss.
    """
    segments_iter, info = model.transcribe(
        path,
        language=language,
        vad_filter=True,
        word_timestamps=True,
        condition_on_previous_text=True,
    )
    words: list[tuple[float, float, str]] = []
    segments: list[dict] = []
    for seg in segments_iter:
        text = seg.text.strip()
        if text:
            segments.append(
                {
                    "start": float(seg.start),
                    "end": float(seg.end),
                    "text": text,
                    "speaker": speaker,
                }
            )
        for word in getattr(seg, "words", None) or []:
            token = (word.word or "").strip()
            if not token:
                continue
            w0 = float(word.start)
            w1 = float(word.end)
            if w1 <= w0:
                w1 = w0 + 0.05
            words.append((w0, w1, token))
    return words, segments, getattr(info, "language", None)


def collect_mic_words(
    model,
    mic_path: str,
    language: str | None,
) -> tuple[list[tuple[float, float, str]], str | None]:
    segments_iter, info = model.transcribe(
        mic_path,
        language=language,
        vad_filter=True,
        word_timestamps=True,
        condition_on_previous_text=False,
    )
    raw_words: list[tuple[float, float, str]] = []
    for seg in segments_iter:
        words = getattr(seg, "words", None) or []
        if not words:
            text = seg.text.strip()
            if text:
                raw_words.append((float(seg.start), float(seg.end), text))
            continue
        for word in words:
            token = (word.word or "").strip()
            if not token:
                continue
            w0 = float(word.start)
            w1 = float(word.end)
            if w1 <= w0:
                w1 = w0 + 0.05
            raw_words.append((w0, w1, token))
    return raw_words, getattr(info, "language", None)


def transcribe_mic_same_clock(
    model,
    mic_path: str,
    language: str | None,
    system_segments: list[dict],
) -> tuple[list[dict], str | None]:
    """Me = mic words that are not an echo of system text at the same time."""
    raw_words, lang = collect_mic_words(model, mic_path, language)
    if not raw_words:
        return [], lang

    tokens = [normalize_token(t) for _, _, t in raw_words]
    mids = [(w0 + w1) * 0.5 for w0, w1, _ in raw_words]
    kept: list[tuple[float, float, str]] = []
    for i, (w0, w1, token) in enumerate(raw_words):
        if rms_window(mic_path, w0, w1) < MIC_SILENCE_RMS:
            continue
        if is_bleed_of_system(w0, w1, i, tokens, mids, system_segments):
            continue
        kept.append((w0, w1, token))
    return stitch_words(kept, speaker="Me"), lang


def normalize_token(token: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", token.lower())


def content_word_set(text: str) -> set[str]:
    return {
        w
        for w in re.findall(r"[a-z0-9]+", text.lower())
        if len(w) > 2 and w not in _ECHO_STOP
    }


def token_matches_sys_vocab(tok: str, sys_vocab: set[str]) -> bool:
    """Exact or fuzzy match — Whisper often mangles names (Chip Nguyen vs Chipwin)."""
    if not tok or len(tok) < 3:
        return False
    if tok in sys_vocab:
        return True
    for w in sys_vocab:
        if len(w) < 3:
            continue
        if tok.startswith(w) or w.startswith(tok):
            if min(len(tok), len(w)) >= 4 or abs(len(tok) - len(w)) <= 2:
                return True
        # Short edit distance for similar ASR spellings.
        if abs(len(tok) - len(w)) <= 2 and len(tok) >= 4:
            # Hamming-ish: count mismatched chars on aligned prefix.
            n = min(len(tok), len(w))
            diffs = sum(1 for i in range(n) if tok[i] != w[i]) + abs(len(tok) - len(w))
            if diffs <= 2:
                return True
    return False


def system_text_near(
    t0: float,
    t1: float,
    system_segments: list[dict],
    pad: float = BLEED_TIME_PAD_SEC,
) -> str:
    """System transcript covering this mic span (same clock)."""
    parts: list[str] = []
    for seg in system_segments:
        a, b = float(seg["start"]), float(seg["end"])
        if b + pad < t0 or a - pad > t1:
            continue
        parts.append(seg.get("text") or "")
    return " ".join(parts)


def window_content_tokens_near_time(
    token_index: int,
    tokens: list[str],
    mids: list[float],
    radius_sec: float = 0.85,
) -> list[str]:
    """Content tokens within ~radius_sec of this word (same clock), not index neighbors."""
    if not (0 <= token_index < len(mids)):
        return []
    center = mids[token_index]
    out: list[str] = []
    for i, mid in enumerate(mids):
        if abs(mid - center) > radius_sec:
            continue
        tok = tokens[i]
        if tok and len(tok) > 2 and tok not in _ECHO_STOP:
            out.append(tok)
    return out


def is_bleed_of_system(
    t0: float,
    t1: float,
    token_index: int,
    tokens: list[str],
    mids: list[float],
    system_segments: list[dict],
) -> bool:
    """True when mic wording matches concurrent system text (speaker bleed)."""
    sys_vocab = content_word_set(system_text_near(t0, t1, system_segments))
    if not sys_vocab:
        return False
    window = window_content_tokens_near_time(token_index, tokens, mids)
    tok = tokens[token_index] if 0 <= token_index < len(tokens) else ""
    tok_hit = token_matches_sys_vocab(tok, sys_vocab)
    if not window:
        return tok_hit and len(tok) > 3
    hits = sum(1 for t in window if token_matches_sys_vocab(t, sys_vocab))
    ratio = hits / len(window)
    # Distinctive mic word absent from system → talk-over, even if neighbors echo.
    if tok and len(tok) > 2 and tok not in _ECHO_STOP and not tok_hit:
        return ratio >= 0.75
    return ratio >= BLEED_SIMILARITY or tok_hit


def stitch_words(
    words: list[tuple[float, float, str]],
    speaker: str,
) -> list[dict]:
    if not words:
        return []
    segments: list[dict] = []
    start, end, text = words[0][0], words[0][1], words[0][2]
    for w0, w1, token in words[1:]:
        if w0 - end <= MIC_WORD_GAP_SEC:
            end = max(end, w1)
            text = f"{text} {token}".strip()
        else:
            segments.append(
                {"start": start, "end": end, "text": text, "speaker": speaker}
            )
            start, end, text = w0, w1, token
    segments.append({"start": start, "end": end, "text": text, "speaker": speaker})
    return segments


_ENVELOPE_CACHE: dict[str, object] = {}


def loudness_envelope(path: str):
    """Coarse RMS envelope of a whole track, streamed so nothing large is held."""
    if path in _ENVELOPE_CACHE:
        return _ENVELOPE_CACHE[path]
    try:
        import audioop

        import numpy as np
    except Exception:
        return None
    try:
        with wave.open(path, "rb") as wf:
            rate = wf.getframerate()
            width = wf.getsampwidth()
            channels = wf.getnchannels()
            hop = max(1, int(rate * ECHO_HOP_SEC))
            values: list[float] = []
            while True:
                raw = wf.readframes(hop * 512)
                if not raw:
                    break
                if channels > 1:
                    raw = audioop.tomono(raw, width, 0.5, 0.5)
                stride = width * hop
                for i in range(0, len(raw) - stride + 1, stride):
                    values.append(float(audioop.rms(raw[i : i + stride], width)))
    except Exception:
        return None
    envelope = np.asarray(values, dtype=np.float32)
    _ENVELOPE_CACHE[path] = envelope
    return envelope


def echo_correlation(mic_path: str, system_path: str, t0: float, t1: float) -> float:
    """How much a mic span looks like a delayed copy of the system output.

    Speaker bleed reproduces the remote loudness shape a few tens of ms later,
    so a lag-compensated envelope correlation separates "the mic re-recorded
    the meeting" from "the local person talked" without trusting ASR wording.
    """
    mic = loudness_envelope(mic_path)
    system = loudness_envelope(system_path)
    if mic is None or system is None or not len(mic) or not len(system):
        return 0.0
    try:
        import numpy as np
    except Exception:
        return 0.0

    if t1 - t0 < ECHO_MIN_SPAN_SEC:
        pad = (ECHO_MIN_SPAN_SEC - (t1 - t0)) * 0.5
        t0, t1 = t0 - pad, t1 + pad
    max_lag = int(ECHO_MAX_LAG_SEC / ECHO_HOP_SEC)
    i0 = int(max(0.0, t0) / ECHO_HOP_SEC)
    i1 = int(max(t0, t1) / ECHO_HOP_SEC)
    i0 = max(max_lag, i0)
    i1 = min(min(len(mic), len(system)) - max_lag, i1)
    if i1 - i0 < 5:
        return 0.0

    a = mic[i0:i1]
    a = a - a.mean()
    a_norm = float(np.linalg.norm(a))
    if a_norm <= 0:
        return 0.0

    best = 0.0
    for lag in range(-max_lag, max_lag + 1):
        b = system[i0 + lag : i1 + lag]
        if len(b) != len(a):
            continue
        b = b - b.mean()
        b_norm = float(np.linalg.norm(b))
        if b_norm <= 0:
            continue
        best = max(best, float((a * b).sum() / (a_norm * b_norm)))
    return best


def is_echoed_me_segment(seg: dict, mic_path: str, system_path: str) -> bool:
    """True when a Me line looks like the system track re-recorded by the mic.

    A strong envelope match is decisive on its own. A moderate match only
    convicts a fragment, because speaking over a remote correlates too and long
    local turns must survive.
    """
    score = echo_correlation(
        mic_path, system_path, float(seg["start"]), float(seg["end"])
    )
    if score >= ECHO_CORR_STRONG:
        return True
    words = len((seg.get("text") or "").split())
    return score >= ECHO_CORR_THRESHOLD and words <= ECHO_FRAGMENT_MAX_WORDS


def drop_echoed_me_segments(
    segments: list[dict],
    mic_path: str,
    system_path: str,
) -> list[dict]:
    """Remove Me lines whose loudness shape is the system track playing back."""
    return [
        seg
        for seg in segments
        if seg.get("speaker") != "Me"
        or not is_echoed_me_segment(seg, mic_path, system_path)
    ]


def rms_window(path: str, t0: float, t1: float) -> float:
    try:
        import audioop

        with wave.open(path, "rb") as wf:
            rate = wf.getframerate()
            width = wf.getsampwidth()
            channels = wf.getnchannels()
            start_f = int(max(0.0, t0) * rate)
            end_f = max(start_f + 1, int(max(t0, t1) * rate))
            wf.setpos(min(start_f, max(wf.getnframes() - 1, 0)))
            frames = wf.readframes(end_f - start_f)
            if not frames:
                return 0.0
            if channels > 1:
                frames = audioop.tomono(frames, width, 0.5, 0.5)
            return float(audioop.rms(frames, width))
    except Exception:
        return 0.0


def transcribe_combined_fallback(
    model,
    audio: str,
    mic: str | None,
    system: str | None,
    language: str | None,
) -> tuple[list[dict], str]:
    segments_iter, info = model.transcribe(
        audio,
        language=language,
        vad_filter=True,
        word_timestamps=False,
        condition_on_previous_text=True,
    )
    segments = []
    for seg in segments_iter:
        text = seg.text.strip()
        if not text:
            continue
        speaker = guess_speaker(seg.start, seg.end, mic, system)
        segments.append(
            {
                "start": float(seg.start),
                "end": float(seg.end),
                "text": text,
                "speaker": speaker,
            }
        )
    return segments, getattr(info, "language", None) or language or "en"


def merge_gap_for_speaker(speaker: str) -> float:
    if speaker == "Me" or speaker in ("SPEAKER_LOCAL", "You", "Speaker 1"):
        return MERGE_GAP_SEC
    return REMOTE_MERGE_GAP_SEC


def merge_segments_by_speaker(segments: list[dict]) -> list[dict]:
    """Join consecutive same-speaker fragments; remotes tolerate longer pauses."""
    if not segments:
        return []
    merged = [dict(segments[0])]
    for seg in segments[1:]:
        prev = merged[-1]
        gap = float(seg["start"]) - float(prev["end"])
        same = seg["speaker"] == prev["speaker"]
        if same and gap <= merge_gap_for_speaker(str(seg["speaker"])):
            prev["end"] = float(seg["end"])
            prev["text"] = f'{prev["text"]} {seg["text"]}'.strip()
        else:
            merged.append(dict(seg))
    return merged


def split_remotes_around_me_interruptions(segments: list[dict]) -> list[dict]:
    """
    If Me talks over a remote, cut that remote into before/after so the
    transcript reads in interruption order: remote → Me → remote.
    """
    me_spans = [
        (float(s["start"]), float(s["end"]))
        for s in segments
        if s.get("speaker") == "Me"
    ]
    if not me_spans:
        return segments

    out: list[dict] = []
    for seg in segments:
        if seg.get("speaker") == "Me":
            out.append(dict(seg))
            continue

        pieces = [dict(seg)]
        for m0, m1 in sorted(me_spans):
            next_pieces: list[dict] = []
            for piece in pieces:
                p0, p1 = float(piece["start"]), float(piece["end"])
                # Me must sit inside this remote span to count as an interruption.
                if m1 <= p0 + 0.05 or m0 >= p1 - 0.05:
                    next_pieces.append(piece)
                    continue
                if m0 <= p0 and m1 >= p1:
                    # Me covers whole remote slice — drop empty remote husk.
                    continue
                cut0 = max(p0, m0)
                cut1 = min(p1, m1)
                if cut1 <= cut0:
                    next_pieces.append(piece)
                    continue

                dur = max(1e-6, p1 - p0)
                words = (piece.get("text") or "").split()
                i_before = int(round(len(words) * ((cut0 - p0) / dur)))
                i_after = int(round(len(words) * ((cut1 - p0) / dur)))
                i_before = max(0, min(len(words), i_before))
                i_after = max(i_before, min(len(words), i_after))
                before_text = " ".join(words[:i_before]).strip()
                after_text = " ".join(words[i_after:]).strip()

                if cut0 - p0 >= 0.2 and before_text:
                    next_pieces.append(
                        {
                            "start": p0,
                            "end": cut0,
                            "text": before_text,
                            "speaker": piece["speaker"],
                        }
                    )
                if p1 - cut1 >= 0.2 and after_text:
                    next_pieces.append(
                        {
                            "start": cut1,
                            "end": p1,
                            "text": after_text,
                            "speaker": piece["speaker"],
                        }
                    )
            pieces = next_pieces
        out.extend(pieces)

    return sorted(out, key=lambda s: (float(s["start"]), float(s["end"])))


def drop_tiny_me_segments(segments: list[dict]) -> list[dict]:
    """Drop crumb Me lines (ASR ghosts while remote audio plays)."""
    out: list[dict] = []
    for seg in segments:
        if seg.get("speaker") != "Me":
            out.append(seg)
            continue
        dur = float(seg["end"]) - float(seg["start"])
        words = len((seg.get("text") or "").split())
        if dur < MIN_ME_SEGMENT_SEC or words < 2:
            continue
        out.append(seg)
    return out


def _remote_speaker_name(speaker: str) -> bool:
    return bool(re.fullmatch(r"Speaker \d+", str(speaker)))


def absorb_tiny_remote_speakers(
    segments: list[dict],
    min_words: int = REMOTE_CRUMB_MAX_WORDS,
) -> list[dict]:
    """Fold short-lived remote labels into the nearest substantial remote."""
    if not segments:
        return segments
    words: dict[str, int] = {}
    for seg in segments:
        sp = str(seg.get("speaker") or "")
        if _remote_speaker_name(sp):
            words[sp] = words.get(sp, 0) + len((seg.get("text") or "").split())
    keep = {sp for sp, n in words.items() if n >= min_words}
    crumbs = {sp for sp in words if sp not in keep}
    if not crumbs or not keep:
        return segments

    # Representative midpoint per kept remote (for nearest-neighbor).
    mids: dict[str, list[float]] = {sp: [] for sp in keep}
    for seg in segments:
        sp = str(seg.get("speaker") or "")
        if sp in keep:
            mids[sp].append((float(seg["start"]) + float(seg["end"])) * 0.5)
    anchors = {sp: sum(ts) / len(ts) for sp, ts in mids.items() if ts}

    out: list[dict] = []
    for seg in segments:
        item = dict(seg)
        sp = str(item.get("speaker") or "")
        if sp in crumbs:
            mid = (float(item["start"]) + float(item["end"])) * 0.5
            nearest = min(anchors, key=lambda k: abs(anchors[k] - mid))
            item["speaker"] = nearest
        out.append(item)
    return out


def densify_remote_speakers(
    segments: list[dict],
    name_start: int = 2,
) -> list[dict]:
    """Renumber Speaker N by first appearance so IDs stay dense after drops."""
    rename: dict[str, str] = {}
    next_n = name_start
    out: list[dict] = []
    for seg in segments:
        item = dict(seg)
        sp = str(item.get("speaker") or "")
        if _remote_speaker_name(sp):
            if sp not in rename:
                rename[sp] = f"Speaker {next_n}"
                next_n += 1
            item["speaker"] = rename[sp]
        out.append(item)
    return out


def load_mono_16k(wav_path: str):
    """Whole track at the encoder sample rate, timing untouched."""
    import librosa

    wav, _ = librosa.load(wav_path, sr=16000, mono=True)
    return wav


def voiced_frames(wav):
    """Per-frame speech/silence mask for the track, or None if unusable."""
    try:
        import numpy as np
    except Exception:
        return None
    hop = int(VOICED_FRAME_SEC * 16000)
    usable = len(wav) // hop * hop
    if usable <= 0:
        return None
    frames = np.sqrt((wav[:usable].reshape(-1, hop) ** 2).mean(1))
    voiced = frames[frames > 0]
    if not len(voiced):
        return None
    threshold = max(0.004, float(np.percentile(voiced, 60)) * 0.25)
    return frames > threshold


def voiced_windows(wav) -> list[tuple[float, float]]:
    """Fixed-length windows that are mostly speech, on the original clock."""
    is_voiced = voiced_frames(wav)
    if is_voiced is None:
        return []
    out: list[tuple[float, float]] = []
    span = int(EMBED_WINDOW_SEC / VOICED_FRAME_SEC)
    step = max(1, int(EMBED_HOP_SEC / VOICED_FRAME_SEC))
    for i in range(0, len(is_voiced) - span + 1, step):
        if is_voiced[i : i + span].mean() >= EMBED_VOICED_FRACTION:
            out.append((i * VOICED_FRAME_SEC, (i + span) * VOICED_FRAME_SEC))
    return out


def speech_islands_in(
    is_voiced, t0: float, t1: float, min_sec: float
) -> list[tuple[float, float]]:
    """Whole contiguous speech runs overlapping a time range."""
    lo = max(0, int(t0 / VOICED_FRAME_SEC))
    hi = min(len(is_voiced), int(t1 / VOICED_FRAME_SEC) + 1)
    while lo > 0 and is_voiced[lo]:
        lo -= 1
    out: list[tuple[float, float]] = []
    i = lo
    while i < hi:
        if not is_voiced[i]:
            i += 1
            continue
        start = i
        while i + 1 < len(is_voiced) and is_voiced[i + 1]:
            i += 1
        end = i + 1
        if (end - start) * VOICED_FRAME_SEC >= min_sec:
            out.append((start * VOICED_FRAME_SEC, end * VOICED_FRAME_SEC))
        i += 1
    return out


def speech_island(is_voiced, t: float) -> tuple[float, float] | None:
    """The contiguous run of speech containing (or nearest to) a time."""
    i = int(t / VOICED_FRAME_SEC)
    if i < 0 or i >= len(is_voiced):
        return None
    if not is_voiced[i]:
        reach = int(0.4 / VOICED_FRAME_SEC)
        found = None
        for k in range(1, reach):
            if i - k >= 0 and is_voiced[i - k]:
                found = i - k
                break
            if i + k < len(is_voiced) and is_voiced[i + k]:
                found = i + k
                break
        if found is None:
            return None
        i = found
    lo = i
    while lo > 0 and is_voiced[lo - 1]:
        lo -= 1
    hi = i
    while hi + 1 < len(is_voiced) and is_voiced[hi + 1]:
        hi += 1
    return lo * VOICED_FRAME_SEC, (hi + 1) * VOICED_FRAME_SEC


def voice_mel(wav):
    """Mel spectrogram for the whole track, or None if the stack is unavailable."""
    try:
        from resemblyzer.audio import wav_to_mel_spectrogram
    except Exception:
        return None
    try:
        return wav_to_mel_spectrogram(wav)
    except Exception:
        return None


_ENCODER: list = []


def voice_encoder():
    """One shared encoder — loading the weights per call is pure overhead."""
    if _ENCODER:
        return _ENCODER[0]
    try:
        from resemblyzer import VoiceEncoder
    except Exception:
        return None
    try:
        _ENCODER.append(VoiceEncoder(verbose=False))
    except Exception:
        return None
    return _ENCODER[0]


def embed_windows(mel, wav, starts: list[float], length_sec: float | None = None):
    """Embed fixed-length windows starting at each given time.

    Mel power scales with amplitude squared, so resemblyzer's per-clip volume
    normalization is applied by scaling each window's mel slice — same result as
    normalizing the audio first, without recomputing the spectrogram every time.
    """
    if mel is None or not starts:
        return None
    encoder = voice_encoder()
    if encoder is None:
        return None
    try:
        import numpy as np
        import torch
        from resemblyzer.hparams import audio_norm_target_dBFS
    except Exception:
        return None

    length = EMBED_WINDOW_SEC if length_sec is None else length_sec
    span = int(round(length * 100))
    int16_max = (2 ** 15) - 1

    slices = []
    for t0 in starts:
        f0 = max(0, min(int(round(t0 * 100)), max(0, len(mel) - span)))
        chunk = mel[f0 : f0 + span]
        if not len(chunk):
            return None
        if len(chunk) < span:
            pad = np.repeat(chunk[-1:], span - len(chunk), axis=0)
            chunk = np.concatenate([chunk, pad], axis=0)
        audio = wav[int(t0 * 16000) : int(t0 * 16000) + int(length * 16000)]
        gain = 1.0
        if len(audio):
            rms = float(np.sqrt(np.mean((audio * int16_max) ** 2)))
            if rms > 0:
                change = audio_norm_target_dBFS - 20 * np.log10(rms / int16_max)
                if change > 0:
                    gain = float(10 ** (change / 20))
        slices.append(chunk * (gain ** 2))

    embeds = []
    with torch.no_grad():
        for i in range(0, len(slices), EMBED_BATCH):
            batch = np.stack(slices[i : i + EMBED_BATCH]).astype(np.float32)
            embeds.append(encoder(torch.from_numpy(batch).to(encoder.device)).cpu().numpy())
    return np.concatenate(embeds, axis=0)


def window_embeddings(wav, windows: list[tuple[float, float]]):
    """One voice embedding per voiced window."""
    return embed_windows(voice_mel(wav), wav, [w[0] for w in windows])


def smooth_embeddings(embeds, windows: list[tuple[float, float]]):
    """Average neighbouring windows to damp per-window noise.

    Only contiguous neighbours are averaged, so the last window before a silence
    never gets blended with the first window of whoever speaks next.
    """
    width = EMBED_SMOOTH_WINDOWS
    if width < 2 or embeds is None or len(embeds) < width:
        return embeds
    try:
        import numpy as np
    except Exception:
        return embeds

    half = width // 2
    reach = half * EMBED_HOP_SEC * 1.5
    starts = [w[0] for w in windows]
    out = np.zeros_like(embeds)
    for i in range(len(embeds)):
        lo = max(0, i - half)
        hi = min(len(embeds), i + half + 1)
        rows = [
            embeds[j] for j in range(lo, hi) if abs(starts[j] - starts[i]) <= reach
        ]
        out[i] = np.mean(rows, axis=0) if rows else embeds[i]
    norms = np.linalg.norm(out, axis=1, keepdims=True)
    return out / np.maximum(norms, 1e-9)


def cluster_embeddings(embeds) -> list[int]:
    """Group windows by voice. Average linkage cut at the measured speaker gap."""
    n = len(embeds)
    if n <= 1:
        return [0] * n
    try:
        from scipy.cluster.hierarchy import fcluster, linkage
        from scipy.spatial.distance import pdist
    except Exception:
        return list(range(n))

    linked = linkage(pdist(embeds, metric="cosine"), method="average")
    labels = fcluster(linked, t=SPEAKER_CLUSTER_DISTANCE, criterion="distance")
    return [int(v) for v in labels]


def merge_clusters_by_centroid(labels: list[int], embeds) -> list[int]:
    """Rejoin clusters that are the same voice, judged on averaged centroids."""
    try:
        import numpy as np
    except Exception:
        return labels
    if embeds is None or len(set(labels)) < 2:
        return labels

    current = list(labels)
    while True:
        groups = sorted(set(current))
        if len(groups) < 2:
            return current
        centroids = {}
        for group in groups:
            rows = [embeds[i] for i, v in enumerate(current) if v == group]
            centroid = np.mean(rows, axis=0)
            centroids[group] = centroid / (np.linalg.norm(centroid) + 1e-9)

        best = None
        for i, a in enumerate(groups):
            for b in groups[i + 1 :]:
                distance = 1.0 - float(np.dot(centroids[a], centroids[b]))
                if best is None or distance < best[0]:
                    best = (distance, a, b)
        if best is None or best[0] > CENTROID_MERGE_DISTANCE:
            return current
        # Last two leftover clusters that are both real voices and sit
        # just inside the merge threshold are two people on a compressed
        # mix (Zoom 09-02 two remotes at 0.213). Slack meetings never
        # land here: when two large voices remain they are already > 0.23.
        # Do not drop CENTROID_MERGE_DISTANCE globally — 0.21 mints a
        # phantom on 08-26.
        if (
            best[0] >= SPLIT_MIN_CENTROID_DISTANCE
            and len(groups) == 2
            and current.count(best[1]) * EMBED_HOP_SEC >= MIN_SPEAKER_SPEECH_SEC
            and current.count(best[2]) * EMBED_HOP_SEC >= MIN_SPEAKER_SPEECH_SEC
        ):
            return current
        _, keep, drop = best
        current = [keep if v == drop else v for v in current]


def smooth_window_labels(labels: list[int]) -> list[int]:
    """Mode filter so one odd window cannot mint a speaker mid-sentence."""
    width = SPEAKER_SMOOTH_WINDOWS
    if width < 3 or len(labels) < width:
        return labels
    half = width // 2
    out = list(labels)
    for i in range(len(labels)):
        lo = max(0, i - half)
        hi = min(len(labels), i + half + 1)
        counts: dict[int, int] = {}
        for v in labels[lo:hi]:
            counts[v] = counts.get(v, 0) + 1
        best = max(counts.items(), key=lambda kv: (kv[1], kv[0] == labels[i]))
        out[i] = best[0]
    return out


def label_word_speakers(
    words: list[tuple[float, float, str]],
    windows: list[tuple[float, float]],
    labels: list[int],
) -> list[int]:
    """Each word takes the dominant voice over its own span.

    Word-level granularity is what separates a handoff like
    "Alright Blake | Hey there, yesterday I met with the vendor" — Whisper hands that
    back as one segment, so segment-level labeling cannot split it.
    """
    if not windows:
        return [0] * len(words)

    order = sorted(range(len(windows)), key=lambda i: windows[i][0])
    starts = [windows[i][0] for i in order]
    ends = [windows[i][1] for i in order]
    labs = [labels[i] for i in order]

    import bisect

    out: list[int] = []
    for w0, w1, _ in words:
        lo = bisect.bisect_left(ends, w0)
        weights: dict[int, float] = {}
        for i in range(lo, len(starts)):
            if starts[i] > w1:
                break
            overlap = min(w1, ends[i]) - max(w0, starts[i])
            if overlap > 0:
                weights[labs[i]] = weights.get(labs[i], 0.0) + overlap
        if weights:
            out.append(max(weights.items(), key=lambda kv: kv[1])[0])
            continue
        mid = (w0 + w1) * 0.5
        nearest = min(
            range(len(starts)),
            key=lambda i: min(abs(mid - starts[i]), abs(mid - ends[i])),
        )
        out.append(labs[nearest])
    return out


def label_centroids(embeds, labels: list[int]) -> dict:
    """Unit-length mean embedding per cluster, skipping thinly-fed ones."""
    try:
        import numpy as np
    except Exception:
        return {}
    if embeds is None:
        return {}
    counts: dict[int, int] = {}
    for label in labels:
        counts[label] = counts.get(label, 0) + 1
    out = {}
    for label, count in counts.items():
        if count < BOUNDARY_MIN_WINDOWS:
            continue
        centroid = embeds[[i for i, v in enumerate(labels) if v == label]].mean(axis=0)
        out[label] = centroid / (np.linalg.norm(centroid) + 1e-9)
    return out


def words_covered_by_windows(
    words: list[tuple[float, float, str]],
    windows: list[tuple[float, float]],
) -> list[bool]:
    """Which words actually sit inside a clustered window."""
    if not windows:
        return [False] * len(words)
    import bisect

    starts = [w[0] for w in windows]
    ends = [w[1] for w in windows]
    out: list[bool] = []
    for w0, w1, _ in words:
        i = bisect.bisect_left(ends, w0)
        covered = False
        while i < len(starts) and starts[i] <= w1:
            if min(w1, ends[i]) - max(w0, starts[i]) > 0:
                covered = True
                break
            i += 1
        out.append(covered)
    return out


def consecutive_runs(
    words: list[tuple[float, float, str]],
    selected: list[bool],
) -> list[tuple[int, int]]:
    """Group flagged words into utterance-sized runs of neighbours.

    Deciding per run rather than per word keeps adjacent words from disagreeing
    and shredding a phrase across two speakers.
    """
    runs: list[tuple[int, int]] = []
    i = 0
    while i < len(words):
        if not selected[i]:
            i += 1
            continue
        last = i
        while (
            last + 1 < len(words)
            and selected[last + 1]
            and words[last + 1][0] - words[last][1] <= ORPHAN_RUN_GAP_SEC
        ):
            last += 1
        runs.append((i, last))
        i = last + 1
    return runs


def longest_island_within(is_voiced, t0: float, t1: float):
    """The most substantial speech run inside a range, clipped to it.

    Clipping matters: an island may continue into the next person's turn, and
    embedding that would answer the wrong question.
    """
    best = None
    for start, end in speech_islands_in(is_voiced, t0, t1, 0.0):
        lo, hi = max(start, t0), min(end, t1)
        if hi - lo <= 0:
            continue
        if best is None or (hi - lo) > (best[1] - best[0]):
            best = (lo, hi)
    return best


def attribute_words_by_island(
    mel,
    wav,
    words: list[tuple[float, float, str]],
    word_labels: list[int],
    redo: list[bool],
    centroids: dict,
    require_margin: bool,
) -> list[int]:
    """Re-judge selected words one speech island at a time.

    Islands are the natural unit here: they are separated by silence, so each
    one belongs to a single person, and even a 0.3s island ranks the right voice
    first when compared against centroids fed by whole turns.
    """
    if mel is None or not centroids or not any(redo):
        return word_labels
    try:
        import numpy as np
    except Exception:
        return word_labels
    is_voiced = voiced_frames(wav)
    if is_voiced is None:
        return word_labels

    refined = list(word_labels)
    for first, last in consecutive_runs(words, redo):
        # Whisper pads word times generously — "All right" is timestamped at
        # 1.76s but holds only 0.30s of speech — so measure the real island.
        island = longest_island_within(
            is_voiced, words[first][0] - 0.15, words[last][1] + 0.15
        )
        if island is None or island[1] - island[0] < ORPHAN_MIN_ISLAND_SEC:
            continue
        span = min(island[1] - island[0], BOUNDARY_ISLAND_MAX_SEC)
        probe = embed_windows(mel, wav, [island[0]], length_sec=span)
        if probe is None or not len(probe):
            continue
        vector = probe[0] / (np.linalg.norm(probe[0]) + 1e-9)
        ranked = sorted(
            (1.0 - float(np.dot(vector, centroids[l])), l) for l in centroids
        )
        # Too close to call: keep what time proximity already implied, since a
        # fragment sitting right against a turn usually belongs to it.
        if require_margin and len(ranked) > 1:
            if ranked[1][0] - ranked[0][0] < ORPHAN_MIN_MARGIN:
                continue
        for i in range(first, last + 1):
            refined[i] = ranked[0][1]
    return refined


def reattribute_small_clusters(
    mel,
    wav,
    words: list[tuple[float, float, str]],
    word_labels: list[int],
    centroids: dict,
) -> list[int]:
    """Split a barely-there cluster across the real voices it actually contains.

    Folding such a cluster into one speaker wholesale is wrong when it spans a
    handoff: one stray cluster here held the tail of Blake's turn *and* Alex's
    "All right" that followed it.
    """
    spans: dict[int, list[float]] = {}
    for seg in regroup_words_by_speaker(words, word_labels):
        spans.setdefault(seg["_label"], []).append(seg["end"] - seg["start"])
    small = {
        label
        for label, lengths in spans.items()
        if not is_real_voice(lengths) or label not in centroids
    }
    keep = {label: vector for label, vector in centroids.items() if label not in small}
    if not small or not keep:
        return word_labels
    redo = [label in small for label in word_labels]
    return attribute_words_by_island(
        mel, wav, words, word_labels, redo, keep, require_margin=False
    )


def island_snapped_boundary(
    mel,
    wav,
    is_voiced,
    middle: float,
    centroid_before,
    centroid_after,
) -> float | None:
    """Place a handoff in the pause between utterances, or None if there is none.

    Each utterance around the handoff is scored against the two voices, then the
    cut goes in the silence where the answer flips. Returns None when the zone
    holds a single unbroken run of speech, leaving the caller to scan inside it.
    """
    try:
        import numpy as np
    except Exception:
        return None

    islands = speech_islands_in(
        is_voiced,
        middle - BOUNDARY_SEARCH_SEC,
        middle + BOUNDARY_SEARCH_SEC,
        BOUNDARY_MIN_ISLAND_SEC,
    )
    if len(islands) < 2:
        return None

    starts, lengths = [], []
    for t0, t1 in islands:
        span = min(t1 - t0, BOUNDARY_ISLAND_MAX_SEC)
        starts.append(t0 + (t1 - t0 - span) * 0.5)
        lengths.append(span)
    scores = []
    for start, span in zip(starts, lengths):
        probe = embed_windows(mel, wav, [start], length_sec=span)
        if probe is None or not len(probe):
            return None
        vector = probe[0] / (np.linalg.norm(probe[0]) + 1e-9)
        scores.append(
            float(np.dot(vector, centroid_after) - np.dot(vector, centroid_before))
        )

    # Weight by how much speech backs each verdict: a confident 1.7s utterance
    # should outvote a 0.3s fragment that scores near-tied between the two.
    weights = np.array(lengths, dtype=float)
    values = np.array(scores, dtype=float)

    def weighted(lo: int, hi: int) -> float:
        total = weights[lo:hi].sum()
        if total <= 0:
            return 0.0
        return float((values[lo:hi] * weights[lo:hi]).sum() / total)

    best_cut, best_gain = None, 0.0
    for cut in range(1, len(scores)):
        gain = weighted(cut, len(scores)) - weighted(0, cut)
        if gain > best_gain:
            best_cut, best_gain = cut, gain
    if best_cut is None:
        return None
    return (islands[best_cut - 1][1] + islands[best_cut][0]) * 0.5


def refine_handoff_boundaries(
    mel,
    wav,
    words: list[tuple[float, float, str]],
    word_labels: list[int],
    embeds,
    labels: list[int],
    covered: list[bool] | None = None,
) -> list[int]:
    """Move a handoff to the word where the voice actually changes.

    Clustering runs on 3s windows, so a window straddling a handoff is a blend
    of both voices and the label flips a beat early. That steals the last words
    of a turn — "Casey you're next" is Alex talking, not Casey.

    Each side already has a well-fed centroid, so the boundary is found by
    sliding a window across the handoff and asking which centroid it resembles.
    The crossover is where the split between the two answers is cleanest.
    """
    if mel is None or embeds is None or len(words) != len(word_labels):
        return word_labels
    try:
        import numpy as np
    except Exception:
        return word_labels

    centroids = label_centroids(embeds, labels)
    is_voiced = voiced_frames(wav)
    refined = list(word_labels)
    for i in range(1, len(words)):
        before, after = word_labels[i - 1], word_labels[i]
        if before == after:
            continue
        if before not in centroids or after not in centroids:
            continue
        gap_start, gap_end = words[i - 1][1], words[i][0]
        if gap_end - gap_start > BOUNDARY_MAX_GAP_SEC:
            continue

        middle = (gap_start + gap_end) * 0.5

        # People leave a pause when handing off, so the boundary almost always
        # sits in silence. Scoring whole utterances and cutting in the gap
        # between them keeps a turn's tail from being handed to the next voice.
        boundary = None
        if is_voiced is not None:
            boundary = island_snapped_boundary(
                mel, wav, is_voiced, middle, centroids[before], centroids[after]
            )
        if boundary is None:
            # No pause: leave the clustering cut. Snap-to-pause runs later and
            # will move an abutted mid-clause cut to the nearest silence.
            continue
        for j in range(len(words)):
            w0, w1, _ = words[j]
            if w1 < middle - BOUNDARY_SEARCH_SEC or w0 > middle + BOUNDARY_SEARCH_SEC:
                continue
            if word_labels[j] not in (before, after):
                continue
            if covered is not None and not covered[j]:
                continue
            refined[j] = before if (w0 + w1) * 0.5 < boundary else after
    return refined


def _vocative_token(token: str) -> str:
    return token.lower().strip(".,!?;:\"'`-")


def vocative_prefix_end(
    words: list[tuple[float, float, str]],
    lo: int,
    hi: int,
    is_voiced=None,
) -> int | None:
    """First answer-word index after a leading name-call, or None.

    `lo`/`hi` are inclusive indices of the incoming speaker's run. The prefix
    must contain a name and leave at least `VOCATIVE_MIN_LEFTOVER_WORDS` so a
    one-word "Casey?" acknowledgment is not stolen wholesale.
    """
    if hi - lo + 1 < VOCATIVE_MIN_LEFTOVER_WORDS + 1:
        return None
    j = lo
    saw_name = False
    last_name = None
    limit = min(hi, lo + VOCATIVE_MAX_PREFIX_WORDS - 1)
    while j <= limit:
        token = _vocative_token(words[j][2])
        if token in VOCATIVE_NAMES:
            saw_name = True
            last_name = j
            j += 1
            continue
        if not saw_name and token in VOCATIVE_LEADING_FILLER:
            j += 1
            continue
        if saw_name and token in VOCATIVE_BETWEEN_FILLER:
            j += 1
            continue
        if saw_name and token in VOCATIVE_TAIL:
            j += 1
            continue
        break
    if not saw_name or last_name is None:
        return None
    if j > hi or j - lo < 1:
        return None
    leftover = hi - j + 1
    if leftover < VOCATIVE_MIN_LEFTOVER_WORDS:
        return None
    name_count = 0
    has_tail = False
    for k in range(lo, j):
        token = _vocative_token(words[k][2])
        if token in VOCATIVE_NAMES:
            name_count += 1
        if token in VOCATIVE_TAIL:
            has_tail = True
    greet_at = None
    for k in range(j, min(hi + 1, j + 5)):
        if _vocative_token(words[k][2]) in VOCATIVE_GREETING:
            greet_at = k
            break
    if greet_at is not None and hi - greet_at + 1 >= VOCATIVE_MIN_LEFTOVER_WORDS:
        return greet_at
    # A lone name with no greeting is usually "thank you Blake" from the
    # incoming speaker, not a host call. Need two names ("thanks X, Y") or
    # "you're next" before a pause-only cut is allowed.
    if name_count < 2 and not has_tail:
        return None
    gap = words[j][0] - words[last_name][1]
    if gap >= VOCATIVE_MIN_GAP_SEC:
        return j
    if is_voiced is not None:
        named = speech_island(is_voiced, (words[last_name][0] + words[last_name][1]) * 0.5)
        after = speech_island(is_voiced, (words[j][0] + words[j][1]) * 0.5)
        if named is not None and after is not None and named != after:
            return j
    return None


def keep_vocative_with_caller(
    words: list[tuple[float, float, str]],
    word_labels: list[int],
    is_voiced=None,
) -> list[int]:
    """Move a name-call at the start of B back onto A.

    Clustering already split the two voices. The 3s window still paints the
    host's "thanks blake uh drew" with Drew's color because those words sit in
    the same island as "hello". Acoustic snap cannot hear a vocative.
    """
    if len(words) != len(word_labels) or len(words) < 3:
        return word_labels
    refined = list(word_labels)
    i = 1
    while i < len(words):
        before, after = word_labels[i - 1], word_labels[i]
        if before == after:
            i += 1
            continue
        k = i
        while k + 1 < len(words) and word_labels[k + 1] == after:
            k += 1
        cut = vocative_prefix_end(words, i, k, is_voiced)
        if cut is not None:
            for j in range(i, cut):
                refined[j] = before
        i = k + 1
    return refined


def _is_vocative_greeting_cut(
    words: list[tuple[float, float, str]],
    labels: list[int],
    i: int,
) -> bool:
    """True when this cut is name-call | greeting — leave it, even if abutted."""
    if _vocative_token(words[i][2]) not in VOCATIVE_GREETING:
        return False
    lo = max(0, i - VOCATIVE_MAX_PREFIX_WORDS)
    return any(_vocative_token(words[j][2]) in VOCATIVE_NAMES for j in range(lo, i))


def _nearest_pause_index(
    words: list[tuple[float, float, str]],
    cut: int,
    search_sec: float,
    min_pause: float,
) -> int | None:
    """Index of the word after the pause nearest to `cut`, or None."""
    t = words[cut][0]
    best: int | None = None
    best_dist = search_sec + 1.0
    lo = cut
    while lo > 0 and t - words[lo][0] <= search_sec:
        lo -= 1
    hi = cut
    while hi + 1 < len(words) and words[hi][0] - t <= search_sec:
        hi += 1
    for j in range(max(1, lo), min(len(words), hi + 1)):
        gap = words[j][0] - words[j - 1][1]
        if gap < min_pause:
            continue
        dist = abs(words[j][0] - t)
        if dist < best_dist:
            best, best_dist = j, dist
    return best


def snap_abutted_changes_to_pauses(
    words: list[tuple[float, float, str]],
    word_labels: list[int],
) -> list[int]:
    """Move a speaker change that sits inside a clause to the nearest pause.

    Clustering and the old sliding probe both cut between abutted words
    ("I think what I'm" | "going to do is"). The sentence should stay whole.
    Vocative greeting cuts are kept — those are a name then hello, not a clause.
    """
    if len(words) != len(word_labels) or len(words) < 3:
        return word_labels
    refined = list(word_labels)
    i = 1
    while i < len(words):
        if refined[i] == refined[i - 1]:
            i += 1
            continue
        gap = words[i][0] - words[i - 1][1]
        if gap >= SNAP_MIN_PAUSE_SEC:
            i += 1
            continue
        if _is_vocative_greeting_cut(words, refined, i):
            i += 1
            continue
        before, after = refined[i - 1], refined[i]
        pause = _nearest_pause_index(
            words, i, SNAP_SEARCH_SEC, SNAP_MIN_PAUSE_SEC
        )
        if pause is not None and pause != i:
            if pause < i:
                for j in range(pause, i):
                    if refined[j] == before:
                        refined[j] = after
            else:
                for j in range(i, pause):
                    if refined[j] == after:
                        refined[j] = before
            i = max(i, pause) + 1
            continue
        start = i - 1
        while start > 0 and words[start][0] - words[start - 1][1] < SNAP_MIN_PAUSE_SEC:
            start -= 1
        end = i
        while (
            end + 1 < len(words)
            and words[end + 1][0] - words[end][1] < SNAP_MIN_PAUSE_SEC
        ):
            end += 1
        dur_before = sum(
            words[j][1] - words[j][0]
            for j in range(start, end + 1)
            if refined[j] == before
        )
        dur_after = sum(
            words[j][1] - words[j][0]
            for j in range(start, end + 1)
            if refined[j] == after
        )
        winner = before if dur_before >= dur_after else after
        for j in range(start, end + 1):
            if refined[j] in (before, after):
                refined[j] = winner
        i = end + 1
    return refined


def _mean_centroid(embeds, indices: list[int]):
    if not indices:
        return None
    try:
        import numpy as np
    except Exception:
        return None
    vec = np.mean([embeds[i] for i in indices], axis=0)
    n = float(np.linalg.norm(vec)) + 1e-9
    return vec / n


def _windows_overlapping(
    windows: list[tuple[float, float]], t0: float, t1: float
) -> list[int]:
    return [i for i, (a, b) in enumerate(windows) if a < t1 and b > t0]


def _windows_overlapping_spans(
    windows: list[tuple[float, float]], spans: list[tuple[float, float]]
) -> list[int]:
    if not spans:
        return []
    return [
        i
        for i, (a, b) in enumerate(windows)
        if any(a < t1 and b > t0 for t0, t1 in spans)
    ]


def _same_label_windows_before(
    words: list[tuple[float, float, str]],
    labels: list[int],
    windows: list[tuple[float, float]],
    name_i: int,
    lab: int,
) -> list[int]:
    """Embedding windows covering recent same-label speech before a name-call.

    Skip other speakers (standup handoff). Stop at a long same-label silence
    so a 4-minute host turn with a 2-minute pause does not average the opening
    into the closer.
    """
    collected: list[int] = []
    seen: set[int] = set()
    speech = 0.0
    last_j: int | None = None
    for j in range(name_i - 1, -1, -1):
        if labels[j] != lab:
            continue
        if last_j is not None:
            gap = words[last_j][0] - words[j][1]
            if gap >= SPLIT_SILENCE_BREAK_SEC and all(
                labels[t] == lab for t in range(j + 1, last_j)
            ):
                break
        last_j = j
        speech += words[j][1] - words[j][0]
        w0, w1, _ = words[j]
        for k, (a, b) in enumerate(windows):
            if k in seen:
                continue
            if a < w1 and b > w0:
                seen.add(k)
                collected.append(k)
        if speech >= SPLIT_BEFORE_SPEECH_SEC and len(collected) >= SPLIT_MIN_WINDOWS:
            break
    if len(collected) >= SPLIT_MIN_WINDOWS:
        return collected
    # Few same-label words in the closer (08-18 host "Casey you're next" is
    # 2s of tokens). Use voiced windows in the last 25s that do not overlap
    # a different speaker.
    t1 = words[name_i][0]
    t0 = t1 - SPLIT_BEFORE_SPEECH_SEC
    other = [
        (a, b)
        for (a, b, _), L in zip(words, labels)
        if L != lab and a < t1 and b > t0
    ]
    clock_idx = []
    for k, (a, b) in enumerate(windows):
        if a >= t1 or b <= t0:
            continue
        if any(a < ob and b > oa for oa, ob in other):
            continue
        clock_idx.append(k)
    return clock_idx if len(clock_idx) >= len(collected) else collected


def _pause_turn_end(
    words: list[tuple[float, float, str]], start: int, hi: int, min_sec: float
) -> int:
    """Last word of the pause-bounded turn starting at `start`."""
    j = start
    while j < hi:
        if words[j + 1][0] - words[j][1] >= 1.5:
            if words[j][1] - words[start][0] >= min_sec:
                return j
        j += 1
    return hi


def _pause_islands(
    words: list[tuple[float, float, str]], lo: int, hi: int, gap_sec: float = 1.5
) -> list[tuple[int, int]]:
    out: list[tuple[int, int]] = []
    s = lo
    for i in range(lo, hi):
        if words[i + 1][0] - words[i][1] >= gap_sec:
            out.append((s, i))
            s = i + 1
    out.append((s, hi))
    return out


def split_merged_at_vocative(
    words: list[tuple[float, float, str]],
    word_labels: list[int],
    windows: list[tuple[float, float]],
    embeds,
) -> list[int]:
    """Split a cluster that ate two people at a name-call.

    Must run *before* keep_vocative_with_caller. Vocative moves "And Blake"
    onto the previous speaker, leaving Blake's "Hey there" on the merged label with no name
    left in the run — then this never fires.

    Alex says "Excellent. And Blake." then Blake talks for minutes, but both
    have the same label because their voices clustered as one. If the local
    centroids on either side of that call actually separate, mint a new
    label from the greeting through the rest of this run, then re-home
    later islands of the old label.
    """
    if (
        embeds is None
        or not windows
        or len(words) != len(word_labels)
        or len(words) < 8
    ):
        return word_labels
    try:
        import numpy as np
    except Exception:
        return word_labels

    original = list(word_labels)
    refined = list(word_labels)
    next_id = max(refined) + 1

    runs: list[tuple[int, int, int]] = []
    start = 0
    for i in range(1, len(words) + 1):
        if i == len(words) or original[i] != original[start]:
            runs.append((start, i - 1, original[start]))
            start = i

    def _try_starts(lo: int, hi: int) -> list[int]:
        starts: list[int] = []
        for i in range(lo, hi):
            if _vocative_token(words[i][2]) in VOCATIVE_NAMES:
                starts.append(max(lo, i - 6))
                starts.append(i)
            if i == lo or words[i][0] - words[i - 1][1] >= VOCATIVE_MIN_GAP_SEC:
                starts.append(i)
        # Unique, keep order.
        seen: set[int] = set()
        out: list[int] = []
        for i in starts:
            if i not in seen:
                seen.add(i)
                out.append(i)
        return out

    for lo, hi, lab in runs:
        if words[hi][1] - words[lo][0] < SPLIT_MIN_AFTER_SEC:
            continue
        found = None
        for i in _try_starts(lo, hi):
            cut = vocative_prefix_end(words, i, hi)
            if cut is None:
                continue
            after_hi = _pause_turn_end(words, cut, hi, SPLIT_MIN_AFTER_SEC)
            after_sec = words[after_hi][1] - words[cut][0]
            if after_sec < SPLIT_MIN_AFTER_SEC:
                continue
            before_idx = _same_label_windows_before(
                words, original, windows, i, lab
            )
            after_idx = _windows_overlapping_spans(
                windows, [(words[cut][0], words[after_hi][1])]
            )
            if (
                len(before_idx) < SPLIT_MIN_WINDOWS
                or len(after_idx) < SPLIT_MIN_WINDOWS
            ):
                continue
            c0 = _mean_centroid(embeds, before_idx)
            c1 = _mean_centroid(embeds, after_idx)
            if c0 is None or c1 is None:
                continue
            dist = 1.0 - float(np.dot(c0, c1))
            if dist < SPLIT_MIN_CENTROID_DISTANCE:
                continue
            found = (cut, after_hi, c0, c1)
            break
        if found is None:
            continue
        cut, after_hi, c0, c1 = found
        new_id = next_id
        next_id += 1
        # Rest of this run after the greeting is the called person, not a
        # 13s pause-capped slice. Prefix stays the old label.
        for j in range(cut, hi + 1):
            refined[j] = new_id
        for rlo, rhi, rlab in runs:
            if rlab != lab:
                continue
            if rlo == lo and rhi == hi:
                continue
            for ilo, ihi in _pause_islands(words, rlo, rhi):
                idxs = _windows_overlapping_spans(
                    windows, [(words[ilo][0], words[ihi][1])]
                )
                cen = _mean_centroid(embeds, idxs) if idxs else None
                if cen is None:
                    continue
                d0 = 1.0 - float(np.dot(cen, c0))
                d1 = 1.0 - float(np.dot(cen, c1))
                if d1 < d0:
                    for j in range(ilo, ihi + 1):
                        if original[j] == lab:
                            refined[j] = new_id
    return refined


def regroup_words_by_speaker(
    words: list[tuple[float, float, str]],
    labels: list[int],
) -> list[dict]:
    """Consecutive words sharing a voice become one segment."""
    segments: list[dict] = []
    for (w0, w1, token), label in zip(words, labels):
        prev = segments[-1] if segments else None
        if (
            prev is not None
            and prev["_label"] == label
            and w0 - prev["end"] <= WORD_REGROUP_GAP_SEC
        ):
            prev["end"] = max(prev["end"], w1)
            prev["text"] = f'{prev["text"]} {token}'.strip()
        else:
            segments.append(
                {"start": w0, "end": w1, "text": token, "_label": label}
            )
    return segments


def is_real_voice(turn_lengths: list[float]) -> bool:
    """Whether a cluster is a person rather than clustering noise.

    Total speech alone can't tell a short standup from scattered backchannels:
    a colleague with one 8s turn and a phantom built from six "Okay"s spread
    over an hour look the same by total. One held turn is the tell.
    """
    if not turn_lengths:
        return False
    return (
        sum(turn_lengths) >= MIN_SPEAKER_SPEECH_SEC
        or max(turn_lengths) >= MIN_SPEAKER_TURN_SEC
    )


def absorb_small_voices(segments: list[dict], embeds, labels: list[int]) -> list[dict]:
    """Fold barely-there voices into the nearest real one by voice, not by clock.

    The old crumb absorber picked the nearest speaker by average timestamp, which
    on a round-robin standup is close to random.
    """
    if not segments:
        return segments
    try:
        import numpy as np
    except Exception:
        return segments

    spans: dict[int, list[float]] = {}
    for seg in segments:
        spans.setdefault(seg["_label"], []).append(seg["end"] - seg["start"])
    speech = {label: sum(lengths) for label, lengths in spans.items()}
    keep = {label for label, lengths in spans.items() if is_real_voice(lengths)}
    small = {k for k in speech if k not in keep}
    if not small or not keep:
        return segments

    centroids: dict[int, "np.ndarray"] = {}
    for label in set(labels):
        rows = [embeds[i] for i, v in enumerate(labels) if v == label]
        if rows:
            centroids[label] = np.mean(rows, axis=0)

    remap: dict[int, int] = {}
    for label in small:
        if label not in centroids:
            remap[label] = sorted(keep, key=lambda k: -speech[k])[0]
            continue
        remap[label] = min(
            (k for k in keep if k in centroids),
            key=lambda k: 1.0
            - float(
                np.dot(centroids[label], centroids[k])
                / (
                    np.linalg.norm(centroids[label])
                    * np.linalg.norm(centroids[k])
                    + 1e-9
                )
            ),
        )

    for seg in segments:
        seg["_label"] = remap.get(seg["_label"], seg["_label"])
    return segments


def diarize_system_by_voice(
    wav_path: str,
    words: list[tuple[float, float, str]],
    name_start: int = 2,
) -> list[dict] | None:
    """Label the system track by clustering voice windows, then labeling words.

    Returns None when the embedding stack is unavailable so the caller can drop
    back to the energy-island path.
    """
    if not words:
        return None
    try:
        wav = load_mono_16k(wav_path)
    except Exception:
        return None

    mel = voice_mel(wav)
    windows = voiced_windows(wav)
    embeds = embed_windows(mel, wav, [w[0] for w in windows])
    if embeds is None or not len(embeds):
        return None

    embeds = smooth_embeddings(embeds, windows)
    labels = merge_clusters_by_centroid(cluster_embeddings(embeds), embeds)
    labels = smooth_window_labels(labels)
    centroids = label_centroids(embeds, labels)
    word_labels = label_word_speakers(words, windows, labels)
    word_labels = reattribute_small_clusters(mel, wav, words, word_labels, centroids)
    covered = words_covered_by_windows(words, windows)
    word_labels = refine_handoff_boundaries(
        mel, wav, words, word_labels, embeds, labels, covered
    )
    word_labels = attribute_words_by_island(
        mel,
        wav,
        words,
        word_labels,
        [not flag for flag in covered],
        centroids,
        require_margin=True,
    )
    word_labels = split_merged_at_vocative(words, word_labels, windows, embeds)
    word_labels = keep_vocative_with_caller(
        words, word_labels, voiced_frames(wav)
    )
    word_labels = snap_abutted_changes_to_pauses(words, word_labels)
    segments = regroup_words_by_speaker(words, word_labels)
    segments = absorb_small_voices(segments, embeds, labels)

    rename: dict[int, str] = {}
    next_n = name_start
    out: list[dict] = []
    for seg in segments:
        label = seg.pop("_label")
        if label not in rename:
            rename[label] = f"Speaker {next_n}"
            next_n += 1
        seg["speaker"] = rename[label]
        out.append(seg)
    return out


def system_speech_islands(wav_path: str) -> list[tuple[float, float]]:
    """Contiguous system-audio regions separated by silence — one remote turn each."""
    import audioop

    with wave.open(wav_path, "rb") as wf:
        rate = wf.getframerate()
        width = wf.getsampwidth()
        channels = wf.getnchannels()
        raw = wf.readframes(wf.getnframes())
    if channels > 1:
        raw = audioop.tomono(raw, width, 0.5, 0.5)
    frame = max(1, int(rate * ISLAND_FRAME_SEC))
    bytes_per = width * frame
    rms_list: list[float] = []
    for i in range(0, len(raw) - bytes_per + 1, bytes_per):
        rms_list.append(float(audioop.rms(raw[i : i + bytes_per], width)))
    if not rms_list:
        return []
    peak = max(rms_list)
    thr = max(80.0, peak * 0.12)
    gap_frames = max(1, int(ISLAND_GAP_SEC / ISLAND_FRAME_SEC))
    islands: list[tuple[float, float]] = []
    start: float | None = None
    silent = 0
    for i, rms in enumerate(rms_list):
        t = i * ISLAND_FRAME_SEC
        if rms >= thr:
            if start is None:
                start = t
            silent = 0
        elif start is not None:
            silent += 1
            if silent >= gap_frames:
                end = (i - silent + 1) * ISLAND_FRAME_SEC
                if end - start >= ISLAND_MIN_SEC:
                    islands.append((start, end))
                start = None
                silent = 0
    if start is not None:
        end = len(rms_list) * ISLAND_FRAME_SEC
        if end - start >= ISLAND_MIN_SEC:
            islands.append((start, end))
    return islands


def merge_similar_islands(
    wav_path: str,
    islands: list[tuple[float, float]],
) -> list[int]:
    """Map island index → speaker slot; merge only if same remote voice returns."""
    n = len(islands)
    if n <= 1:
        return list(range(n))
    try:
        import librosa
        import numpy as np
        from resemblyzer import VoiceEncoder, preprocess_wav
    except Exception:
        return list(range(n))

    rate = 16000
    wav, _ = librosa.load(wav_path, sr=rate, mono=True)
    encoder = VoiceEncoder()
    embeds: list = []
    for a, b in islands:
        start = max(0, int(a * rate))
        end = min(len(wav), int(b * rate))
        chunk = wav[start:end]
        if len(chunk) < int(DIARIZE_MIN_SEC * rate):
            embeds.append(None)
            continue
        chunk = preprocess_wav(chunk, source_sr=rate)
        if len(chunk) < int(DIARIZE_MIN_SEC * rate):
            embeds.append(None)
            continue
        embeds.append(encoder.embed_utterance(chunk))

    slot = [0] * n
    next_slot = 1
    for i in range(1, n):
        merged = False
        if embeds[i] is not None:
            for j in range(i):
                if embeds[j] is None:
                    continue
                dist = 1.0 - float(
                    np.dot(embeds[i], embeds[j])
                    / (
                        np.linalg.norm(embeds[i]) * np.linalg.norm(embeds[j])
                        + 1e-9
                    )
                )
                if dist <= ISLAND_EMBED_MERGE_DISTANCE:
                    slot[i] = slot[j]
                    merged = True
                    break
        if not merged:
            slot[i] = next_slot
            next_slot += 1
    return slot


def _segment_embedding(encoder, wav, rate: int, seg: dict):
    from resemblyzer import preprocess_wav

    start = max(0, int(float(seg["start"]) * rate))
    end = min(len(wav), int(float(seg["end"]) * rate))
    chunk = wav[start:end]
    if len(chunk) < int(DIARIZE_MIN_SEC * rate):
        return None
    chunk = preprocess_wav(chunk, source_sr=rate)
    if len(chunk) < int(DIARIZE_MIN_SEC * rate):
        return None
    return encoder.embed_utterance(chunk)


def split_energy_islands_by_voice(
    wav_path: str,
    energy_islands: list[tuple[float, float]],
    segments: list[dict],
) -> list[tuple[float, float]]:
    """
    Subdivide continuous energy islands when Whisper segments show a voice change.
    Catches ad → host in one video without needing a silence gap.
    """
    if not energy_islands or not segments:
        return energy_islands
    try:
        import librosa
        import numpy as np
        from resemblyzer import VoiceEncoder
    except Exception:
        return energy_islands

    rate = 16000
    wav, _ = librosa.load(wav_path, sr=rate, mono=True)
    encoder = VoiceEncoder()

    refined: list[tuple[float, float]] = []
    for a, b in energy_islands:
        in_island = [
            s
            for s in segments
            if max(0.0, min(float(s["end"]), b) - max(float(s["start"]), a)) > 0.15
        ]
        in_island.sort(key=lambda s: float(s["start"]))
        if len(in_island) < 2:
            refined.append((a, b))
            continue

        embeds = [_segment_embedding(encoder, wav, rate, s) for s in in_island]
        cuts = [a]
        last_emb = embeds[0]
        for i in range(1, len(in_island)):
            emb = embeds[i]
            if last_emb is None:
                last_emb = emb
                continue
            if emb is None:
                continue
            dist = 1.0 - float(
                np.dot(last_emb, emb)
                / (np.linalg.norm(last_emb) * np.linalg.norm(emb) + 1e-9)
            )
            if dist >= VOICE_CHANGE_DIST:
                # New voice starts at this segment — skip crumb-sized cuts.
                cut = max(cuts[-1] + 0.2, float(in_island[i]["start"]))
                left_dur = cut - cuts[-1]
                right_dur = b - cut
                trig = in_island[i]
                trig_words = len((trig.get("text") or "").split())
                trig_dur = float(trig["end"]) - float(trig["start"])
                substantial = (
                    trig_words >= VOICE_CHANGE_MIN_WORDS
                    or trig_dur >= VOICE_CHANGE_MIN_SEC
                )
                if (
                    cut < b - 0.4
                    and left_dur >= VOICE_CHANGE_MIN_SEC
                    and right_dur >= VOICE_CHANGE_MIN_SEC
                    and substantial
                ):
                    cuts.append(cut)
            last_emb = emb
        cuts.append(b)
        for i in range(len(cuts) - 1):
            if cuts[i + 1] - cuts[i] >= ISLAND_MIN_SEC:
                refined.append((cuts[i], cuts[i + 1]))
    return refined or energy_islands


def diarize_by_speech_islands(
    wav_path: str,
    segments: list[dict],
    name_start: int = 2,
) -> list[dict]:
    """Label system segments: energy islands, then split on clear voice changes."""
    if not segments:
        return segments
    energy = system_speech_islands(wav_path)
    if not energy:
        for seg in segments:
            seg["speaker"] = f"Speaker {name_start}"
        return segments

    islands = split_energy_islands_by_voice(wav_path, energy, segments)
    island_slots = merge_similar_islands(wav_path, islands)

    labeled: list[dict] = []
    for seg in segments:
        s0, s1 = float(seg["start"]), float(seg["end"])
        best_i = 0
        best_ov = -1.0
        for i, (a, b) in enumerate(islands):
            ov = max(0.0, min(s1, b) - max(s0, a))
            if ov > best_ov:
                best_ov = ov
                best_i = i
        if best_ov <= 0:
            mid = (s0 + s1) * 0.5
            best_i = min(
                range(len(islands)),
                key=lambda i: min(
                    abs(mid - islands[i][0]), abs(mid - islands[i][1])
                ),
            )
        a, b = islands[best_i]
        # Clamp so Whisper spans across silence/voice cuts don't steal gaps.
        c0 = max(s0, a)
        c1 = min(s1, b)
        if c1 - c0 < 0.15:
            continue
        item = dict(seg)
        item["start"] = c0
        item["end"] = c1
        item["speaker"] = f"__slot_{island_slots[best_i]}"
        labeled.append(item)

    # Dense Speaker N by first appearance (no skipped numbers from unused slots).
    rename: dict[str, str] = {}
    next_n = name_start
    for seg in labeled:
        key = str(seg["speaker"])
        if key not in rename:
            rename[key] = f"Speaker {next_n}"
            next_n += 1
        seg["speaker"] = rename[key]
    return labeled


def diarize_track(
    wav_path: str,
    segments: list[dict],
    name_start: int = 2,
) -> list[dict]:
    """Back-compat alias."""
    return diarize_by_speech_islands(wav_path, segments, name_start=name_start)


def has_usable_audio(path: str | None) -> bool:
    """True if any 1s window across the file has energy (meetings often start quiet)."""
    if not path:
        return False
    p = Path(path)
    if not p.is_file() or p.stat().st_size < 8192:
        return False
    try:
        import audioop

        with wave.open(path, "rb") as wf:
            frames = wf.getnframes()
            rate = wf.getframerate() or 1
            width = wf.getsampwidth()
            duration = frames / float(rate)
            if duration < MIN_TRACK_SECONDS:
                return False
            points = [
                0.0,
                duration * 0.25,
                duration * 0.5,
                duration * 0.75,
                max(0.0, duration - 1.5),
            ]
            for t in points:
                pos = min(int(t * rate), max(frames - 1, 0))
                wf.setpos(pos)
                raw = wf.readframes(rate)
                if raw and audioop.rms(raw, width) > 40:
                    return True
            return False
    except Exception:
        return False


def guess_speaker(
    start: float, end: float, mic_path: str | None, system_path: str | None
) -> str:
    """Fallback when dual-track ASR isn't available."""
    if not mic_path or not system_path:
        return "Me"
    mic = rms_window(mic_path, start, end)
    sys = rms_window(system_path, start, end)
    if sys > mic * 1.25 and sys > 200:
        return REMOTE_SPEAKER
    if mic > sys * 1.25 and mic > 200:
        return "Me"
    if sys > 250:
        return REMOTE_SPEAKER
    return "Me"


if __name__ == "__main__":
    main()

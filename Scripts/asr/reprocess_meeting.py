#!/usr/bin/env python3
"""Reprocess a meeting folder: fresh system diarize + Me from prior asr-raw.

Keeps mic/Me labels from backup (bleed already applied). Re-runs system Whisper
+ island diarize with current transcribe.py settings, then absorb/densify.
Writes asr-raw.json, transcript.json/.md/.srt, updates meeting.json speakers.
"""
from __future__ import annotations

import argparse
import json
import uuid
from pathlib import Path

import transcribe as T


def merge_gap(speaker: str) -> float:
    return T.merge_gap_for_speaker(speaker)


def merge_adjacent(segs: list[dict]) -> list[dict]:
    return T.merge_segments_by_speaker(segs)


def render_md(blocks: list[dict]) -> str:
    lines = []
    for b in blocks:
        lines.append(
            f"### {ts(b['start'])} – {ts(b['end'])} · {b['speaker']}\n\n{b['text']}\n"
        )
    return "\n".join(lines)


def render_srt(blocks: list[dict]) -> str:
    parts = []
    for i, b in enumerate(blocks, 1):
        parts.append(
            f"{i}\n{srt(b['start'])} --> {srt(b['end'])}\n{b['speaker']}: {b['text']}"
        )
    return "\n\n".join(parts) + ("\n" if parts else "")


def ts(t: float) -> str:
    total = int(round(t))
    h, m, s = total // 3600, (total % 3600) // 60, total % 60
    return f"{h:02d}:{m:02d}:{s:02d}"


def srt(t: float) -> str:
    total_ms = int(round(t * 1000))
    h = total_ms // 3_600_000
    m = (total_ms % 3_600_000) // 60_000
    s = (total_ms % 60_000) // 1000
    ms = total_ms % 1000
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def speaker_sort_key(sp: str):
    if sp == "Me":
        return (0, 0)
    m = __import__("re").fullmatch(r"Speaker (\d+)", sp)
    if m:
        return (1, int(m.group(1)))
    return (2, sp)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--meeting-dir", required=True)
    ap.add_argument("--me-from", help="asr-raw.json to take Me segments from (default: meeting asr-raw or backup)")
    ap.add_argument("--model", default="small.en")
    ap.add_argument("--language", default="en")
    ap.add_argument(
        "--diarize-only",
        action="store_true",
        help="Reuse remote text/times from asr-raw; only re-run island diarize + absorb/densify (no Whisper)",
    )
    ap.add_argument(
        "--postprocess-only",
        action="store_true",
        help="Keep existing labels; only absorb crumbs + densify (no Whisper/diarize)",
    )
    ap.add_argument(
        "--reuse-words",
        action="store_true",
        help="Reuse cached system word times so diarization can be retuned without re-running Whisper",
    )
    args = ap.parse_args()

    meet = Path(args.meeting_dir).expanduser().resolve()
    T.load_vocative_names(meet)
    system = meet / "system.wav"
    if not args.postprocess_only and not system.is_file():
        raise SystemExit(f"missing {system}")

    me_src = Path(args.me_from).expanduser() if args.me_from else meet / "asr-raw.json"
    if not me_src.is_file():
        backups = sorted(meet.glob("backup-before-reprocess-*/asr-raw.json"))
        if not backups:
            raise SystemExit("no Me source asr-raw.json")
        me_src = backups[-1]
    prior = json.loads(me_src.read_text(encoding="utf-8"))
    lang = prior.get("language")

    if args.postprocess_only:
        segments = [dict(s) for s in prior.get("segments", [])]
        print(f"Postprocess-only from {me_src}: {len(segments)} segments", flush=True)
        print(
            "before:",
            sorted({s["speaker"] for s in segments}, key=speaker_sort_key),
            flush=True,
        )
    else:
        me_segs = [dict(s) for s in prior.get("segments", []) if s.get("speaker") == "Me"]
        print(f"Me segments from {me_src}: {len(me_segs)}", flush=True)

        sys_words: list[tuple[float, float, str]] = []
        if args.diarize_only:
            sys_segs = [
                {
                    "start": float(s["start"]),
                    "end": float(s["end"]),
                    "text": s.get("text") or "",
                    "speaker": T.REMOTE_SPEAKER,
                }
                for s in prior.get("segments", [])
                if s.get("speaker") != "Me" and (s.get("text") or "").strip()
            ]
            print(f"Reusing {len(sys_segs)} remote segments (diarize-only)", flush=True)
        else:
            cache = meet / "asr-system-words.json"
            if args.reuse_words and cache.is_file():
                cached = json.loads(cache.read_text(encoding="utf-8"))
                sys_words = [(w[0], w[1], w[2]) for w in cached["words"]]
                sys_segs = cached["segments"]
                lang = cached.get("language") or lang
                print(f"Reusing {len(sys_words)} cached system words", flush=True)
            else:
                model = T.load_whisper_model(args.model)
                language = T.resolve_language(args.language)
                print("Transcribing system.wav…", flush=True)
                sys_words, sys_segs, lang = T.transcribe_system_track(
                    model, str(system), language, speaker=T.REMOTE_SPEAKER
                )
                cache.write_text(
                    json.dumps(
                        {
                            "language": lang,
                            "words": [list(w) for w in sys_words],
                            "segments": sys_segs,
                        }
                    ),
                    encoding="utf-8",
                )
            print(
                f"system whisper segments: {len(sys_segs)} words: {len(sys_words)}",
                flush=True,
            )

        by_voice = None
        if sys_words:
            print("Diarizing system by voice windows…", flush=True)
            by_voice = T.diarize_system_by_voice(str(system), sys_words, name_start=2)
        if by_voice is not None:
            sys_segs = by_voice
        else:
            print("Voice windows unavailable — energy islands…", flush=True)
            sys_segs = T.diarize_by_speech_islands(str(system), sys_segs, name_start=2)
        print(
            "system speakers:",
            sorted({s["speaker"] for s in sys_segs}, key=speaker_sort_key),
            flush=True,
        )

        mic = meet / "microphone.wav"
        if mic.is_file() and system.is_file():
            kept = T.drop_echoed_me_segments(me_segs, str(mic), str(system))
            print(
                f"echo filter: dropped {len(me_segs) - len(kept)} of {len(me_segs)} Me segments",
                flush=True,
            )
            me_segs = kept

        segments = me_segs + sys_segs
        segments.sort(key=lambda s: (float(s["start"]), float(s["end"])))
        segments = T.merge_segments_by_speaker(segments)
        segments = T.split_remotes_around_me_interruptions(segments)
        segments = T.drop_tiny_me_segments(segments)
        segments = T.merge_segments_by_speaker(segments)

    segments = T.absorb_tiny_remote_speakers(segments)
    segments = T.densify_remote_speakers(segments, name_start=2)
    segments = T.merge_segments_by_speaker(segments)

    speakers = sorted({s["speaker"] for s in segments}, key=speaker_sort_key)
    print("final speakers:", speakers, flush=True)
    from collections import Counter

    words: Counter[str] = Counter()
    for s in segments:
        words[s["speaker"]] += len((s.get("text") or "").split())
    for sp in speakers:
        print(f"  {sp}: {words[sp]} words", flush=True)

    info_language = lang or prior.get("language") or "en"
    raw = {"language": info_language, "segments": segments}
    (meet / "asr-raw.json").write_text(json.dumps(raw, indent=2), encoding="utf-8")

    # Match app merge gaps for export blocks.
    blocks = merge_adjacent(segments)
    transcript = {
        "language": info_language,
        "speakers": sorted({b["speaker"] for b in blocks}, key=speaker_sort_key),
        "blocks": [
            {
                "id": str(uuid.uuid4()).upper(),
                "start": float(b["start"]),
                "end": float(b["end"]),
                "speaker": b["speaker"],
                "text": b["text"],
            }
            for b in blocks
        ],
    }
    (meet / "transcript.json").write_text(
        json.dumps(transcript, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    (meet / "transcript.md").write_text(render_md(transcript["blocks"]), encoding="utf-8")
    (meet / "transcript.srt").write_text(render_srt(transcript["blocks"]), encoding="utf-8")

    meeting_path = meet / "meeting.json"
    meeting = json.loads(meeting_path.read_text(encoding="utf-8"))
    meeting["speakers"] = transcript["speakers"]
    meeting["status"] = "ready"
    meeting_path.write_text(json.dumps(meeting, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote outputs in {meet}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

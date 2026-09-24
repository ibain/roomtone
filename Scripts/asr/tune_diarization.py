#!/usr/bin/env python3
"""Measure diarization quality on a recorded meeting so tuning is data-driven.

Reads a meeting folder, runs the current diarization pipeline, and reports where
it is likely wrong. Voice embeddings are cached, so repeated runs and threshold
sweeps are fast.

    python tune_diarization.py --meeting-dir "~/Documents/Roomtone/<meeting>"
    python tune_diarization.py --meeting-dir DIR --sweep
    python tune_diarization.py --meeting-dir DIR --truth truth.json

`truth.json` is a hand-labeled reference for the system track, which turns the
report from "looks plausible" into a number that can be compared across builds:

    [{"start": 10.1, "end": 66.3, "speaker": "Alex"}, ...]
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

import transcribe as T

FRAME_SEC = 0.1


def clock(t: float) -> str:
    return f"{int(t) // 60}:{int(t) % 60:02d}"


def load_words(meet: Path) -> list[tuple[float, float, str]]:
    """Word timings from the reprocess cache, or transcribe and cache them."""
    cache = meet / "asr-system-words.json"
    if cache.is_file():
        data = json.loads(cache.read_text(encoding="utf-8"))
        return [(w[0], w[1], w[2]) for w in data["words"]]

    system = meet / "system.wav"
    if not system.is_file():
        raise SystemExit(f"no system.wav in {meet}")
    print("transcribing system track (no cache yet)…", flush=True)
    model = T.load_whisper_model("small.en")
    words, segments, language = T.transcribe_system_track(
        model, str(system), "en", "Speaker 2"
    )
    cache.write_text(
        json.dumps(
            {
                "language": language,
                "words": [list(w) for w in words],
                "segments": segments,
            }
        ),
        encoding="utf-8",
    )
    return words


class Voices:
    """Embedded voice windows for one meeting, cached across runs."""

    def __init__(self, meet: Path, words: list[tuple[float, float, str]]) -> None:
        self.meet = meet
        self.words = words
        self.wav = T.load_mono_16k(str(meet / "system.wav"))
        self.mel = T.voice_mel(self.wav)
        cache = meet / "asr-voice-embeds.npz"
        if cache.is_file():
            blob = np.load(cache)
            if len(blob["starts"]):
                self.windows = [
                    (float(a), float(b))
                    for a, b in zip(blob["starts"], blob["ends"])
                ]
                self.embeds = blob["embeds"]
                return
        self.windows = T.voiced_windows(self.wav)
        raw = T.embed_windows(self.mel, self.wav, [w[0] for w in self.windows])
        if raw is None or not len(raw):
            raise SystemExit("embedding stack unavailable")
        self.embeds = T.smooth_embeddings(raw, self.windows)
        try:
            np.savez(
                cache,
                starts=np.array([w[0] for w in self.windows]),
                ends=np.array([w[1] for w in self.windows]),
                embeds=self.embeds,
            )
        except OSError as err:
            print(f"(embedding cache not written: {err})", flush=True)

    def label(self, cluster_distance: float, merge_distance: float) -> list[int]:
        """Run clustering only, so sweeps skip the expensive embedding step."""
        before_c = T.SPEAKER_CLUSTER_DISTANCE
        before_m = T.CENTROID_MERGE_DISTANCE
        T.SPEAKER_CLUSTER_DISTANCE = cluster_distance
        T.CENTROID_MERGE_DISTANCE = merge_distance
        try:
            labels = T.cluster_embeddings(self.embeds)
            labels = T.merge_clusters_by_centroid(labels, self.embeds)
            return T.smooth_window_labels(labels)
        finally:
            T.SPEAKER_CLUSTER_DISTANCE = before_c
            T.CENTROID_MERGE_DISTANCE = before_m

    def segments(self, labels: list[int]) -> list[dict]:
        """Words through the full word-level pipeline, as shipped."""
        centroids = T.label_centroids(self.embeds, labels)
        word_labels = T.label_word_speakers(self.words, self.windows, labels)
        word_labels = T.reattribute_small_clusters(
            self.mel, self.wav, self.words, word_labels, centroids
        )
        covered = T.words_covered_by_windows(self.words, self.windows)
        word_labels = T.refine_handoff_boundaries(
            self.mel, self.wav, self.words, word_labels, self.embeds, labels, covered
        )
        word_labels = T.attribute_words_by_island(
            self.mel,
            self.wav,
            self.words,
            word_labels,
            [not flag for flag in covered],
            centroids,
            require_margin=True,
        )
        word_labels = T.split_merged_at_vocative(
            self.words, word_labels, self.windows, self.embeds
        )
        word_labels = T.keep_vocative_with_caller(
            self.words, word_labels, T.voiced_frames(self.wav)
        )
        word_labels = T.snap_abutted_changes_to_pauses(self.words, word_labels)
        segments = T.regroup_words_by_speaker(self.words, word_labels)
        return T.absorb_small_voices(segments, self.embeds, labels)


def report_turns(voices: Voices, segments: list[dict], limit: float) -> None:
    merged = T.merge_segments_by_speaker(
        [dict(seg, speaker=f"S{seg['_label']}") for seg in segments]
    )
    totals: dict[str, float] = {}
    for seg in merged:
        totals[seg["speaker"]] = totals.get(seg["speaker"], 0.0) + (
            seg["end"] - seg["start"]
        )
    print(f"\n{len(totals)} remote voices over {merged[-1]['end'] / 60:.1f} min")
    for name, total in sorted(totals.items(), key=lambda kv: -kv[1]):
        print(f"  {name:6} {total / 60:6.1f} min")

    print(f"\nturns (first {clock(limit)}):")
    for seg in merged:
        if seg["start"] > limit:
            print("  …")
            break
        span = f"{clock(seg['start'])}-{clock(seg['end'])}"
        print(f"  [{span:>11}] {seg['speaker']:5} {seg['text'][:64]}")


def report_confidence(
    voices: Voices, labels: list[int], segments: list[dict], worst: int
) -> None:
    """Rank turns by how clearly their voice beats the runner-up.

    A thin margin is where to listen first: it means the embedding barely
    preferred the speaker it picked.
    """
    kept = {seg["_label"] for seg in segments}
    centroids = {
        label: vector
        for label, vector in T.label_centroids(voices.embeds, labels).items()
        if label in kept
    }
    if len(centroids) < 2:
        return
    is_voiced = T.voiced_frames(voices.wav)

    scored = []
    for seg in segments:
        island = T.longest_island_within(is_voiced, seg["start"], seg["end"])
        if island is None or island[1] - island[0] < T.ORPHAN_MIN_ISLAND_SEC:
            continue
        span = min(island[1] - island[0], T.BOUNDARY_ISLAND_MAX_SEC)
        probe = T.embed_windows(voices.mel, voices.wav, [island[0]], length_sec=span)
        if probe is None or not len(probe):
            continue
        vector = probe[0] / (np.linalg.norm(probe[0]) + 1e-9)
        ranked = sorted(
            (1.0 - float(np.dot(vector, centroids[l])), l) for l in centroids
        )
        scored.append((ranked[1][0] - ranked[0][0], seg, ranked))

    scored.sort(key=lambda row: row[0])
    print(f"\nleast confident turns (listen here first):")
    for margin, seg, ranked in scored[:worst]:
        picked = "S%d" % seg["_label"]
        best = "S%d" % ranked[0][1]
        flag = " MISMATCH" if best != picked else ""
        print(
            f"  {clock(seg['start']):>6} margin {margin:.3f}  kept {picked}"
            f" nearest {best}:{ranked[0][0]:.2f}{flag}  {seg['text'][:44]}"
        )


def report_sweep(voices: Voices) -> None:
    """Show how the voice count reacts to the clustering thresholds.

    A shipped setting should sit in a plateau, not on a cliff, or the next
    meeting will split or merge a speaker.
    """
    merges = [0.19, 0.21, 0.23, 0.25, 0.27]
    print("\nvoice count by threshold (cluster x merge):")
    print("        " + "".join(f"{m:>7.2f}" for m in merges))
    for cluster in [0.26, 0.29, 0.32, 0.35, 0.38]:
        row = []
        for merge in merges:
            labels = voices.label(cluster, merge)
            row.append(len({seg["_label"] for seg in voices.segments(labels)}))
        marker = " *" if abs(cluster - T.SPEAKER_CLUSTER_DISTANCE) < 1e-9 else "  "
        print(f"{marker}{cluster:>6.2f}" + "".join(f"{n:>7d}" for n in row))
    print(f"  * shipped cluster={T.SPEAKER_CLUSTER_DISTANCE}"
          f" merge={T.CENTROID_MERGE_DISTANCE}")


def report_truth(segments: list[dict], truth_path: Path) -> None:
    """Frame-accuracy against hand labels, after mapping clusters to names."""
    truth = json.loads(truth_path.read_text(encoding="utf-8"))
    if not truth:
        return
    end = max(row["end"] for row in truth)
    frames = int(end / FRAME_SEC) + 1

    want = [None] * frames
    for row in truth:
        for f in range(int(row["start"] / FRAME_SEC), min(int(row["end"] / FRAME_SEC), frames)):
            want[f] = row["speaker"]
    got: list[int | None] = [None] * frames
    for seg in segments:
        for f in range(int(seg["start"] / FRAME_SEC), min(int(seg["end"] / FRAME_SEC), frames)):
            got[f] = seg["_label"]

    pairs = [(w, g) for w, g in zip(want, got) if w is not None and g is not None]
    if not pairs:
        print("\ntruth: no overlap with predictions")
        return

    counts: dict[int, dict[str, int]] = {}
    for name, label in pairs:
        counts.setdefault(label, {})
        counts[label][name] = counts[label].get(name, 0) + 1
    mapping = {
        label: max(hits.items(), key=lambda kv: kv[1])[0]
        for label, hits in counts.items()
    }
    correct = sum(1 for name, label in pairs if mapping[label] == name)
    print(f"\ntruth: {correct / len(pairs) * 100:.1f}% of labeled speech correct"
          f" ({len(pairs) * FRAME_SEC / 60:.1f} min compared)")

    per: dict[str, list[int]] = {}
    for name, label in pairs:
        hit, total = per.setdefault(name, [0, 0])
        per[name] = [hit + (1 if mapping[label] == name else 0), total + 1]
    for name, (hit, total) in sorted(per.items(), key=lambda kv: -kv[1][1]):
        print(f"  {name:10} {hit / total * 100:5.1f}%  ({total * FRAME_SEC / 60:.1f} min)")
    collisions = [n for n in set(mapping.values()) if list(mapping.values()).count(n) > 1]
    for name in collisions:
        print(f"  note: {name} was split across multiple clusters")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--meeting-dir", required=True)
    ap.add_argument("--sweep", action="store_true", help="threshold stability grid")
    ap.add_argument("--truth", help="hand-labeled reference JSON")
    ap.add_argument("--timeline-sec", type=float, default=600.0)
    ap.add_argument("--worst", type=int, default=12)
    ap.add_argument("--cluster", type=float, default=T.SPEAKER_CLUSTER_DISTANCE)
    ap.add_argument("--merge", type=float, default=T.CENTROID_MERGE_DISTANCE)
    ap.add_argument("--min-speech", type=float, default=T.MIN_SPEAKER_SPEECH_SEC)
    args = ap.parse_args()
    T.MIN_SPEAKER_SPEECH_SEC = args.min_speech

    meet = Path(args.meeting_dir).expanduser()
    if not meet.is_dir():
        raise SystemExit(f"not a directory: {meet}")
    T.load_vocative_names(meet)

    words = load_words(meet)
    voices = Voices(meet, words)
    print(f"{len(words)} words, {len(voices.windows)} voice windows")

    if (args.cluster, args.merge) != (
        T.SPEAKER_CLUSTER_DISTANCE,
        T.CENTROID_MERGE_DISTANCE,
    ):
        print(f"overriding: cluster={args.cluster} merge={args.merge}")
    labels = voices.label(args.cluster, args.merge)
    segments = voices.segments(labels)
    report_turns(voices, segments, args.timeline_sec)
    report_confidence(voices, labels, segments, args.worst)
    if args.truth:
        report_truth(segments, Path(args.truth).expanduser())
    if args.sweep:
        report_sweep(voices)


if __name__ == "__main__":
    main()

"""Ordered narration assembly. Originals remain the editable FCPXML storyline.

Virtual source time concatenates the original clips before their per-clip edits. This
lets the existing TimelineMap remap captions/cues without inventing a flattened master.
"""
from __future__ import annotations

import json
import math
from pathlib import Path

import config as C
import fcpxml as FX

EDL = Path("assembly/selected.edl.json")
TRANSCRIPT = Path("assembly/selected.words.json")


def compile_sources(records: list[tuple[Path, dict, dict, float]]) -> tuple[dict, dict, list[dict]]:
    if len(records) < 2:
        raise ValueError("An assembly requires at least two explicitly ordered sources")
    keeps, segments, drops, words, picks = [], [], [], [], []
    block = 0.0
    seen = set()
    for source, transcript, edl, duration in records:
        source = source.resolve()
        if source in seen or not math.isfinite(duration) or duration <= 0:
            raise ValueError("Duplicate source or invalid source duration")
        seen.add(source)
        bound = C.snap_seconds(duration)
        if bound <= 0:
            raise ValueError("Source is shorter than one frame")
        if (C.ROOT / edl["source"]).resolve() != source or (C.ROOT / transcript["source"]).resolve() != source:
            raise ValueError("The transcript and edit list must belong to the selected source")
        prior = 0.0
        if not edl["keeps"] or not transcript["words"]:
            raise ValueError("A selected source has no verified retained speech")
        for span in edl["keeps"]:
            start, end = float(span["start"]), float(span["end"])
            if not all(math.isfinite(v) for v in (start, end)) or start < prior or end <= start or end > duration + 1 / C.FPS:
                raise ValueError("Invalid, overlapping or out-of-range retained span")
            prior = end
            start, end = C.snap_seconds(start), min(C.snap_seconds(end), bound)
            if end <= start:
                raise ValueError("Retained span is shorter than one frame")
            keeps.append({"start": block + start, "end": block + end})
            segments.append({"source": str(source), "start": start, "end": end})
            picks.append({"path": source, "start": start, "end": end, "note": "Explicit narration order"})
        for word in transcript["words"]:
            start, end = float(word["start"]), float(word["end"])
            if not all(math.isfinite(v) for v in (start, end)) or not 0 <= start <= end <= duration + 1 / C.FPS:
                raise ValueError("Invalid source word timing")
            if start >= bound:
                raise ValueError("Source word begins beyond available media")
            end = min(end, bound)
            words.append({**word, "start": block + start, "end": block + end})
        for span in edl.get("drops", []):
            drops.append({**span, "start": block + span["start"], "end": block + span["end"], "source": str(source),
                          "source_start": span["start"], "source_end": span["end"]})
        block += bound
    return ({"clip": "Ordered narration", "source": "Ordered narration", "fps": C.FPS,
             "keeps": keeps, "segments": segments, "drops": drops,
             "source_duration": block, "cut_duration": sum(p["end"] - p["start"] for p in picks)},
            {"clip": "Ordered narration", "source": "Ordered narration", "fps": C.FPS,
             "duration": block, "word_count": len(words), "words": words}, picks)


def assemble(spec_path: Path, project: str, preview: bool) -> None:
    from tools import assemble as A
    spec = json.loads(spec_path.read_text())
    if spec.get("schema_version") != 2 or not isinstance(spec.get("sources"), list):
        raise ValueError("Unreadable narration order")
    records = []
    for value in spec["sources"]:
        source = Path(value["source"])
        key = value["key"]
        if not key or key != Path(key).name or key in (".", ".."):
            raise ValueError("Invalid transcription output key")
        if not source.is_absolute() or not source.is_file():
            raise ValueError("A selected source is unavailable")
        transcript = json.loads((C.TRANSCRIPTS / f"{key}.words.json").read_text())
        edl = json.loads((C.ROUGHCUT / f"{key}.edl.json").read_text())
        # Stage 2 has already checked each clip. The assembled audio needs its own check.
        if not (C.ROUGHCUT / f"{key}.heard.txt").is_file():
            raise ValueError("A selected source has no read-back")
        records.append((source, transcript, edl, FX.probe(source)["duration"]))
    edl, transcript, picks = compile_sources(records)
    work = C.ROUGHCUT / "assembly"
    work.mkdir(parents=True, exist_ok=True)
    lines, problems = A.listen_back(picks, work)
    if not lines or not any(line.get("text", "").strip() for line in lines):
        raise ValueError("The assembled audio contains no verified speech")
    (work / "selected.heard.txt").write_text("\n".join(x["text"] for x in lines) + "\n")
    if problems:
        raise ValueError("The assembled audio needs review: " + "; ".join(problems))
    _, problems = A.to_fcpxml(project, picks, work / "selected.roughcut.fcpxml")
    if problems:
        raise ValueError("The assembled timeline failed validation: " + "; ".join(problems))
    if preview:
        A.render_preview(picks, work / "selected.preview.mp4")
    (C.ROUGHCUT / EDL).write_text(json.dumps(edl, indent=2))
    target = C.TRANSCRIPTS / TRANSCRIPT
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(transcript, indent=2))
    print(f"Verified ordered narration: {len(records)} sources, {len(picks)} retained spans")

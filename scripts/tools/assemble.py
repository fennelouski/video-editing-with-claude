"""
assemble.py — one rough cut out of several clips.

Stage 2 cuts *within* a clip: it knows she said the line six times on this card and keeps the
last complete one. It has no way to know she said it again on the next card, because each
transcript is processed on its own. Choosing between takes across clips is the editorial pass,
and it happens here, driven by a selection file a human can read and argue with:

    {"project": "intro001",
     "picks": [{"source": "Intro 001/MVI_0019.MOV", "start": 12.34, "end": 19.01,
                "note": "hook — 'this is yeast bubbling'"}]}

Output is the same shape as stage 2's: an FCPXML Final Cut can import, and a read-back of what
the assembled audio actually says. The read-back is the point. A selection file is a claim about
the footage built from transcripts of the *sources*, so it inherits every error those transcripts
have; the only description of the cut that cannot is one taken from the cut. [S-026]

    ./run tools/assemble.py build/roughcut/intro001.picks.json --preview
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import math
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import cli
import config as C
import fcpxml as FX
import stage2_roughcut as S2

MIN_MUSIC_TAIL = 1.0     # a repeat shorter than this is arithmetic, not music
MIN_PUNCH_NEIGHBOUR = 10.0  # a static punch-in needs this much settled picture on both sides


def load_picks(path: Path) -> tuple[str, list[dict], dict]:
    spec = json.loads(path.read_text())
    picks = spec["picks"]
    for i, p in enumerate(picks):
        src = cli.resolve_or_exit(p["source"], expect=(".mov", ".mp4", ".m4v", ".wav"),
                                  label=f"pick {i + 1} source")
        p["path"] = src
        p["start"] = C.snap_seconds(float(p["start"]))
        p["end"] = C.snap_seconds(float(p["end"]))
        if p["end"] <= p["start"]:
            sys.exit(f"! pick {i + 1} ends before it starts: {p['start']} → {p['end']}")

        # A `video` block is a split edit: sound stays on this pick, picture comes from
        # somewhere else. Its length is derived from the pick rather than stated twice, because
        # two numbers that must agree are two numbers that will eventually disagree.
        if v := p.get("video"):
            v["path"] = cli.resolve_or_exit(
                v["source"], expect=(".mov", ".mp4", ".m4v", ".avi"),
                label=f"pick {i + 1} picture")
            v["start"] = C.snap_seconds(float(v.get("start", 0.0)))
            # An insert may cover only the head of the pick — `duration` says how much; the
            # picture comes back to her for the rest. Default is the whole pick.
            span = p["end"] - p["start"]
            v["duration"] = C.snap_seconds(min(float(v.get("duration", span)), span))
            v["end"] = C.snap_seconds(v["start"] + v["duration"])
            have = FX.probe(v["path"])["duration"]
            if v["end"] > have + 0.01:
                sys.exit(f"! pick {i + 1} picture runs to {v['end']:.2f}s but "
                         f"{v['path'].name} is only {have:.2f}s long")
    return spec.get("project", path.stem), picks, spec


def load_music(spec: dict, total: float) -> list[dict]:
    """
    Resolve the music cues, and work out where each one runs to.

    `at` is a timeline position. `until` defaults to wherever the next cue starts, and the last
    cue runs to the end of the cut — so moving one cue moves the boundary with it rather than
    leaving a hole for someone to find later.
    """
    cues = []
    for i, cue in enumerate(spec.get("music", [])):
        src = cli.resolve_or_exit(cue["source"], expect=(".wav", ".aif", ".aiff", ".m4a", ".mp3"),
                                  label=f"music cue {i + 1}")
        cues.append({**cue, "path": src, "at": C.snap_seconds(float(cue.get("at", 0.0))),
                     "length": FX.probe(src)["duration"]})
    for cue, nxt in zip(cues, cues[1:] + [None]):
        end = cue.get("until", nxt["at"] if nxt else total)
        cue["until"] = C.snap_seconds(min(float(end), total))
    return cues


def audio_graph(picks: list[dict], sources: list[Path]) -> str:
    """Concat filter across however many distinct sources the picks draw on."""
    idx = {str(p): i for i, p in enumerate(sources)}
    # Gain is applied here too, not only in the preview: this is what the read-back listens to
    # and what the music bed is measured against, and a bed set from a voice 20 dB below the
    # one that ships is set from a voice nobody hears.
    parts = [f"[{idx[str(p['path'])]}:a]atrim=start={p['start']}:end={p['end']},"
             f"asetpts=PTS-STARTPTS"
             + (f",volume={p['gain_db']:.2f}dB" if p.get("gain_db") else "")
             + f"[c{i}]" for i, p in enumerate(picks)]
    return (";".join(parts) + ";" + "".join(f"[c{i}]" for i in range(len(picks)))
            + f"concat=n={len(picks)}:v=0:a=1[cut]")


def render_audio(picks: list[dict], out: Path) -> Path:
    """The assembled audio and nothing else — what a viewer's ears actually receive."""
    out.parent.mkdir(parents=True, exist_ok=True)
    sources = list(dict.fromkeys(p["path"] for p in picks))
    inputs: list[str] = []
    for s in sources:
        inputs += ["-i", str(s)]
    subprocess.run(["ffmpeg", "-y", "-v", "error", *inputs,
                    "-filter_complex", audio_graph(picks, sources),
                    "-map", "[cut]", "-ar", "16000", "-ac", "1", str(out)], check=True)
    return out


def listen_back(picks: list[dict], workdir: Path) -> tuple[list[dict], list[str]]:
    """Transcribe the assembly and read *that*, not the transcripts it was chosen from."""
    import stage1_transcribe as S1

    wav = render_audio(picks, workdir / "_assemble.verify.wav")
    try:
        heard = [dataclasses.asdict(w) for w in S1.flatten_words(S1.transcribe(wav))]
    finally:
        wav.unlink(missing_ok=True)
    lines = S2.group_sentences(heard)
    return lines, S2.read_through(lines)


def music_clips(cues: list[dict]) -> list["FX.Connected"]:
    """
    The bed as real clips on the Music role, below the storyline, at the measured level.

    A cue longer than its track repeats it: FCPXML has no loop, so a 2:54 bed under twelve
    minutes is five clips, the last one short. That is also the honest representation — the
    repeat is visible in the timeline instead of hidden inside a render, which is the point at
    which someone notices the track has come round for the fourth time.
    """
    out: list[FX.Connected] = []
    for cue in cues:
        at, gain, n = cue["at"], cue.get("gain_db"), 0
        while True:
            span = min(cue["length"], cue["until"] - at)
            # The timeline is the sum of 60 frame-snapped picks, so it overshoots the last whole
            # repeat by a few tens of milliseconds — and filling that with another clip produced
            # a one-frame sliver of the outro after the outro. A repeat too short to be a musical
            # event is an artifact of the arithmetic; it is dropped, and said out loud below.
            if n and span < MIN_MUSIC_TAIL:
                cue["dropped_tail"] = span
                break
            out.append(FX.Connected(
                asset_path=cue["path"], offset=C.snap_seconds(at),
                duration=C.snap_seconds(span), start=0.0,
                name=f"{cue['path'].stem} ({cue.get('role', 'music')})",
                lane=C.LANE_MUSIC, role=C.ROLE_MUSIC, audio=True, gain_db=gain,
            ))
            at += span
            n += 1
            if at >= cue["until"] - 1e-6:
                break
    return out


def to_fcpxml(project: str, picks: list[dict], out: Path,
              music: list["FX.Connected"] | None = None) -> tuple[Path, list[str]]:
    clips, timeline = [], 0.0
    inserts: list[FX.Connected] = []
    chapters: list[tuple[float, str]] = []
    for i, p in enumerate(picks):
        span = p["end"] - p["start"]
        clip = FX.Clip(
            asset_path=p["path"],
            offset=C.snap_seconds(timeline),
            start=p["start"],
            duration=C.snap_seconds(span),
            name=f"{p['path'].stem} {i + 1:02d}",
            role=C.ROLE_VIDEO,
            gain_db=p.get("gain_db"),
            scale=p.get("scale"),
            push_to=p.get("push_to"),
        )
        if v := p.get("video"):
            # Picture only, on a positive lane so it covers the storyline it is attached to.
            inserts.append(FX.Connected(
                asset_path=v["path"], offset=clip.offset, start=v["start"],
                duration=v["duration"], name=v.get("note") or v["path"].stem,
                lane=C.LANE_BROLL, role=C.ROLE_VIDEO, video_only=True,
            ))
        # Every join is a shot change between two different source moments, and often two
        # different cards. The note says which take this is and why it was chosen, so the join
        # can be argued with in the timeline rather than reverse-engineered from timecode.
        if p.get("note"):
            clip.markers.append((clip.offset, f"take · {p['note']}", True))
        # A chapter starts where its first pick starts; a cue is a to-do marker at an offset
        # into the pick, so "GFX: flask" lands on the word it answers rather than on the join.
        if p.get("chapter"):
            chapters.append((clip.offset, p["chapter"]))
        for cue in p.get("cues", []):
            at = C.snap_seconds(clip.offset + float(cue.get("at", 0.0)))
            clip.markers.append((min(at, clip.offset + clip.duration - 1 / C.FPS),
                                 cue["text"], True))
            # A cue that already has a rendered layer is placed as well as marked: on the
            # graphics lane, for exactly as long as the render runs, so the hold it was
            # rendered with is the hold it gets.
            if cue.get("layer"):
                layer = cli.resolve_or_exit(cue["layer"], expect=(".mov",), label="layer")
                inserts.append(FX.Connected(
                    asset_path=layer, offset=at, start=0.0,
                    duration=C.snap_seconds(FX.probe(layer)["duration"]),
                    name=layer.stem, lane=C.LANE_GRAPHICS, role=C.ROLE_GRAPHICS_SUB,
                    video_only=True))
        clips.append(clip)
        timeline += span

    # A reframed picture spans whatever clips it overlaps — the picks were split at pauses,
    # so a 10 s picture usually sits across three or four of them.
    for t0, t1 in reframes(picks):
        for clip in clips:
            c0, c1 = clip.offset, clip.offset + clip.duration
            if t0 < c1 and t1 > c0:
                clip.reframe.append((clip.start + max(t0, c0) - c0,
                                     clip.start + min(t1, c1) - c0))

    builder = FX.FCPXMLBuilder(project=f"{project} — rough cut", aspect=C.DEFAULT_ASPECT)
    builder.write(builder.build(clips, connected=inserts + (music or []), chapters=chapters),
                  out)
    return out, FX.validate(out)


def reframes(picks: list[dict]) -> list[tuple[float, float]]:
    """Timeline intervals during which a cue asked the footage to make room for a picture."""
    out, timeline = [], 0.0
    for p in picks:
        for cue in p.get("cues", []):
            if cue.get("reframe"):
                at = C.snap_seconds(timeline + float(cue.get("at", 0.0)))
                out.append((at, C.snap_seconds(at + float(cue.get("seconds", 6.0)))))
        timeline += p["end"] - p["start"]
    return out


def measure_beds(picks: list[dict], cues: list[dict], workdir: Path) -> None:
    """
    Set each cue's level from the cut voice, in the band the voice is actually carried in.

    Measured against the *cut*, not the tapes: the cut is 43% of the source and drops the loudest
    run-ups, so a gain taken from the original sits in the wrong place. And measured in
    `MUSIC_BAND` — a stated dB figure without the band it was measured in is not a specification,
    which is the whole of [S-022]. Anything laying a bed imports the level, the band and
    `bed_gain()` together, from `music.py`.
    """
    from music import MUSIC_BAND, MUSIC_UNDER_DB, bed_gain

    voice = render_audio(picks, workdir / "_assemble.voice.wav")
    try:
        for cue in cues:
            under = float(cue.get("under_db", MUSIC_UNDER_DB))
            gain = bed_gain(voice, cue["path"], under)
            cue["gain"] = gain
            cue["gain_db"] = 20 * math.log10(gain) if gain > 0 else -96.0
            print(f"    {cue['path'].name}: {cue['gain_db']:+.1f} dB "
                  f"({under:.0f} dB under the cut voice, measured "
                  f"{MUSIC_BAND[0]:.0f} Hz–{MUSIC_BAND[1] / 1000:.0f} kHz) "
                  f"· {cue['at']:.1f}s–{cue['until']:.1f}s")
    finally:
        voice.unlink(missing_ok=True)


def face_lift_mask(spec: dict, out: Path) -> Path:
    """
    A soft-light mask that lifts where she sits — mid-grey everywhere (no change), brighter in
    an ellipse over her head and shoulders. A grading mask, not imagery: nothing of it reaches
    the screen as pixels of its own. Final Cut's equivalent is a colour mask on the Color Board.
    """
    from PIL import Image, ImageDraw, ImageFilter
    (cx, cy), (rx, ry) = spec["centre"], spec["radius"]
    m = Image.new("L", (1920, 1080), 128)
    ImageDraw.Draw(m).ellipse((cx - rx, cy - ry, cx + rx, cy + ry), fill=188)
    m = m.filter(ImageFilter.GaussianBlur(140))
    out.parent.mkdir(parents=True, exist_ok=True)
    m.save(out)
    return out


def render_preview(picks: list[dict], out: Path, cues: list[dict] | None = None,
                   grade: dict | None = None) -> Path:
    """Flattened preview for judging pace. Never the deliverable — see to_fcpxml()."""
    from music import MUSIC_HIGHPASS_HZ

    sources = list(dict.fromkeys([p["path"] for p in picks]
                                 + [p["video"]["path"] for p in picks if p.get("video")]))
    idx = {str(s): i for i, s in enumerate(sources)}
    inputs: list[str] = []
    for s in sources:
        inputs += ["-i", str(s)]
    parts, streams = [], []
    for i, p in enumerate(picks):
        n = idx[str(p["path"])]
        # Picture and sound are addressed separately so a pick can take one from each place.
        v = p.get("video")
        gain = f",volume={p['gain_db']:.2f}dB" if p.get("gain_db") else ""
        # The same framing the FCPXML carries, so the preview shows what the timeline will.
        # A push is linear across the pick; a static punch-in is the same expression with
        # both ends equal.
        zoom = ""
        if p.get("scale") is not None or p.get("push_to") is not None:
            s0 = p.get("scale", 1.0) or 1.0
            s1 = p.get("push_to", s0) if p.get("push_to") is not None else s0
            span = p["end"] - p["start"]
            zoom = (f",scale=eval=frame:w='1920*({s0:.4f}+({s1 - s0:.4f})*t/{span:.4f})'"
                    f":h='1080*({s0:.4f}+({s1 - s0:.4f})*t/{span:.4f})',crop=1920:1080")
        conform = f"setpts=PTS-STARTPTS,scale=1920:1080{zoom},fps={C.FPS_STR}"
        if v and v["duration"] < p["end"] - p["start"] - 1e-6:
            # Insert over the head of the pick, then her picture for the remainder.
            parts.append(
                f"[{idx[str(v['path'])]}:v]trim=start={v['start']}:end={v['end']},{conform}[i{i}];"
                f"[{n}:v]trim=start={p['start'] + v['duration']}:end={p['end']},{conform}[r{i}];"
                f"[i{i}][r{i}]concat=n=2:v=1:a=0[v{i}]")
        else:
            vn, vstart, vend = ((idx[str(v["path"])], v["start"], v["end"]) if v
                                else (n, p["start"], p["end"]))
            parts.append(f"[{vn}:v]trim=start={vstart}:end={vend},{conform}[v{i}]")
        parts.append(
            f"[{n}:a]atrim=start={p['start']}:end={p['end']},asetpts=PTS-STARTPTS{gain}[a{i}]")
        streams.append(f"[v{i}][a{i}]")
    graph = ";".join(parts) + ";" + "".join(streams) + f"concat=n={len(picks)}:v=1:a=1[v][a]"

    vmap = "[v]"
    # The grade, before the graphics go on: the cards are already in the palette. The LUT is
    # the same file she applies in Final Cut; the face lift is preview-only and documented.
    if grade:
        if grade.get("lut"):
            lut = cli.resolve_or_exit(grade["lut"], expect=(".cube",), label="LUT")
            graph += f";{vmap}lut3d=file={lut}[vg]"
            vmap = "[vg]"
        if grade.get("face_lift"):
            mask = face_lift_mask(grade["face_lift"], out.parent / f"{out.stem}.face-lift.png")
            n = inputs.count("-i")
            inputs += ["-i", str(mask)]
            graph += (f";[{n}:v]format=rgb24[fm];{vmap}format=rgb24[vf];"
                      f"[vf][fm]blend=all_mode=softlight:all_opacity="
                      f"{float(grade['face_lift'].get('amount', 0.7)):.2f}[vl]")
            vmap = "[vl]"

    # The reframe, as a snap: during a picture the footage is scaled and moved onto a paper
    # ground, and the mat layer on top has a window exactly there. Same numbers as the FCPXML.
    spans = reframes(picks)
    if spans:
        inside = "+".join(f"between(t,{a:.4f},{b:.4f})" for a, b in spans)
        sc = C.REFRAME_SCALE
        x0 = int(round(960 + C.REFRAME_X - 1920 * sc / 2))
        y0 = int(round(540 - C.REFRAME_Y - 1080 * sc / 2))
        graph += (f";{vmap}scale=eval=frame:w='1920*if({inside},{sc},1)'"
                  f":h='1080*if({inside},{sc},1)'[vr];"
                  f"color=c=0x{C.PALETTE['bone'][1:]}:s=1920x1080:r={C.FPS_STR}[paper];"
                  f"[paper][vr]overlay=eval=frame:shortest=1"
                  f":x='if({inside},{x0},0)':y='if({inside},{y0},0)'[vo]")
        vmap = "[vo]"

    # Rendered graphic layers over the picture, where the FCPXML puts them.
    timeline = 0.0
    for p in picks:
        for cue in p.get("cues", []):
            if not cue.get("layer"):
                continue
            layer = cli.resolve_or_exit(cue["layer"], expect=(".mov",), label="layer")
            at = C.snap_seconds(timeline + float(cue.get("at", 0.0)))
            n = inputs.count("-i")
            # Shifted at the input, not with setpts in the graph: ffmpeg feeds whichever input
            # has the earliest timestamps, so a 10 s layer stamped 0–10 s is decoded whole —
            # 240 RGBA frames — before the cut reaches it. Thirteen of those got the render
            # killed (exit 137). With -itsoffset the layer's frames are late and stay unread.
            inputs += ["-itsoffset", f"{at:.4f}", "-i", str(layer)]
            nxt = f"[g{n}]"
            graph += (f";[{n}:v]format=rgba[l{n}];"
                      f"{vmap}[l{n}]overlay=eof_action=pass:format=auto{nxt}")
            vmap = nxt
        timeline += p["end"] - p["start"]

    amap = "[a]"
    for i, cue in enumerate(cues or []):
        span = cue["until"] - cue["at"]
        fade_in = min(float(cue.get("fade_in", 2.0)), span / 2)
        fade = min(float(cue.get("fade_out", 2.0)), span - fade_in)
        # Counted off the input list as it stands, not off `sources`: the graphic layers
        # above were appended in between.
        n = inputs.count("-i")
        inputs += ["-stream_loop", "-1", "-i", str(cue["path"])]
        # Trim first, then delay: the cue is placed on the timeline, so its fades belong to its
        # own span rather than to the start of the programme.
        graph += (
            f";[{n}:a]atrim=0:{span:.3f},asetpts=PTS-STARTPTS,"
            f"highpass=f={MUSIC_HIGHPASS_HZ},volume={cue['gain']:.5f},"
            f"afade=t=in:st=0:d={fade_in:.2f},"
            f"afade=t=out:st={max(0.0, span - fade):.3f}:d={fade:.2f},"
            f"adelay={int(cue['at'] * 1000)}:all=1[bed{i}]"
        )
    if cues:
        graph += (";" + amap + "".join(f"[bed{i}]" for i in range(len(cues)))
                  + f"amix=inputs={len(cues) + 1}:duration=first:normalize=0[mix]")
        amap = "[mix]"

    proc = subprocess.run(["ffmpeg", "-y", "-v", "error", *inputs, "-filter_complex", graph,
                           "-map", vmap, "-map", amap,
                           "-c:v", "libx264", "-crf", "20", "-preset", "medium",
                           "-pix_fmt", "yuv420p", "-r", C.FPS_STR,
                           "-c:a", "aac", "-b:a", "192k", str(out)],
                          capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"preview render failed:\n{proc.stderr[-1200:]}")
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Assemble one rough cut from picks across clips")
    ap.add_argument("picks", help="selection JSON")
    ap.add_argument("--preview", action="store_true", help="also render a flattened mp4")
    ap.add_argument("--no-verify", action="store_true",
                    help="skip the read-back. The read-back is the only check that does not "
                         "inherit the source transcripts' mistakes, so this leaves the cut "
                         "unverified — which is not the same as clean")
    args = ap.parse_args(argv)

    path = cli.resolve_or_exit(args.picks, expect=(".json",), label="picks file")
    project, picks, spec = load_picks(path)
    total = sum(p["end"] - p["start"] for p in picks)
    print(f"Assembling {project}: {len(picks)} picks from "
          f"{len({p['path'] for p in picks})} clip(s) → {total:.1f}s")

    cues = load_music(spec, total)
    if cues:
        print(f"  music: {len(cues)} cue(s)")
        measure_beds(picks, cues, C.ROUGHCUT)
        for cue in cues:
            plays = (cue["until"] - cue["at"]) / cue["length"]
            if plays > 1.05:
                print(f"    ! {cue['path'].name} is {cue['length']:.0f}s and has to come round "
                      f"{plays:.1f} times to cover {cue['until'] - cue['at']:.0f}s")

    # A static punch-in exists to hide a jump cut, and it only hides one if the eye has settled
    # on both sides of it. Between two short shots it is a third cut, not a second camera — so a
    # punch-in with a neighbour under 10 s is refused rather than written.
    # Consecutive picks from one source at one framing are one shot to the eye — a take
    # with its pauses tightened is still the take — so the rule measures runs, not picks.
    runs: list[list[int]] = []
    for i, p in enumerate(picks):
        same = (runs and picks[runs[-1][-1]]["path"] == p["path"]
                and picks[runs[-1][-1]].get("scale") == p.get("scale")
                and not p.get("video") and not picks[runs[-1][-1]].get("video"))
        runs[-1].append(i) if same else runs.append([i])
    length = lambda run: sum(picks[k]["end"] - picks[k]["start"] for k in run)
    for r, run in enumerate(runs):
        p = picks[run[0]]
        if p.get("scale") is None or p.get("push_to") is not None:
            continue
        for j in (r - 1, r + 1):
            if 0 <= j < len(runs) and length(runs[j]) < MIN_PUNCH_NEIGHBOUR:
                sys.exit(f"! pick {run[0] + 1} is punched in to {p['scale']:.2f}× but the shot "
                         f"beside it (pick {runs[j][0] + 1}) runs {length(runs[j]):.1f}s — "
                         f"needs {MIN_PUNCH_NEIGHBOUR:.0f}s either side, or drop the scale")

    # A frame rate that is not the project timebase is a conform Final Cut will do silently and
    # differently than we would. [S-007] — name it here rather than discover it in the timeline.
    for src in dict.fromkeys(p["path"] for p in picks):
        rate = FX.probe(src).get("fps")
        if rate and abs(rate - C.FPS) > 0.01:
            print(f"  ! {src.name} is {rate:.3f} fps, not the {C.FPS:.3f} timebase — "
                  f"Final Cut will conform it and the motion will not match its neighbours")

    beds = music_clips(cues)
    for cue in cues:
        if cue.get("dropped_tail"):
            print(f"    {cue['path'].name}: last {cue['dropped_tail'] * 1000:.0f} ms of the cue "
                  f"left unfilled — too short to be worth another repeat")
    fx, problems = to_fcpxml(project, picks, C.ROUGHCUT / f"{project}.roughcut.fcpxml",
                             music=beds)
    print(f"  ✓ {fx.relative_to(C.ROOT)}")
    for p in problems[:5]:
        print(f"    ! {p}")

    failed = False
    if not args.no_verify:
        print("  listening back…")
        lines, heard_problems = listen_back(picks, C.ROUGHCUT)
        heard = C.ROUGHCUT / f"{project}.heard.txt"
        heard.write_text("\n".join(x["text"] for x in lines) + "\n", encoding="utf-8")
        print(f"  what it actually says ({heard.relative_to(C.ROOT)}):")
        for line in lines:
            print(f"    {line['text']}")
        if heard_problems:
            print(f"\n  ! the cut does not survive its own read-back — "
                  f"{len(heard_problems)} problem(s):")
            for problem in heard_problems:
                print(f"    - {problem}")
            failed = True

    if args.preview:
        out = render_preview(picks, C.ROUGHCUT / f"{project}.preview.mp4", cues,
                             grade=spec.get("grade"))
        m = S2.measure(out)
        print(f"  ✓ {out.relative_to(C.ROOT)} (preview only) — "
              f"{m['lufs']:+.1f} LUFS, peak {m['peak']:+.1f} dBFS")
        print("    her voice is unprocessed here: the §8 dialogue chain belongs to the finish. "
              "The bed is placed against that raw voice, so it will need re-measuring once the "
              "chain is on — the balance is right, the absolute level is not.")

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())

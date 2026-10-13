"""
Final Cut handoff invariants (style_guide [S-006], [S-007]; taste_principles §6.7).

The connected-clip offset test is the important one. Point 2 of the fcpxml module docstring
calls it out as the reason graphics land in the wrong place: the offset written into the file
is in the *parent clip's* local time, so proving it round-trips back to the absolute timeline
position is the only way to know a graphic will appear where the plan said.
"""

from __future__ import annotations

from xml.etree import ElementTree as ET

import pytest

import config as C
import fcpxml as FX


TICKS = C.FCPXML_FRAME_TICKS
SCALE = C.FCPXML_TIMESCALE


def seconds_of(value: str) -> float:
    """Parse an FCPXML rational time back into seconds."""
    if value in ("0s", "", None):
        return 0.0
    num, den = value[:-1].split("/")
    return int(num) / int(den)


@pytest.fixture(scope="module")
def built(tmp_path_factory, video):
    """
    A three-clip timeline with graphics attached to each, plus markers and chapters.

    Three clips matters: with one clip, parent-local time and timeline time are identical
    and the offset bug this file exists to catch is invisible.
    """
    out_dir = tmp_path_factory.mktemp("fcpxml")

    clips = [
        FX.Clip(asset_path=video, offset=0.0, start=0.0, duration=2.0, name="seg 01"),
        FX.Clip(asset_path=video, offset=2.0, start=3.5, duration=2.5, name="seg 02"),
        FX.Clip(asset_path=video, offset=4.5, start=7.0, duration=1.5, name="seg 03"),
    ]
    # One graphic inside each clip, at a deliberately awkward position within it.
    connected = [
        FX.Connected(asset_path=video, offset=0.5, duration=1.0, name="c001"),
        FX.Connected(asset_path=video, offset=3.25, duration=1.0, name="c002"),
        FX.Connected(asset_path=video, offset=4.75, duration=0.75, name="c003"),
    ]
    clips[1].markers.append((3.0, "BROLL: bubbles", True))
    chapters = [(0.0, "The temperature mistake"), (4.5, "What actually works")]

    builder = FX.FCPXMLBuilder(project="test", aspect="16:9")
    tree = builder.build(clips, connected, chapters)
    path = builder.write(tree, out_dir / "test.fcpxml")
    return path, clips, connected, chapters


# --------------------------------------------------------------------------------------
# Validation and structure
# --------------------------------------------------------------------------------------

def test_generated_document_validates(built):
    path, *_ = built
    assert FX.validate(path) == []


def test_document_satisfies_final_cuts_own_dtd(built):
    """
    The real import contract, not our reading of it.

    Final Cut ships the DTD for every FCPXML version it reads, so this is the same schema the
    importer enforces. It caught a live defect our hand-written checks passed: connected clips
    carried a `role` attribute, and asset-clip has no such attribute — only `audioRole` and
    `videoRole`. FCP's report on that would have been "The file could not be imported".
    """
    path, *_ = built
    problems = FX.dtd_problems(path)
    if problems is None:
        pytest.skip("Final Cut Pro is not installed on this machine")
    assert problems == []


def test_graphics_carry_videorole_not_role(built):
    """
    The specific shape of that defect, pinned. `role` on an asset-clip is undeclared and
    silently wrong; graphics are video-only ProRes 4444 layers, so videoRole is the correct
    carrier for [S-006]'s lane discipline.
    """
    path, *_ = built
    root = ET.parse(path).getroot()
    graphics = [g for p in root.iter("spine") for c in p.findall("asset-clip")
                for g in c.findall("asset-clip")]
    assert graphics
    for g in graphics:
        assert g.get("role") is None, "asset-clip has no `role` attribute in FCP's schema"
        assert g.get("videoRole") == C.ROLE_GRAPHICS_SUB


@pytest.mark.parametrize("aspect", ["16:9", "9:16"])
def test_both_aspects_satisfy_the_dtd(tmp_path, video, aspect):
    """The vertical cut goes through the same importer and gets the same scrutiny."""
    builder = FX.FCPXMLBuilder(project="aspect", aspect=aspect)
    clips = [FX.Clip(asset_path=video, offset=0.0, start=0.0, duration=3.0, name="one")]
    connected = [FX.Connected(asset_path=video, offset=0.5, duration=1.0, name="c001")]
    clips[0].markers.append((1.0, "MACRO: bubbles", True))
    path = builder.write(builder.build(clips, connected, [(0.0, "Chapter")]),
                         tmp_path / f"{aspect.replace(':', '-')}.fcpxml")

    problems = FX.dtd_problems(path)
    if problems is None:
        pytest.skip("Final Cut Pro is not installed on this machine")
    assert problems == []


def test_document_parses_and_declares_the_right_version(built):
    path, *_ = built
    root = ET.parse(path).getroot()
    assert root.tag == "fcpxml"
    assert root.get("version") == C.FCPXML_VERSION


def test_format_is_the_project_timebase(built):
    path, *_ = built
    fmt = ET.parse(path).getroot().find("./resources/format")
    assert fmt.get("frameDuration") == C.FRAME_DURATION
    assert (fmt.get("width"), fmt.get("height")) == ("1920", "1080")


def test_every_time_value_sits_on_the_frame_grid(built):
    """[S-007] — an off-grid value makes FCP reject the import or shift a clip a frame."""
    path, *_ = built
    for el in ET.parse(path).getroot().iter():
        for attr in ("offset", "start", "duration"):
            v = el.get(attr)
            if not v or v == "0s":
                continue
            num, den = v[:-1].split("/")
            assert int(den) == SCALE, f"<{el.tag} {attr}={v}> wrong timescale"
            assert int(num) % TICKS == 0, f"<{el.tag} {attr}={v}> is off the frame grid"


def test_media_is_referenced_by_absolute_file_url(built):
    """A relative path imports as offline media, which looks like a pipeline failure."""
    path, *_ = built
    for rep in ET.parse(path).getroot().iter("media-rep"):
        assert rep.get("src", "").startswith("file://")


def test_the_same_media_is_registered_once(built):
    """All three clips come off one source; three asset entries would duplicate it in FCP."""
    path, *_ = built
    assets = list(ET.parse(path).getroot().iter("asset"))
    assert len(assets) == 1


def test_validate_catches_an_off_grid_time(tmp_path):
    """The validator has to actually fail — a check that never fires protects nothing."""
    doc = (
        '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE fcpxml>\n'
        f'<fcpxml version="{C.FCPXML_VERSION}"><resources>'
        f'<format id="r1" frameDuration="{C.FRAME_DURATION}"/></resources>'
        '<library><event><project><sequence format="r1"><spine>'
        '<asset-clip ref="r1" offset="500/24000s" duration="1001/24000s"/>'
        "</spine></sequence></project></event></library></fcpxml>"
    )
    path = tmp_path / "bad.fcpxml"
    path.write_text(doc)
    problems = FX.validate(path)
    assert any("off the frame grid" in p for p in problems), problems


def test_validate_catches_a_dangling_reference(tmp_path):
    doc = (
        '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE fcpxml>\n'
        f'<fcpxml version="{C.FCPXML_VERSION}"><resources>'
        f'<format id="r1" frameDuration="{C.FRAME_DURATION}"/></resources>'
        '<library><event><project><sequence format="r1"><spine>'
        '<asset-clip ref="r99" offset="0s" duration="1001/24000s"/>'
        "</spine></sequence></project></event></library></fcpxml>"
    )
    path = tmp_path / "dangling.fcpxml"
    path.write_text(doc)
    assert any("doesn't exist" in p for p in FX.validate(path))


def test_build_refuses_an_empty_spine():
    """A sequence with no primary storyline is not a timeline she can open."""
    builder = FX.FCPXMLBuilder(project="empty")
    with pytest.raises(ValueError):
        builder.build([], [])


# --------------------------------------------------------------------------------------
# Connected clips — the offset that puts graphics in the wrong place
# --------------------------------------------------------------------------------------

def test_connected_offsets_reconstruct_to_absolute_timeline_positions(built):
    """
    The written offset is parent-local: parent.start + (timeline_pos − parent.offset).
    Invert it and every graphic must come back to the position the plan asked for.
    """
    path, clips, connected, _ = built
    root = ET.parse(path).getroot()

    wanted = {g.name: g.offset for g in connected}
    seen: dict[str, float] = {}

    for parent in root.iter("spine"):
        for clip_el in parent.findall("asset-clip"):
            p_offset = seconds_of(clip_el.get("offset"))
            p_start = seconds_of(clip_el.get("start"))
            for graphic in clip_el.findall("asset-clip"):
                local = seconds_of(graphic.get("offset"))
                absolute = p_offset + (local - p_start)
                seen[graphic.get("name")] = absolute

    assert set(seen) == set(wanted), f"graphics lost or duplicated: {sorted(seen)}"
    for name, expected in wanted.items():
        assert seen[name] == pytest.approx(C.snap_seconds(expected), abs=1e-6), (
            f"{name} reconstructs to {seen[name]:.4f}s, plan said {expected:.4f}s"
        )


def test_each_connected_clip_is_attached_to_the_clip_that_contains_it(built):
    path, clips, connected, _ = built
    root = ET.parse(path).getroot()
    for clip_el in root.iter("spine"):
        for parent in clip_el.findall("asset-clip"):
            p_offset = seconds_of(parent.get("offset"))
            p_dur = seconds_of(parent.get("duration"))
            p_start = seconds_of(parent.get("start"))
            for graphic in parent.findall("asset-clip"):
                absolute = p_offset + (seconds_of(graphic.get("offset")) - p_start)
                assert p_offset - 1e-6 <= absolute < p_offset + p_dur + 1e-6, (
                    f"{graphic.get('name')} is attached to a clip that does not contain it"
                )


def test_connected_clips_are_on_a_lane_above_the_storyline(built):
    """[S-006] — graphics stay independently movable, which means a real lane, not a merge."""
    path, *_ = built
    root = ET.parse(path).getroot()
    graphics = [g for p in root.iter("spine") for c in p.findall("asset-clip")
                for g in c.findall("asset-clip")]
    assert graphics
    for g in graphics:
        assert int(g.get("lane")) >= 1
        assert g.get("videoRole") == C.ROLE_GRAPHICS_SUB


def test_nothing_extends_past_the_sequence_duration(built):
    """
    A graphic that runs past the end of the sequence silently disappears in FCP — the clip
    is there in the XML and simply never plays.
    """
    path, *_ = built
    root = ET.parse(path).getroot()
    total = seconds_of(root.find(".//sequence").get("duration"))
    assert total > 0

    for parent in root.iter("spine"):
        for clip_el in parent.findall("asset-clip"):
            p_offset = seconds_of(clip_el.get("offset"))
            p_start = seconds_of(clip_el.get("start"))
            assert p_offset + seconds_of(clip_el.get("duration")) <= total + 1e-6

            for child in clip_el:
                if child.tag not in ("asset-clip", "marker", "chapter-marker"):
                    continue
                absolute = p_offset + (seconds_of(child.get("start") or
                                                  child.get("offset")) - p_start)
                end = absolute + seconds_of(child.get("duration") or "0s")
                assert end <= total + 1e-6, (
                    f"<{child.tag} {child.get('value') or child.get('name')}> ends at "
                    f"{end:.3f}s, past the {total:.3f}s sequence"
                )


def test_markers_and_chapters_reconstruct_to_their_timeline_positions(built):
    path, clips, _, chapters = built
    root = ET.parse(path).getroot()

    found_chapters: list[float] = []
    found_markers: list[float] = []
    for parent in root.iter("spine"):
        for clip_el in parent.findall("asset-clip"):
            p_offset = seconds_of(clip_el.get("offset"))
            p_start = seconds_of(clip_el.get("start"))
            for ch in clip_el.findall("chapter-marker"):
                found_chapters.append(p_offset + (seconds_of(ch.get("start")) - p_start))
            for mk in clip_el.findall("marker"):
                found_markers.append(p_offset + (seconds_of(mk.get("start")) - p_start))

    assert sorted(found_chapters) == pytest.approx(sorted(C.snap_seconds(a) for a, _ in chapters))
    assert found_markers == pytest.approx([C.snap_seconds(3.0)])


# --------------------------------------------------------------------------------------
# Captions  (§6.7)
# --------------------------------------------------------------------------------------

def parse_itt_cards(path) -> list[list[str]]:
    """Every caption card, as its list of rendered lines."""
    text = path.read_text()
    cards: list[list[str]] = []
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("<p "):
            continue
        body = line.split(">", 1)[1].rsplit("</p>", 1)[0]
        cards.append([seg for seg in body.split("<br/>")])
    return cards


def test_itt_lines_respect_the_character_limit(tmp_path, words):
    """
    §6.7 — the pipeline decides the line breaks, not FCP's auto-wrap, so they break on sense
    rather than on width. That only holds if the pipeline's own limit holds.
    """
    path, _ = FX.build_itt(words, tmp_path / "caps.itt")
    cards = parse_itt_cards(path)
    assert cards, "no caption cards were written"
    for card in cards:
        for line in card:
            assert len(line) <= C.CAPTION_MAX_CHARS_PER_LINE, (
                f"{len(line)} chars: {line!r} (limit {C.CAPTION_MAX_CHARS_PER_LINE})"
            )


def test_itt_cards_respect_the_line_limit(tmp_path, words):
    path, _ = FX.build_itt(words, tmp_path / "caps.itt")
    for card in parse_itt_cards(path):
        assert len(card) <= C.CAPTION_MAX_LINES, f"{len(card)} lines: {card}"


def test_itt_is_well_formed_xml(tmp_path, words):
    path, _ = FX.build_itt(words, tmp_path / "caps.itt")
    root = ET.parse(path).getroot()
    assert root.tag.endswith("tt")
    assert root.get("{http://www.w3.org/ns/ttml#parameter}frameRate") == "24"
    assert root.get("{http://www.w3.org/ns/ttml#parameter}frameRateMultiplier") == "1000 1001"


def test_itt_declares_the_pulldown_not_a_float_rate(tmp_path, words):
    """
    iTT counts frames at the nominal 24 with a 1000/1001 multiplier. Writing 23.976 as the
    frame rate is the [S-007] failure in a different file format.
    """
    text = (FX.build_itt(words, tmp_path / "caps.itt")[0]).read_text()
    assert 'ttp:frameRate="24"' in text
    assert "23.976" not in text


def test_captions_are_remapped_onto_the_cut_timeline(tmp_path, words, edl):
    """
    A caption timed to the source is seconds out once Stage 2 has removed the retakes, and
    still contains the lines that were cut.
    """
    tmap = FX.TimelineMap([{"start": k.start, "end": k.end} for k in edl.keeps])
    path, dropped = FX.build_itt(words, tmp_path / "caps.itt", tmap=tmap)

    assert dropped > 0, "nothing was dropped, yet Stage 2 removed a whole take"

    text = path.read_text()
    assert "stone dead" in text        # the surviving take is captioned
    # Cards must not run past the end of the cut timeline.
    for card in parse_itt_cards(path):
        assert card


def test_wrap_balanced_never_exceeds_the_limit():
    samples = [
        "Above forty six degrees the cell walls rupture and the yeast dies",
        "Proof it between twenty four and twenty eight degrees",
        "short",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    ]
    for s in samples:
        lines = FX.wrap_balanced(s)
        assert len(lines) <= C.CAPTION_MAX_LINES
        for line in lines:
            # A single unbreakable token can legitimately exceed the measure; anything with a
            # space in it must not.
            if " " in s:
                assert len(line) <= C.CAPTION_MAX_CHARS_PER_LINE, (s, line)


def test_wrap_balanced_survives_an_unbreakable_token():
    """
    One token longer than the measure has no split point. Returning it long is the only
    sensible outcome — the previous behaviour was a bare `assert` that took the whole
    caption build down with it.
    """
    long_token = "a" * 55
    assert FX.wrap_balanced(long_token) == [long_token]
    assert FX.wrap_balanced("x") == ["x"]
    assert FX.wrap_balanced("") == [""]


def test_wrap_balanced_keeps_all_the_words():
    s = "Above forty six degrees the cell walls rupture and the yeast dies"
    assert " ".join(FX.wrap_balanced(s)).split() == s.split()


def test_smpte_counts_frames_at_the_nominal_rate():
    """
    iTT counts frames at a nominal 24 and declares the 1000/1001 pulldown separately, so a
    timecode round-trips through the *frame index*, not through wall-clock seconds. Asserting
    on hand-computed clock times instead is how the pulldown gets quietly dropped.
    """
    assert FX.smpte(0.0) == "00:00:00:00"

    for seconds in (0.0, 0.5, 1.0, 59.9, 60.0, 3599.5, 3600.0):
        frame = C.frames(seconds)
        hh, mm, ss, ff = (int(p) for p in FX.smpte(seconds).split(":"))
        assert 0 <= ff < 24
        assert ((hh * 60 + mm) * 60 + ss) * 24 + ff == frame


def test_smpte_is_monotonic():
    codes = [FX.smpte(s / 4) for s in range(0, 400)]
    assert codes == sorted(codes)


def test_escape_handles_xml_metacharacters():
    assert FX.escape('a & b < c > d "e"') == "a &amp; b &lt; c &gt; d &quot;e&quot;"


def test_source_ranges_splits_a_span_that_straddles_a_cut():
    """
    A line heard in the finished cut can span several keeps. Returning one range would cover
    the material between them too, and cut a good take along with the duplicate. [S-026]
    """
    tmap = FX.TimelineMap([{"start": 10.0, "end": 12.0}, {"start": 20.0, "end": 25.0}])
    assert tmap.source_ranges(1.0, 4.0) == [(11.0, 12.0), (20.0, 22.0)]


def test_source_ranges_is_the_inverse_of_to_timeline():
    tmap = FX.TimelineMap([{"start": 10.0, "end": 12.0}, {"start": 20.0, "end": 25.0}])
    for src in (10.5, 11.9, 20.1, 24.5):
        tl = tmap.to_timeline(src)
        assert tmap.source_ranges(tl, tl + 0.1)[0][0] == pytest.approx(src)


def test_push_in_is_a_transform_with_keyframes_in_clip_time(tmp_path, video):
    """
    A punch-in or push is written as <adjust-transform>, never rendered — and the DTD orders
    video intrinsics before audio ones, so it has to land ahead of <adjust-volume>.
    """
    builder = FX.FCPXMLBuilder(project="push", aspect="16:9")
    clips = [
        FX.Clip(asset_path=video, offset=0.0, start=0.0, duration=3.0, name="static", scale=1.08,
                gain_db=6.0),
        FX.Clip(asset_path=video, offset=3.0, start=4.0, duration=2.0, name="push",
                push_to=1.06),
    ]
    path = builder.write(builder.build(clips, [], []), tmp_path / "push.fcpxml")
    root = ET.parse(path).getroot()
    static, push = list(root.iter("asset-clip"))

    assert [c.tag for c in static][:2] == ["adjust-transform", "adjust-volume"]
    assert static.find("adjust-transform").get("scale") == "1.0800 1.0800"

    kfs = push.findall("adjust-transform/param[@name='scale']/keyframeAnimation/keyframe")
    assert [seconds_of(k.get("time")) for k in kfs] == pytest.approx(
        [C.snap_seconds(4.0), C.snap_seconds(6.0)], abs=1e-6)   # source time, not timeline
    assert kfs[-1].get("value") == "1.0600 1.0600"

    problems = FX.dtd_problems(path)
    if problems is None:
        pytest.skip("Final Cut Pro is not installed on this machine")
    assert problems == []


def test_reframe_composes_with_a_push_and_snaps_in_one_frame(tmp_path, video):
    """A picture's reframe scales the footage and moves it right, multiplied onto the push."""
    clip = FX.Clip(asset_path=video, offset=0.0, start=0.0, duration=4.0, name="r",
                   push_to=1.04, reframe=[(1.0, 3.0)])
    keys = clip.transform_keys()
    times = [round(k[0], 3) for k in keys]
    assert times[0] == 0.0 and times[-1] == 4.0
    inside = [k for k in keys if 1.0 <= k[0] <= 3.0]
    assert all(abs(k[2] - C.REFRAME_X) < 1e-6 for k in inside)          # moved right
    assert all(abs(k[1] / C.REFRAME_SCALE - (1 + 0.04 * k[0] / 4)) < 1e-3 for k in inside)
    before = next(k for k in keys if k[0] < 1.0 and k[0] > 0.9)        # one frame earlier
    assert before[2] == 0.0 and abs(1.0 - before[0] - 1 / C.FPS) < 1e-6

    builder = FX.FCPXMLBuilder(project="reframe", aspect="16:9")
    path = builder.write(builder.build([clip], [], []), tmp_path / "reframe.fcpxml")
    root = ET.parse(path).getroot()
    assert root.find(".//adjust-transform/param[@name='position']/keyframeAnimation") is not None
    problems = FX.dtd_problems(path)
    if problems is None:
        pytest.skip("Final Cut Pro is not installed on this machine")
    assert problems == []

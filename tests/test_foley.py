"""
Foley placement invariants (taste_principles §8; HANDOFF item 7).

§8 calls foley the secret weapon, and the two ways to get it wrong are both subtle. A hit at
the entrance *start* sounds like the piece announcing itself before it arrives; the sound is
the piece touching the table, so it belongs at contact. And the same tap twice in a row is
worse than silence — it tells the viewer they are hearing a sample rather than a thing
happening.
"""

from __future__ import annotations

import json

import pytest

import config as C
import fixtures as FX
import foley
import stepclock as SC


@pytest.fixture(scope="module")
def library(tmp_path_factory):
    return foley.Library(FX.write_foley_library(tmp_path_factory.mktemp("foley") / "lib"))


def plan(cues=None):
    return {"cues": cues if cues is not None else [
        {"id": "c001", "kind": "GFX", "start": 2.0,
         "assets": ["cutout:yeast_cell", "cutout:thermometer", "cutout:jar"]},
        {"id": "c002", "kind": "CHAPTER", "start": 8.0, "assets": ["cutout:card"]},
    ]}


# --------------------------------------------------------------------------------------
# Timing — the hit lands on contact, not on the entrance
# --------------------------------------------------------------------------------------

def test_contact_is_derived_from_the_easing_not_hardcoded():
    """
    §5.3's settle means a piece reaches the surface partway through its placement. Reading
    that off `place_in` rather than assuming it means the foley follows if the settle is ever
    retuned, instead of drifting quietly out of sync.
    """
    clock = SC.StepClock()
    contact = foley.contact_frame(clock)
    assert 0 < contact < C.PLACE_FRAMES[1], "contact should be inside the placement, not at its end"
    assert SC.place_in("probe", contact, C.PLACE_FRAMES[1], clock).y >= 0.0
    before = contact - C.GRAPHIC_STEP
    assert SC.place_in("probe", before, C.PLACE_FRAMES[1], clock).y < 0.0, (
        "the frame before contact must still be above the surface"
    )


def test_contact_lands_on_the_step_grid():
    """Non-negotiable 6 — the graphic layer only moves on even frames, so contact is on one."""
    assert foley.contact_frame(SC.StepClock()) % C.GRAPHIC_STEP == 0


def test_hit_is_after_the_entrance_starts(library):
    """The sound is the piece touching the table, not the piece beginning to move."""
    hits, _ = foley.hits_for_plan(plan(), library)
    first = min(h.at for h in hits)
    assert first > 2.0, "the first hit is at the entrance start, not at contact"
    assert first < 2.0 + C.PLACE_FRAMES[1] / C.FPS + 1e-6


def test_one_hit_per_element_staggered(library):
    """
    A diagram assembled from three cutouts gets three taps, 4 frames apart — which is what
    stop-motion assembly sounds like, and why §5.3's stagger exists.
    """
    hits, _ = foley.hits_for_plan(plan(), library)
    c001 = sorted(h.at for h in hits if h.cue_id == "c001")
    assert len(c001) == 3
    gaps = [round((b - a) * C.FPS) for a, b in zip(c001, c001[1:])]
    assert gaps == [C.STAGGER_FRAMES, C.STAGGER_FRAMES]


def test_hits_land_on_the_frame_grid(library):
    hits, _ = foley.hits_for_plan(plan(), library)
    for hit in hits:
        assert C.frames(hit.at) * C.FPS_DEN / C.FPS_NUM == pytest.approx(hit.at, abs=1e-9)


def test_only_rendered_cues_get_sound(library):
    """
    A note or a b-roll marker is a shot instruction for her, not something on screen. A tap
    against a graphic nobody rendered is a sound with no picture.
    """
    hits, _ = foley.hits_for_plan(plan([
        {"id": "c001", "kind": "GFX", "start": 1.0, "assets": ["cutout:a"]},
        {"id": "c002", "kind": "BROLL", "start": 2.0, "assets": ["cutout:b"]},
        {"id": "c003", "kind": "NOTE", "start": 3.0, "assets": ["cutout:c"]},
        {"id": "c004", "kind": "VO", "start": 4.0, "assets": ["cutout:d"]},
    ]), library)
    assert {h.cue_id for h in hits} == {"c001"}


def test_unanchored_cues_are_skipped(library):
    hits, _ = foley.hits_for_plan(
        plan([{"id": "c001", "kind": "GFX", "start": None, "assets": ["cutout:a"]}]), library)
    assert hits == []


def test_hits_are_remapped_onto_the_cut_timeline(library):
    """
    Cue times are source time; the timeline is the cut. Without the remap every hit lands late
    by however much Stage 2 removed before it — the bug CLAUDE.md flags as the cause of any
    "graphic in the wrong place" report, in audio.
    """
    from fcpxml import TimelineMap

    tmap = TimelineMap([{"start": 0.0, "end": 5.0}, {"start": 15.0, "end": 25.0}])
    cues = plan([{"id": "c001", "kind": "GFX", "start": 16.0, "assets": ["cutout:a"]}])

    raw, _ = foley.hits_for_plan(cues, library)
    mapped, _ = foley.hits_for_plan(cues, library, tmap=tmap)
    assert raw[0].at > 16.0
    assert mapped[0].at == pytest.approx(6.0 + foley.contact_frame(SC.StepClock()) / C.FPS,
                                         abs=0.05)


# --------------------------------------------------------------------------------------
# Variation
# --------------------------------------------------------------------------------------

def test_the_same_sound_never_fires_twice_consecutively(library):
    """
    §8's whole point. A repeated tap announces that the sound is a sample rather than a thing
    happening, which is worse than having no foley at all.
    """
    many = plan([{"id": f"c{i:03d}", "kind": "GFX", "start": float(i),
                  "assets": ["cutout:a", "cutout:b", "cutout:c"]} for i in range(1, 15)])
    hits, _ = foley.hits_for_plan(many, library)
    assert len(hits) == 42
    for a, b in zip(hits, hits[1:]):
        if a.category == b.category:
            assert a.sound != b.sound, f"{a.sound.name} fired twice in a row at {b.at:.2f}s"


def test_variation_is_deterministic(library):
    """Seeded, like everything in stepclock — the same plan must sound identical every run."""
    first, _ = foley.hits_for_plan(plan(), library)
    second, _ = foley.hits_for_plan(plan(), library)
    assert [h.sound for h in first] == [h.sound for h in second]


def test_the_library_is_actually_walked(library):
    """
    Never-repeat is necessary but not sufficient: alternating between two files would satisfy
    it while wasting the other three takes she recorded.
    """
    many = plan([{"id": f"c{i:03d}", "kind": "GFX", "start": float(i),
                  "assets": ["cutout:a", "cutout:b"]} for i in range(1, 12)])
    hits, _ = foley.hits_for_plan(many, library)
    used = {h.sound for h in hits if h.category == "tap"}
    assert len(used) == len(library.sounds["tap"]), f"only {len(used)} of the takes were used"


def test_a_single_take_library_still_works(tmp_path):
    """One recorded take cannot avoid repeating. It must not crash trying."""
    FX.write_foley_library(tmp_path / "one", counts={"tap": 1})
    lib = foley.Library(tmp_path / "one")
    hits, problems = foley.hits_for_plan(plan(), lib)
    assert hits and not problems


# --------------------------------------------------------------------------------------
# Library and refusals
# --------------------------------------------------------------------------------------

def test_library_groups_by_filename_prefix(library):
    assert library.categories == {"tap", "slide", "squeak"}
    assert len(library) == 10


def test_unknown_category_is_reported_not_substituted(library):
    """
    "Never silently substitute a default." A marker squeak where a cardboard tap belongs is a
    wrong sound, and a wrong sound is more damaging than a missing one.
    """
    hits, problems = foley.hits_for_plan(
        plan([{"id": "c001", "kind": "GFX", "start": 1.0,
               "assets": ["cutout:a"], "foley": "scratch"}]), library)
    assert hits == []
    assert problems and "scratch" in problems[0]
    assert "tap" in problems[0], "the message should say what *is* recorded"


def test_cue_can_choose_its_category(library):
    hits, _ = foley.hits_for_plan(
        plan([{"id": "c001", "kind": "GFX", "start": 1.0,
               "assets": ["cutout:a"], "foley": "slide"}]), library)
    assert hits[0].category == "slide"
    assert hits[0].sound.stem.startswith("slide")


def test_empty_library_reports_rather_than_blocking(tmp_path, capsys):
    """
    §8 wants foley everywhere, but its absence is missing polish, not a missing graphic — so
    it reports and stops rather than blocking the handoff the way [S-001] blocks a cutout.
    """
    (tmp_path / "plan").mkdir()
    (tmp_path / "plan" / "video001.plan.json").write_text(json.dumps(plan()))
    code = foley.main([str(tmp_path / "plan" / "video001.plan.json"),
                       "--library", str(tmp_path / "nothing-here")])
    out = capsys.readouterr().out
    assert code != 0
    assert "no foley recorded" in out
    assert "tap_01.wav" in out, "the message should show the naming convention"


# --------------------------------------------------------------------------------------
# FCPXML output
# --------------------------------------------------------------------------------------

def test_foley_is_audio_below_the_storyline_on_the_effects_role(library):
    """
    Final Cut stacks negative lanes below the primary storyline. A foley hit on a positive
    lane would sit in the video stack, above the picture.
    """
    hits, _ = foley.hits_for_plan(plan(), library)
    connected = foley.to_connected(hits)
    assert connected
    for clip in connected:
        assert clip.audio is True
        assert clip.lane < 0
        assert clip.role == C.ROLE_EFFECTS


def test_foley_clips_write_audiorole_and_validate(tmp_path, video, library):
    """[S-017] — asset-clip has no bare `role`; audio takes audioRole."""
    import fcpxml as FX_

    hits, _ = foley.hits_for_plan(plan(), library)
    builder = FX_.FCPXMLBuilder(project="foley", aspect="16:9")
    clips = [FX_.Clip(asset_path=video, offset=0.0, start=0.0, duration=12.0, name="seg")]
    path = builder.write(builder.build(clips, foley.to_connected(hits)),
                         tmp_path / "foley.fcpxml")

    text = path.read_text()
    assert 'audioRole="Effects.Foley"' in text
    assert FX_.validate(path) == []

    schema = FX_.dtd_problems(path)
    if schema is not None:
        assert schema == [], schema

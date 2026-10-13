"""
Rough-cut invariants (style_guide [S-002], taste_principles §8).

The breath floor is the one this file exists for. Cutting every pause to zero is the single
most recognisable signature of a machine edit — it sounds wrong before a viewer can say why —
so it gets tested against the *surviving* silence, not against the stage's own arithmetic.
"""

from __future__ import annotations

import pytest

import config as C
import fixtures as FX
import stage2_roughcut as S2
from fcpxml import TimelineMap


# --------------------------------------------------------------------------------------
# The breath floor  [S-002]
# --------------------------------------------------------------------------------------

def surviving_gaps(words: list[dict], edl) -> list[tuple[float, float, str, str]]:
    """
    (original_gap, surviving_gap, before_word, after_word) for every consecutive word pair.

    Measured on the timeline, not from the EDL's own drop arithmetic — that would only prove
    the stage agrees with itself. What matters is the pause a viewer actually hears.
    """
    tmap = TimelineMap([{"start": k.start, "end": k.end} for k in edl.keeps])
    out: list[tuple[float, float, str, str]] = []
    for a, b in zip(words, words[1:]):
        ta, tb = tmap.to_timeline(a["end"]), tmap.to_timeline(b["start"])
        if ta is None or tb is None:      # one of them was cut out entirely
            continue
        out.append((b["start"] - a["end"], tb - ta, a["word"], b["word"]))
    return out


def test_no_gap_is_ever_trimmed_below_the_breath_floor(words, edl):
    """
    [S-002] governs *trimming*: never reduce a pause below 120 ms.

    So the bound is `min(original, floor)`, not `floor`. Natural speech is full of 60 ms gaps
    between words inside a phrase — those are not silences the stage trimmed, and holding them
    to 120 ms would be testing the fixture's cadence rather than the pipeline's behaviour.
    """
    floor = C.BREATH_FLOOR_MS / 1000.0
    for original, surviving, before, after in surviving_gaps(words, edl):
        assert surviving >= min(original, floor) - 1e-6, (
            f"{before!r} -> {after!r}: {original * 1000:.0f} ms trimmed to "
            f"{surviving * 1000:.0f} ms — [S-002] floor is {C.BREATH_FLOOR_MS} ms"
        )


def test_a_trimmed_pause_keeps_at_least_the_breath_floor(words, edl):
    """
    The half of the rule above can't see: for every pause that *was* shortened, what is left
    has to clear the floor outright.
    """
    floor = C.BREATH_FLOOR_MS / 1000.0
    trimmed = [g for g in surviving_gaps(words, edl) if g[1] < g[0] - 1e-6]
    assert trimmed, "nothing was trimmed — the fixture is not exercising the dead-air pass"
    for original, surviving, before, after in trimmed:
        assert surviving >= floor - 1e-6, (
            f"{before!r} -> {after!r}: trimmed {original * 1000:.0f} ms down to "
            f"{surviving * 1000:.0f} ms, under the {C.BREATH_FLOOR_MS} ms floor"
        )


def test_long_gaps_are_actually_shortened(words, edl):
    """
    The floor is only half the rule. A stage that never trims anything would pass the test
    above trivially, so confirm the long pauses did come down.
    """
    before = {round(a["end"], 3): b["start"] - a["end"] for a, b in zip(words, words[1:])}
    long_gaps = [g for g in before.values() if g * 1000 > C.MIN_SILENCE_TO_CUT_MS]
    assert long_gaps, "fixture has no gaps long enough to trim — it is not exercising the pass"
    assert edl.cut_duration < edl.source_duration, "nothing was removed at all"


def test_short_gaps_are_left_completely_alone(words):
    """
    Gaps under MIN_SILENCE_TO_CUT_MS are untouched — the seam costs more than the time saved.
    """
    for drop in S2.find_dead_air(words):
        # The lead-in and tail are gaps too, but they sit outside any word pair.
        if "lead-in" in drop["reason"] or drop["reason"].startswith("tail"):
            continue
        gap = next(
            (b["start"] - a["end"] for a, b in zip(words, words[1:])
             if a["end"] <= drop["start"] and b["start"] >= drop["end"]),
            None,
        )
        assert gap is not None
        assert gap * 1000 >= C.MIN_SILENCE_TO_CUT_MS


def test_lead_in_before_the_first_word_is_trimmed():
    """
    Silence before she starts talking is a gap like any other. Only looking *between* words
    left 21 seconds of nobody speaking as the opening shot of the first real clip.
    """
    words = [{"word": "Hello.", "start": 21.0, "end": 21.4},
             {"word": "There.", "start": 22.0, "end": 22.5}]
    drops = S2.find_dead_air(words, duration=30.0)
    lead = [d for d in drops if "lead-in" in d["reason"]]
    assert lead, "21 s of leading silence was kept"
    assert lead[0]["start"] == 0.0
    # A breath is still left in front of the first word — never a hard start on speech.
    assert 21.0 - lead[0]["end"] == pytest.approx(C.BREATH_PARAGRAPH_MS / 1000.0, abs=1e-6)


def test_tail_after_the_last_word_is_trimmed():
    words = [{"word": "Hello.", "start": 1.0, "end": 1.4},
             {"word": "There.", "start": 2.0, "end": 2.5}]
    drops = S2.find_dead_air(words, duration=40.0)
    tail = [d for d in drops if d["reason"].startswith("tail")]
    assert tail and tail[0]["end"] == 40.0
    assert tail[0]["start"] - 2.5 == pytest.approx(C.BREATH_PARAGRAPH_MS / 1000.0, abs=1e-6)


def test_a_short_lead_in_is_left_alone():
    """Half a second before the first word is a breath, not dead air."""
    words = [{"word": "Hello.", "start": 0.3, "end": 0.8}]
    assert [d for d in S2.find_dead_air(words, duration=5.0) if "lead-in" in d["reason"]] == []


def test_dead_air_never_removes_more_than_the_gap_holds(words):
    for drop in S2.find_dead_air(words):
        assert drop["end"] > drop["start"]
        removable = (drop["end"] - drop["start"]) * 1000
        assert removable > C.BREATH_FLOOR_MS, (
            "a trim smaller than the floor should have been skipped entirely"
        )


def test_breath_floor_constant_matches_the_spec():
    """Non-negotiable 4 and [S-002]: 120 ms, with 150/250 ms targets at boundaries."""
    assert C.BREATH_FLOOR_MS == 120
    assert C.BREATH_SENTENCE_MS >= C.BREATH_FLOOR_MS
    assert C.BREATH_PARAGRAPH_MS >= C.BREATH_SENTENCE_MS


# --------------------------------------------------------------------------------------
# Repeated takes — the LATER one survives
# --------------------------------------------------------------------------------------

def test_the_later_take_survives_not_the_earlier(words, edl):
    """
    She says a line, stumbles, says it again. The second attempt is the good one — keeping
    the first is worse than making no cut at all, because it silently ships the fluff.
    """
    bad_start, bad_end = FX.span_of(words, "take_bad")
    good_start, good_end = FX.span_of(words, "take_good")
    assert bad_end < good_start, "fixture ordering is wrong"

    tmap = TimelineMap([{"start": k.start, "end": k.end} for k in edl.keeps])

    bad_mid = (bad_start + bad_end) / 2
    good_mid = (good_start + good_end) / 2

    assert tmap.to_timeline(bad_mid) is None, "the stumbled first take survived the cut"
    assert tmap.to_timeline(good_mid) is not None, "the clean second take was removed"


def test_repeated_take_detection_reports_the_earlier_span(words):
    sentences = S2.group_sentences(words)
    dropped = S2.find_repeated_takes(sentences)
    assert dropped, "no repeated take detected in a fixture that contains one"

    bad_start, bad_end = FX.span_of(words, "take_bad")
    good_start, _ = FX.span_of(words, "take_good")

    # The span is allowed to start earlier than the bad take itself: group_sentences() folds
    # the isolated "Um" in front of it into the same sentence, because neither carries
    # terminal punctuation and the gap between them is under a second. Covering the stumble
    # *and* the filler in one drop is the correct outcome.
    assert any(
        d["start"] <= bad_start + 1e-6 and d["end"] >= bad_end - 1e-6 and d["end"] <= good_start
        for d in dropped
    ), f"no dropped span covers the earlier take ({bad_start:.2f}–{bad_end:.2f}s): {dropped}"

    for d in dropped:
        assert d["start"] < good_start, "a drop starts at or after the surviving take"


def test_a_late_callback_is_not_treated_as_a_retake():
    """
    A phrase legitimately repeated later in the video — a callback or a recap — is not a bad
    take. Only repeats inside the 45 s window count.
    """
    line = "Yeast is a living organism and heat kills it stone dead."
    sentences = [
        {"start": 0.0, "end": 3.0, "text": line, "words": 11},
        {"start": 400.0, "end": 403.0, "text": line, "words": 11},
    ]
    assert S2.find_repeated_takes(sentences) == []


def test_short_lines_are_never_treated_as_retakes():
    """"Right." twice in a row is speech, not a retake."""
    sentences = [
        {"start": 0.0, "end": 0.5, "text": "Right.", "words": 1},
        {"start": 1.0, "end": 1.5, "text": "Right.", "words": 1},
    ]
    assert S2.find_repeated_takes(sentences) == []


# --------------------------------------------------------------------------------------
# Fillers
# --------------------------------------------------------------------------------------

def test_isolated_filler_is_removed(words, edl):
    start, end = FX.span_of(words, "filler_um")
    tmap = TimelineMap([{"start": k.start, "end": k.end} for k in edl.keeps])
    assert tmap.to_timeline((start + end) / 2) is None, "the isolated 'Um' survived"


def test_filler_tucked_mid_phrase_is_left_alone():
    """
    A filler with no gap around it can't be excised without a click, and the seam costs more
    than the word does.
    """
    tight = [
        {"word": "and", "start": 0.00, "end": 0.20},
        {"word": "um", "start": 0.22, "end": 0.32},
        {"word": "heat", "start": 0.34, "end": 0.60},
    ]
    assert S2.find_fillers(tight) == []


def test_fillers_only_removed_when_aggressive(words):
    meta = {"clip": "x", "source": "y.mov"}
    lazy = S2.build_edl(meta, words, aggressive=False)
    keen = S2.build_edl(meta, words, aggressive=True)
    assert lazy.stats["fillers"] == 0
    assert keen.stats["fillers"] > 0


# --------------------------------------------------------------------------------------
# EDL structure
# --------------------------------------------------------------------------------------

def test_keeps_are_ordered_and_disjoint(edl):
    for a, b in zip(edl.keeps, edl.keeps[1:]):
        assert a.end <= b.start, "keeps overlap — the same footage would appear twice"


def test_keeps_land_on_the_frame_grid(edl):
    """An off-grid cut shows as a torn field on export."""
    for k in edl.keeps:
        for value in (k.start, k.end):
            assert C.frames(value) / C.FPS == pytest.approx(value, abs=1e-3)


def test_no_keep_is_shorter_than_four_frames(edl):
    """A 3-frame island is a glitch, not an edit."""
    for k in edl.keeps:
        assert k.duration >= 4 / C.FPS - 1e-6


def test_something_survives(edl, words):
    assert edl.keeps, "the whole clip was cut"
    assert edl.cut_duration > 0.5 * edl.source_duration, (
        "over half the source was removed — far past the ~30% the conventions describe"
    )


# --------------------------------------------------------------------------------------
# Fragments, breath ownership, and the time target
# --------------------------------------------------------------------------------------

def test_a_trailing_fragment_is_treated_as_the_same_line():
    """
    "thousands of years ago." is the tail of the line before it, not a new one. Overlap ratio
    scores that at 0.40 and left it standing as its own shot right after the complete take.
    """
    full = "As humans, we started using yeast thousands of years ago."
    sentences = [
        {"start": 0.0, "end": 3.0, "text": full, "words": 10},
        {"start": 4.0, "end": 5.0, "text": "thousands of years ago.", "words": 4},
    ]
    dropped = S2.find_repeated_takes(sentences)
    assert [d["start"] for d in dropped] == [4.0], (
        "the fragment survived, or the complete take was dropped for it"
    )


def test_the_last_complete_take_wins_not_merely_the_last():
    """
    She trails off on the final attempt more often than not. Keeping "the last" literally kept
    a half-line and threw away the complete take sitting two attempts earlier.
    """
    full = "As humans, we started using yeast thousands of years ago."
    sentences = [
        {"start": 0.0, "end": 3.0, "text": full, "words": 10},
        {"start": 4.0, "end": 7.0, "text": full, "words": 10},
        {"start": 8.0, "end": 9.5, "text": "As humans, we started using yeast.", "words": 6},
    ]
    kept = {s["start"] for s in sentences} - {d["start"] for d in S2.find_repeated_takes(sentences)}
    assert kept == {4.0}, f"expected the last full take to survive, kept {kept}"


def test_breath_is_never_its_own_shot(edl, words):
    """
    A standalone breath between two takes is a third camera position for five frames, and reads
    as a glitch. The pause belongs to the take it leads into, where it costs no extra cut.
    """
    spoken = [
        k for k in edl.keeps
        if not any(k.start <= (w["start"] + w["end"]) / 2 <= k.end for w in words)
    ]
    assert spoken == [], f"{len(spoken)} wordless clip(s) survived as their own shots"


def test_breath_absorption_never_reaches_back_into_speech(edl, words):
    """
    Extending a take backwards to pick up its own breath must stop at silence. Reaching further
    drags in the last word of the discarded take before it — the first real cut opened on a
    stray "action." left over from an earlier attempt.
    """
    for k in edl.keeps:
        inside = [w for w in words if w["end"] > k.start and w["start"] < k.end]
        if len(inside) < 2:
            continue
        first, second = inside[0], inside[1]
        assert second["start"] - first["end"] < 1.5, (
            f"clip at {k.start:.2f}s opens on {first['word']!r}, then a "
            f"{second['start'] - first['end']:.1f}s hole — that word is a leftover"
        )


def test_target_never_cuts_below_the_breath_floor(words):
    """
    A time target tightens the pauses; it does not get to violate [S-002]. If the target can
    only be met by cutting her lines, the stage reports the shortfall instead.
    """
    meta = {"clip": "x", "source": "y.mov"}
    edl = S2.build_edl(meta, words, aggressive=False, target_seconds=0.5)
    floor = C.BREATH_FLOOR_MS / 1000.0
    for original, surviving, before, after in surviving_gaps(words, edl):
        assert surviving >= min(original, floor) - 1e-6, (
            f"the target pushed {before!r} -> {after!r} to {surviving * 1000:.0f} ms"
        )
    assert edl.stats.get("over_target"), "an impossible target was silently accepted"


# --------------------------------------------------------------------------------------
# Reading the cut  [S-021]
# --------------------------------------------------------------------------------------

# The last third of the first cut of real footage. Every timing check passed on this.
INCOHERENT = [
    {"start": 18.1, "end": 27.0, "words": 25, "text": "Archaeological records aren't exact "
     "about when we first started using yeast, but we do know that the earliest records that "
     "we have are from Egypt."},
    {"start": 27.4, "end": 32.0, "words": 19, "text": "But we do know that the earliest "
     "records that we have are from Egypt, and there's other records from"},
    {"start": 41.8, "end": 46.8, "words": 19, "text": "but we do know that yeast has shown up "
     "all over Asia and Europe from our earliest human ancestors,"},
]


def test_the_read_through_catches_what_every_timing_check_missed():
    problems = S2.read_through(INCOHERENT)
    assert problems, (
        "the cut that said Egypt twice and ended on a comma read as clean — the check that "
        "exists precisely to catch that is not catching it"
    )
    assert any("repeats" in p for p in problems), "the duplicated passage was not reported"
    assert any("mid-sentence" in p for p in problems), "the line ending on a comma was not reported"


def test_a_clean_script_reads_clean():
    assert S2.read_through([
        {"start": 0.0, "end": 2.0, "words": 6, "text": "This is yeast bubbling in action."},
        {"start": 3.0, "end": 6.0, "words": 10, "text": "As humans, we started using yeast "
                                                        "thousands of years ago."},
    ]) == []


def test_a_thinking_pause_is_not_a_trailed_off_line():
    """
    Her unscripted delivery pauses mid-sentence, and `group_sentences` ends a line at any gap
    over a second. Read one line at a time, every one of those breaths looks like an abandoned
    take: one assembly reported 28 of them, all wrong. A check that is wrong 28 times out of 30
    is not strict, it is ignored.
    """
    assert S2.read_through([
        {"start": 0.0, "end": 3.0, "words": 8, "text": "But if you're happy with your bread,"},
        {"start": 4.2, "end": 6.0, "words": 9,
         "text": "it doesn't matter if you have access to fresh yeast."},
    ]) == [], "a sentence split by a breath was reported as trailing off"


def test_a_restart_after_a_pause_is_still_a_restart():
    """The merge above must not swallow [S-021]: a restart begins a new sentence, not a clause."""
    problems = S2.read_through(INCOHERENT[1:])
    assert any("mid-sentence" in p for p in problems), (
        "joining paused lines hid the line that ends on a comma with a restart after it"
    )


def test_a_restarted_passage_is_one_take_even_at_low_similarity():
    """
    She restarts mid-passage, so two attempts share fourteen words verbatim and still score
    0.56 whole-sentence. Similarity shipped both; the cut said Egypt twice.
    """
    dropped = S2.find_repeated_takes(INCOHERENT[:2])
    assert [d["start"] for d in dropped] == [27.4], (
        "the unfinished second attempt at the Egypt passage survived alongside the first"
    )


def test_her_verbal_tic_is_not_a_restart():
    """"but we do know that" opens five unrelated sentences in one clip. Six shared words is
    not enough on its own — the run also has to be most of the shorter line."""
    assert not S2.is_restart(
        "but we do know that the earliest records are from egypt",
        "but we do know that yeast has shown up all over asia and europe")


def test_a_passage_with_no_finished_attempt_is_dropped_entirely():
    """
    Falling back to "the last one" when nothing was finished closed the cut on a five-word tail
    of an abandoned sentence. If she never got through it, there is no take of it.
    """
    line = "and we know there are records from all over Asia and Europe"
    sentences = [
        {"start": 0.0, "end": 4.0, "words": 11, "text": line + " about..."},
        {"start": 6.0, "end": 9.0, "words": 11, "text": line + ","},
    ]
    assert len(S2.find_repeated_takes(sentences)) == 2, "an unfinished passage survived"


def test_an_abandoned_line_she_talked_past_is_dropped():
    sentences = [
        {"start": 0.0, "end": 2.0, "words": 7, "text": "We do know that there are records,"},
        {"start": 3.0, "end": 6.0, "words": 8, "text": "Yeast turns up right across Asia."},
    ]
    assert [d["start"] for d in S2.find_repeated_takes(sentences)] == [0.0]


def test_the_last_thing_on_the_tape_is_not_assumed_abandoned():
    """An unfinished final line may just be where the camera stopped, not a discarded take."""
    sentences = [{"start": 0.0, "end": 2.0, "words": 7, "text": "And so what that means is"}]
    assert S2.find_repeated_takes(sentences) == []


# --------------------------------------------------------------------------------------
# Silence is a measurement, not an inference  [S-024]
# --------------------------------------------------------------------------------------

# Two words with a 1.7s hole between them — the shape of the intro on the first real clip.
STUMBLE_WORDS = [
    {"word": "is...", "start": 88.0, "end": 88.43},
    {"word": "Hi,", "start": 90.13, "end": 90.37},
    {"word": "I'm", "start": 90.97, "end": 92.97},
]
# What the microphone heard in that hole: two false starts WhisperX never turned into words,
# plus the clipped onset of "Hi," which begins before the transcript says it does.
STUMBLE_VOICED = [
    (87.0, 88.46), (89.01, 89.13), (89.64, 89.72), (89.98, 90.40), (90.90, 93.0),
]


def test_a_false_start_is_removed_even_though_no_word_records_it():
    """
    The defect: three audible fluffs opened the first cut. Every check passed, because every
    check read the transcript and the transcript had no idea they were there.
    """
    dead = S2.find_dead_air(STUMBLE_WORDS, duration=93.0, voiced=STUMBLE_VOICED)
    culprit = [d for d in dead if "false start" in d["reason"]]
    assert culprit, "voiced audio inside a word gap was still classified as dead air"
    d = culprit[0]
    assert d["start"] <= 89.01 and d["end"] >= 89.72, "the false starts survived the trim"


def test_the_transcript_alone_cannot_see_it():
    """Guards the fix, not the symptom: without the audio there is nothing to find."""
    dead = S2.find_dead_air(STUMBLE_WORDS, duration=93.0, voiced=None)
    assert not [d for d in dead if "false start" in d["reason"]]


def test_a_clipped_word_onset_is_not_mistaken_for_a_stumble():
    """
    WhisperX routinely starts a word late. The voiced run at 89.98 is the "H" of "Hi," — cutting
    to the transcript boundary would clip the consonant off the front of her line.
    """
    dead = S2.find_dead_air(STUMBLE_WORDS, duration=93.0, voiced=STUMBLE_VOICED)
    for d in (x for x in dead if x["start"] < 90.13):     # the gap ahead of "Hi," only
        assert d["end"] <= 89.98, f"trim to {d['end']:.2f}s eats the onset of 'Hi,'"


def test_the_breath_does_not_walk_the_take_back_over_a_false_start():
    """
    Second site of the same blindness: the take reaches backwards to collect its own breath,
    and the floor it stops at was the last *word*, so it stepped straight back over the fluffs
    find_dead_air had just removed and put them back in the cut.
    """
    keeps = [S2.Keep(88.55, 89.86), S2.Keep(89.86, 92.97)]
    out = S2.collapse_breath_runs(keeps, STUMBLE_WORDS, STUMBLE_VOICED)
    assert out[0].start >= 89.72, (
        f"take opens at {out[0].start:.2f}s, back inside the false start at 89.64s"
    )


def test_an_unmeasured_cut_never_reports_itself_as_clean():
    """"Not checked" and "checked, none found" must not share a representation."""
    meta = {"clip": "x.MOV", "source": "footage/x.MOV", "duration": 93.0}
    assert S2.build_edl(meta, STUMBLE_WORDS, False).stats["audio_checked"] is False
    assert S2.build_edl(meta, STUMBLE_WORDS, False,
                        voiced=STUMBLE_VOICED).stats["audio_checked"] is True


# --------------------------------------------------------------------------------------
# A take can hide inside one transcribed word  [S-026]
# --------------------------------------------------------------------------------------

# WhisperX gave the intro a single token — "I'm" — spanning 2.0s and four voiced bursts. The
# audio is "I'm Katie, I'm a foo—". The transcript is one short word, so the script read clean.
BURIED_WORDS = [
    {"word": "Hi,", "start": 90.13, "end": 90.37},
    {"word": "I'm", "start": 90.97, "end": 92.97},
    {"word": "Katie,", "start": 93.01, "end": 93.27},
]
BURIED_VOICED = [(90.96, 91.15), (91.31, 91.44), (92.48, 92.56), (92.86, 93.28)]


def test_a_take_buried_inside_one_word_is_found():
    """
    The defect Nathan heard: "I'm Katie I'm a foo— Hi I'm Katie and I'm a food scientist."
    Nothing caught it, because every check read the transcript and the transcript said "I'm".
    """
    buried = S2.find_buried_takes(BURIED_WORDS, BURIED_VOICED)
    assert len(buried) == 1, "a 2.0s 'I'm' holding four voiced bursts was accepted as a word"
    d = buried[0]
    assert d["start"] == pytest.approx(90.97)
    # she restarts and then delivers, so the real word is the last burst — keep it
    assert 92.6 < d["end"] <= 92.86, f"trim to {d['end']:.2f}s does not leave the actual word"


def test_a_drawn_out_word_is_not_a_buried_take():
    """She leans on a word for emphasis. One continuous burst is a word, however long."""
    words = [{"word": "yeeeast", "start": 10.0, "end": 11.6}]
    assert S2.find_buried_takes(words, [(10.0, 11.6)]) == []


def test_a_buried_take_is_invisible_without_the_audio():
    assert S2.find_buried_takes(BURIED_WORDS, None) == []


# --------------------------------------------------------------------------------------
# Reading back the cut itself  [S-026]
# --------------------------------------------------------------------------------------

def test_the_same_short_line_twice_is_caught():
    """
    RETAKE_RUN_WORDS is 6, so the verbatim-run check could not see "I'm Katie." twice — four
    words in total and unmistakably a defect. The read-back reported it and nothing acted.
    """
    lines = [
        {"start": 0.2, "end": 1.0, "words": 2, "text": "I'm Katie."},
        {"start": 2.1, "end": 3.0, "words": 2, "text": "I'm Katie."},
    ]
    assert S2.duplicate_lines(lines), "the same line twice in a row read as clean"
    assert S2.read_through(lines), "read_through did not inherit the duplicate check"


def test_what_the_readback_heard_is_mapped_back_to_source_time():
    """
    The read-back is timed on the cut; drops are in source time. Skipping that conversion is
    the bug CLAUDE.md warns about twice over — it would cut a perfectly good moment instead.
    """
    edl = S2.EDL(clip="x.MOV", source="footage/x.MOV", fps=C.FPS,
                 keeps=[S2.Keep(10.0, 12.0), S2.Keep(20.0, 25.0)], drops=[])
    heard = [
        {"start": 0.2, "end": 1.0, "words": 2, "text": "I'm Katie."},
        {"start": 2.1, "end": 3.0, "words": 2, "text": "I'm Katie."},
    ]
    drops = S2.drops_from_readback(edl, heard)
    assert len(drops) == 1, "the duplicate was not turned into a drop"
    # timeline 0.2-1.0 lives at source 10.2-11.0, not at 0.2-1.0
    assert drops[0]["start"] == pytest.approx(10.2)
    assert drops[0]["end"] == pytest.approx(11.0)


def test_the_earlier_of_a_duplicated_pair_is_the_one_that_goes():
    """Matches the keeper rule everywhere else in this file: she restarts, then delivers."""
    edl = S2.EDL(clip="x.MOV", source="footage/x.MOV", fps=C.FPS,
                 keeps=[S2.Keep(0.0, 10.0)], drops=[])
    heard = [
        {"start": 1.0, "end": 2.0, "words": 2, "text": "I'm Katie."},
        {"start": 3.0, "end": 4.0, "words": 2, "text": "I'm Katie."},
    ]
    assert S2.drops_from_readback(edl, heard)[0]["start"] == pytest.approx(1.0)


def test_extra_drops_survive_the_target_tightening_pass():
    """A second build for a length target must not quietly discard what the read-back found."""
    meta = {"clip": "x.MOV", "source": "footage/x.MOV", "duration": 20.0}
    words = [{"word": "one", "start": 1.0, "end": 1.4},
             {"word": "two.", "start": 8.0, "end": 8.4},
             {"word": "three.", "start": 15.0, "end": 15.4}]
    extra = [{"start": 8.0, "end": 8.4, "reason": "heard twice on read-back", "text": "two."}]
    edl = S2.build_edl(meta, words, False, target_seconds=1.0, extra_drops=extra)
    assert any("read-back" in d.reason for d in edl.drops)

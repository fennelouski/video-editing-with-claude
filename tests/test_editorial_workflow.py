"""Synthetic source/verdict fixtures; no model, media, NAS or GUI calls."""
import copy
from concurrent.futures import ThreadPoolExecutor
import json

import pytest

import editorial_workflow as E


@pytest.fixture
def sources():
    return [E.TranscriptSource("camera-a", E.sha256(b"synthetic camera A"), 5, [
        {"word": "Let", "start": 1, "end": 1.2},
        {"word": "the", "start": 1.25, "end": 1.4},
        {"word": "dough", "start": 1.4, "end": 1.9},
        {"word": "rest.", "start": 2, "end": 2.4},
    ]), E.TranscriptSource("camera-b", E.sha256(b"synthetic camera B"), 2, [
        {"word": "Shape", "start": .1, "end": .5},
        {"word": "it.", "start": .55, "end": .7},
    ])]


@pytest.fixture
def script(sources):
    return {"schema_version": 1, "title": "Synthetic dough", "sections": [
        {"title": "Rest", "segments": [{"source_id": sources[0].source_id,
          "source_sha256": sources[0].source_sha256, "first_word": 0, "last_word": 3,
          "spoken_text": "Let the dough rest."}]},
        {"title": "Shape", "segments": [{"source_id": sources[1].source_id,
          "source_sha256": sources[1].source_sha256, "first_word": 0, "last_word": 1}]},
    ]}


def receipt(validated, role, number=1, decision="agree", issues=None, session=None):
    return E.ReviewReceipt.from_artifact(session or role, f"{role}-{number}", {
        "decision": decision, "script_sha256": validated.script_sha256,
        "issues": [] if issues is None else issues,
    })


def record(ledger, validated, number=1, writer_decision="agree", reviewer_decision="agree", issues=None):
    return ledger.append_round(validated, writer=receipt(validated, "writer", number, writer_decision),
                               reviewer=receipt(validated, "reviewer", number, reviewer_decision, issues), round_id=f"round-{number}")


def opened(tmp_path, sources, limit=10):
    ledger = E.RoundLedger.create(tmp_path / "ledger", max_rounds=limit)
    ledger.complete_transcripts(sources)
    return ledger


def test_exact_source_trace_and_exact_byte_identity(sources, script):
    raw = json.dumps(script, indent=2).encode()
    result = E.validate_script(raw, sources)
    assert result.script_sha256 == E.sha256(raw)
    assert result.script_sha256 != E.validate_script(script, sources).script_sha256
    assert result.segments[0].quoted_words == ("Let", "the", "dough", "rest.")
    assert (result.segments[0].first_word, result.segments[0].last_word) == (0, 3)
    assert (result.segments[0].start, result.segments[0].end) == (1, 2.4)
    assert result.segments[1].source_id == "camera-b"
    assert result.segments[1].spoken_text == "Shape it."
    assert result.segments[0].transcript_sha256 == sources[0].transcript_sha256
    assert json.loads(json.dumps(result.to_dict())) == result.to_dict()


def test_script_duration_is_conservative_and_does_not_invent_padding(sources, script):
    validated = E.validate_script(script, sources)
    projection = E.script_duration_projection(validated, sources, end_card_seconds=10)
    assert projection['projection_only'] and not projection['source_audio_boundaries_verified']
    assert projection['invented_nonverbal_seconds'] == 0
    assert projection['finished_estimate_seconds'] < 13
    with pytest.raises(E.EditorialError, match='below the 480'):
        E.check_script_duration(projection, 480)
    E.check_script_duration(projection, 8)
    with pytest.raises(E.EditorialError, match='exact reviewed source'):
        E.script_duration_projection(validated, [E.TranscriptSource('camera-a', E.sha256(b'changed'), 5, sources[0].words), sources[1]])


def test_stretched_asr_token_cannot_make_a_short_script_pass_eight_minutes():
    source = E.TranscriptSource('synthetic-a', E.sha256(b'synthetic'), 900, [{'word':'It','start':0,'end':700}])
    script = E.validate_script({'sections':[{'segments':[{'source_id':source.source_id,'source_sha256':source.source_sha256,'first_word':0,'last_word':0}]}]}, [source])
    projection = E.script_duration_projection(script, [source])
    assert projection['source_span_seconds'] == 700
    assert projection['finished_estimate_seconds'] == 10.45
    with pytest.raises(E.EditorialError, match='Duration review required'):
        E.check_script_duration(projection, 480)


def test_split_contiguous_words_and_section_joins_cannot_invent_duration():
    source = E.TranscriptSource("synthetic-a", E.sha256(b"synthetic"), 331, [
        {"word": "dough", "start": i * .3, "end": (i + 1) * .3} for i in range(1100)
    ])
    segments = [{"source_id": source.source_id, "source_sha256": source.source_sha256,
                 "first_word": i, "last_word": i} for i in range(1100)]
    split = E.validate_script({"sections": [{"segments": segments[:550]}, {"segments": segments[550:]}]}, [source])
    joined = E.validate_script({"sections": [{"segments": [
        {**segments[0], "last_word": 1099}
    ]}]}, [source])
    projection = E.script_duration_projection(split, [source])
    assert projection["source_span_seconds"] == pytest.approx(330)
    assert projection["finished_estimate_seconds"] == pytest.approx(340)
    assert projection["finished_estimate_seconds"] == pytest.approx(E.script_duration_projection(joined, [source])["finished_estimate_seconds"])
    assert projection["unverified_pause_seconds_credited"] == 0
    with pytest.raises(E.EditorialError, match="below the 480"):
        E.check_script_duration(projection, 480)


def test_overlapping_asr_tokens_cannot_inflate_articulation_or_pass_minimum():
    source = E.TranscriptSource("synthetic-a", E.sha256(b"synthetic"), 2, [
        {"word": "dough", "start": i * .001, "end": i * .001 + .45} for i in range(1100)
    ])
    script = E.validate_script({"sections": [{"segments": [
        {"source_id": source.source_id, "source_sha256": source.source_sha256, "first_word": 0, "last_word": 1099}
    ]}]}, [source])
    projection = E.script_duration_projection(script, [source])
    assert projection["source_span_seconds"] == pytest.approx(1.549)
    assert projection["repaired_narration_estimate_seconds"] == pytest.approx(1.549)
    with pytest.raises(E.EditorialError, match="below the 480"):
        E.check_script_duration(projection, 480)


@pytest.mark.parametrize("pause", [.1, 3])
def test_interword_pauses_are_not_credited_without_audio_evidence(pause):
    source = E.TranscriptSource("synthetic-a", E.sha256(b"synthetic"), 5, [
        {"word": "Make", "start": .1, "end": .5},
        {"word": "pizza.", "start": .5 + pause, "end": .9 + pause},
    ])
    script = E.validate_script({"sections": [{"segments": [
        {"source_id": source.source_id, "source_sha256": source.source_sha256, "first_word": 0, "last_word": 1}
    ]}]}, [source])
    projection = E.script_duration_projection(script, [source])
    assert projection["repaired_narration_estimate_seconds"] == pytest.approx(.8)
    assert projection["finished_estimate_seconds"] == pytest.approx(10.8)
    assert projection["source_span_seconds"] == pytest.approx(.8 + pause)


def test_overlapping_stretched_tokens_retain_caps_without_bridging_a_gap():
    source = E.TranscriptSource("synthetic-a", E.sha256(b"synthetic"), 900, [
        {"word": "It", "start": 0, "end": 700},
        {"word": "is", "start": .1, "end": 700.2},
        {"word": "done", "start": 800, "end": 800.3},
    ])
    script = E.validate_script({"sections": [{"segments": [
        {"source_id": source.source_id, "source_sha256": source.source_sha256, "first_word": 0, "last_word": 2}
    ]}]}, [source])
    projection = E.script_duration_projection(script, [source])
    assert projection["source_span_seconds"] == pytest.approx(800.3)
    assert projection["repaired_narration_estimate_seconds"] == pytest.approx(.85)
    with pytest.raises(E.EditorialError, match="below the 480"):
        E.check_script_duration(projection, 480)


def test_duration_projection_binds_unused_and_silent_catalog_sources(sources, script):
    silent = E.TranscriptSource("silent-broll", E.sha256(b"silent"), 12, [])
    validated = E.validate_script(script, sources + [silent])
    changed = E.TranscriptSource(silent.source_id, silent.source_sha256, 13, [])
    with pytest.raises(E.EditorialError, match="exact reviewed source catalog"):
        E.script_duration_projection(validated, sources + [changed])
    changed_words = E.TranscriptSource(sources[0].source_id, sources[0].source_sha256, sources[0].duration,
                                       [{**word.to_dict(), "word": "Changed"} for word in sources[0].words])
    with pytest.raises(E.EditorialError, match="exact reviewed source catalog"):
        E.script_duration_projection(validated, [changed_words, sources[1], silent])


def test_sufficient_actual_word_articulation_passes_planning_minimum():
    source = E.TranscriptSource("synthetic-a", E.sha256(b"synthetic"), 500, [
        {"word": "dough", "start": i * .5, "end": (i + 1) * .5} for i in range(1000)
    ])
    script = E.validate_script({"sections": [{"segments": [
        {"source_id": source.source_id, "source_sha256": source.source_sha256, "first_word": 0, "last_word": 999}
    ]}]}, [source])
    projection = E.script_duration_projection(script, [source])
    assert projection["finished_estimate_seconds"] == pytest.approx(510)
    E.check_script_duration(projection, 480)
    assert projection["projection_only"] and projection["final_rendered_file_duration_check_required"]


def test_replayed_source_word_cannot_supply_the_minimum_deficit():
    source = E.TranscriptSource("synthetic-a", E.sha256(b"synthetic"), 1, [
        {"word": "dough", "start": 0, "end": .5},
    ])
    segment = {"source_id": source.source_id, "source_sha256": source.source_sha256, "first_word": 0, "last_word": 0}
    script = E.validate_script({"sections": [{"segments": [segment] * 500}, {"segments": [segment] * 500}]}, [source])
    projection = E.script_duration_projection(script, [source])
    assert projection["selected_words"] == 1000
    assert projection["source_span_seconds"] == 500
    assert projection["selected_articulation_seconds"] == 500
    assert projection["replay_articulation_seconds_not_credited"] == 499.5
    assert projection["finished_estimate_seconds"] == 10.5
    with pytest.raises(E.EditorialError, match="below the 480"):
        E.check_script_duration(projection, 480)


def test_alias_source_ids_share_credit_but_distinct_physical_sources_do_not():
    words = [{"word": "dough", "start": .1, "end": .6}]
    original = E.TranscriptSource("original", E.sha256(b"original bytes"), 1, words)
    alias = E.TranscriptSource("copied-file", original.source_sha256, 1, words)
    distinct = E.TranscriptSource("different-take", E.sha256(b"different bytes"), 1, words)
    segments = [{"source_id": source.source_id, "source_sha256": source.source_sha256, "first_word": 0, "last_word": 0}
                for source in (original, alias, distinct)]
    sources = [original, alias, distinct]
    script = E.validate_script({"sections": [{"segments": segments}]}, sources)
    projection = E.script_duration_projection(script, sources)
    assert projection["selected_words"] == 3
    assert projection["source_span_seconds"] == pytest.approx(1.5)
    assert projection["selected_articulation_seconds"] == pytest.approx(1.5)
    assert projection["repaired_narration_estimate_seconds"] == pytest.approx(1)
    assert projection["replay_articulation_seconds_not_credited"] == pytest.approx(.5)
    assert projection["finished_estimate_seconds"] == pytest.approx(11)


@pytest.mark.parametrize("alias_id", [False, True])
@pytest.mark.parametrize("reverse_order", [False, True])
def test_partially_overlapping_segments_credit_original_time_once(alias_id, reverse_order):
    original = E.TranscriptSource("original", E.sha256(b"original bytes"), 3, [
        {"word": "dough", "start": i * .5, "end": (i + 1) * .5} for i in range(6)
    ])
    alias = E.TranscriptSource("copied-file", original.source_sha256, original.duration, original.words)
    second_source = alias if alias_id else original
    segments = [
        {"source_id": original.source_id, "source_sha256": original.source_sha256, "first_word": 0, "last_word": 3},
        {"source_id": second_source.source_id, "source_sha256": second_source.source_sha256, "first_word": 2, "last_word": 5},
    ]
    if reverse_order: segments.reverse()
    sources = [original, alias]
    script = E.validate_script({"sections": [{"segments": segments}]}, sources)
    projection = E.script_duration_projection(script, sources)
    assert projection["selected_words"] == 8
    assert projection["source_span_seconds"] == 4
    assert projection["selected_articulation_seconds"] == 4
    assert projection["repaired_narration_estimate_seconds"] == 3
    assert projection["replay_articulation_seconds_not_credited"] == 1
    assert projection["finished_estimate_seconds"] == 13


def test_editorial_metadata_is_preserved_but_not_spoken(sources, script):
    script.update(purpose="A concise demonstration", join_notes=["Keep the breath"], notes="Unspoken editorial notes")
    script["sections"][0]["purpose"] = "Set up the action"
    script["sections"][0]["join_notes"] = "The next shot shows shaping"
    script["sections"][0]["segments"][0]["join_notes"] = "Match action"
    result = E.validate_script(script, sources)
    assert result.segments[0].spoken_text == "Let the dough rest."
    assert b'Match action' in result.script_json


@pytest.mark.parametrize("change,match", [
    ({"source_id": "missing"}, "Unknown source"),
    ({"source_sha256": E.sha256(b"different media")}, "Stale source"),
    ({"transcript_sha256": E.sha256(b"old words")}, "Stale transcript"),
    ({"spoken_text": "Let the dough rest for exactly two hours."}, "fabricated/replacement"),
    ({"spoken_text": "[PICKUP: explain the reaction]"}, "exact supplied words"),
    ({"spoken_text": "let the dough rest."}, "exact supplied words"),
    ({"first_word": -1}, "inclusive"),
    ({"first_word": 3, "last_word": 1}, "inclusive"),
    ({"first_word": 0.0}, "inclusive"),
    ({"first_word": True}, "inclusive"),
    ({"last_word": 4}, "inclusive"),
    ({"last_word": None}, "inclusive"),
    ({"start_seconds": 0}, "unsupported fields"),
    ({"pickup": "say a better sentence"}, "unsupported fields"),
])
def test_spoken_selection_rejections(sources, script, change, match):
    script["sections"][0]["segments"][0].update(change)
    with pytest.raises(E.EditorialError, match=match): E.validate_script(script, sources)


@pytest.mark.parametrize("start,end", [(float("nan"), 1), (0, float("inf")), (0, 8), (-1, 1), (1, 0), (1, 1), (False, 1)])
def test_invalid_timestamps_are_refused(start, end):
    with pytest.raises(E.EditorialError):
        E.TranscriptSource("invalid", E.sha256(b"fixture"), 5, [{"word": "A", "start": start, "end": end}])


def test_word_order_overlap_and_silent_sources(sources, script, tmp_path):
    with pytest.raises(E.EditorialError, match="out of order"):
        E.TranscriptSource("backwards", E.sha256(b"fixture"), 5, [
            {"word": "A", "start": 2, "end": 3}, {"word": "B", "start": 1, "end": 2}])
    overlapping = E.TranscriptSource("overlap", E.sha256(b"fixture"), 5, [
        {"word": "A", "start": 1, "end": 2}, {"word": "B", "start": 1.9, "end": 3}])
    assert overlapping.words[1].start == 1.9
    silent = E.TranscriptSource("silent-broll", E.sha256(b"silent fixture"), 12, [])
    opened(tmp_path, sources + [silent])
    assert E.validate_script(script, sources + [silent]).segments
    script["sections"][0]["segments"][0].update(source_id=silent.source_id, source_sha256=silent.source_sha256)
    with pytest.raises(E.EditorialError, match="inclusive"): E.validate_script(script, sources + [silent])


def test_source_catalog_alias_duplicates_and_pickup_markers(sources, script):
    with pytest.raises(E.EditorialError, match="duplicate IDs"): E.validate_script(script, sources + [sources[0]])
    with pytest.raises(E.EditorialError, match="catalog keys"): E.validate_script(script, {"other": sources[0]})
    marked = E.TranscriptSource("pickup", E.sha256(b"placeholder"), 1, [{"word": "[PICKUP]", "start": 0, "end": .5}])
    value = {"sections": [{"segments": [{"source_id": "pickup", "source_sha256": marked.source_sha256, "first_word": 0, "last_word": 0}]}]}
    with pytest.raises(E.EditorialError, match="pickup placeholder"): E.validate_script(value, [marked])


@pytest.mark.parametrize("payload", ['{"sections":[],"sections":[]}', '{"sections":[],"purpose":NaN}', '{"sections":[],"purpose":1e309}', '[]'])
def test_ambiguous_or_nonfinite_json_cannot_be_evidence(sources, payload):
    with pytest.raises(E.EditorialError): E.validate_script(payload, sources)


@pytest.mark.parametrize("category", ["pickups", "coverage_gaps", "fact_flags"])
def test_unresolved_critical_issues_gate_picture_even_if_both_agents_agree(sources, script, tmp_path, category):
    script[category] = [{"id": "unresolved", "description": "Needs separate evidence"}]
    validated = E.validate_script(script, sources)
    assert len(validated.unresolved_critical) == 1
    ledger = opened(tmp_path, sources)
    result = record(ledger, validated)
    assert not result["approved"] and result["unresolved_critical"][0]["category"] == category
    with pytest.raises(E.EditorialError, match="both sessions"):
        ledger.advance(E.Stage.PICTURE_DIALOGUE, artifact_sha256=E.sha256(b"picture"), script_sha256=validated.script_sha256)


def test_fact_resolution_requires_human_and_pickup_cannot_be_downgraded(sources, script):
    script["fact_flags"] = [{"id": "fact", "description": "Verify a scientific mechanism", "status": "resolved",
                             "resolution": "Supplied human clarification", "resolved_by": "writer"}]
    with pytest.raises(E.EditorialError, match="human resolution"): E.validate_script(script, sources)
    script["fact_flags"][0]["resolved_by"] = "human"
    assert E.validate_script(script, sources).unresolved_critical  # A model annotation authenticates no human.
    script["pickups"] = [{"id": "pickup", "description": "Missing recorded words", "severity": "warning"}]
    assert E.validate_script(script, sources).unresolved_critical[0].category == "pickups"


def test_revision_approval_reload_and_immutable_records(sources, script, tmp_path):
    ledger = opened(tmp_path, sources)
    first = E.validate_script(script, sources)
    result = record(ledger, first, reviewer_decision="revise", issues=[{"id": "join", "description": "Abrupt join"}])
    assert not result["approved"] and result["round_count"] == 1
    immutable = {p.name: p.read_bytes() for p in (ledger.path / "events").iterdir()}
    revised = copy.deepcopy(script); revised["sections"][0]["segments"][0]["first_word"] = 1
    revised["sections"][0]["segments"][0]["spoken_text"] = "the dough rest."
    second = E.validate_script(revised, sources)
    result = record(E.RoundLedger.load(ledger.path), second, 2, issues=[{
        "id": "join", "description": "Abrupt join", "status": "resolved",
        "resolution": "The selected source-bound revision removes the abrupt lead-in.", "resolved_by": "reviewer"}])
    assert result["approved"] and result["approved_script_sha256"] == second.script_sha256
    assert E.RoundLedger.load(ledger.path).summary() == result
    assert all((ledger.path / "events" / name).read_bytes() == raw for name, raw in immutable.items())
    with pytest.raises(E.EditorialError, match="approved script is immutable"): record(ledger, second, 3)
    json.dumps(result, allow_nan=False)


def test_ten_real_disagreements_exhaust_without_approval(sources, script, tmp_path):
    ledger = opened(tmp_path, sources)
    validated = E.validate_script(script, sources)
    for number in range(1, 11):
        result = record(ledger, validated, number, reviewer_decision="revise")
        assert not result["approved"]
    assert result["round_count"] == 10 and result["exhausted_without_approval"]
    assert result["approved_script_sha256"] is None
    with pytest.raises(E.EditorialError, match="round limit"): record(ledger, validated, 11)
    with pytest.raises(E.EditorialError, match="both sessions"):
        ledger.advance(E.Stage.PICTURE_DIALOGUE, artifact_sha256=E.sha256(b"cut"), script_sha256=validated.script_sha256)
    assert E.RoundLedger.load(ledger.path).summary()["exhausted_without_approval"]


def test_omitting_or_downgrading_an_earlier_issue_never_resolves_it(sources, script, tmp_path):
    ledger = opened(tmp_path, sources); validated = E.validate_script(script, sources)
    record(ledger, validated, reviewer_decision="revise", issues=[{"id": "gap", "description": "The middle step is missing"}])
    result = record(ledger, validated, 2)
    assert not result["approved"] and result["unresolved_critical"][0]["id"] == "gap"
    result = record(ledger, validated, 3, issues=[{"id": "gap", "description": "Ignore the middle step", "severity": "warning"}])
    assert not result["approved"]
    result = record(ledger, validated, 4, issues=[{"id": "gap", "description": "The middle step is missing", "status": "resolved",
                                              "resolution": "The actual selected dialogue contains the prerequisite.", "resolved_by": "reviewer"}])
    assert result["approved"]


def test_deleted_science_flag_stays_blocked_until_explicit_human_resolution(sources, script, tmp_path):
    script["fact_flags"] = [{"id": "science", "description": "Check this claim with the host"}]
    ledger = opened(tmp_path, sources); first = E.validate_script(script, sources)
    assert not record(ledger, first)["approved"]
    del script["fact_flags"]
    revised = E.validate_script(script, sources)
    assert not record(ledger, revised, 2)["approved"]
    script["fact_flags"] = [{"id": "science", "description": "Check this claim with the host", "status": "resolved",
                             "resolution": "Host supplied the reviewed correction.", "resolved_by": "human"}]
    final = E.validate_script(script, sources)
    assert not record(ledger, final, 3)["approved"]
    approval = E.HumanFactApproval("science", "actual-human-input-receipt", final.script_sha256, b"Synthetic human input approving this specific reviewed fact.")
    result = ledger.append_round(final, writer=receipt(final, "writer", 4), reviewer=receipt(final, "reviewer", 4),
                                 round_id="round-4", human_fact_approvals=[approval])
    assert result["approved"] and result["human_fact_approvals"][0]["artifact_sha256"] == E.sha256(approval.artifact)


def test_human_fact_evidence_cannot_be_a_model_field_or_a_stale_approval(sources, script, tmp_path):
    script["fact_flags"] = [{"id": "fact", "description": "Check the numeric claim", "status": "resolved",
                             "resolution": "Synthetic recorded human clarification.", "resolved_by": "human"}]
    validated = E.validate_script(script, sources); ledger = opened(tmp_path, sources)
    assert not record(ledger, validated)["approved"]
    approval = E.HumanFactApproval("fact", "human-receipt", E.sha256(b"another version"), "Synthetic actual human-input boundary evidence")
    with pytest.raises(E.EditorialError, match="exact script SHA"):
        ledger.append_round(validated, writer=receipt(validated, "writer", 2), reviewer=receipt(validated, "reviewer", 2),
                            round_id="stale-human", human_fact_approvals=[approval])
    with pytest.raises(E.EditorialError, match="Do not infer human authority"):
        ledger.append_round(validated, writer=receipt(validated, "writer", 2), reviewer=receipt(validated, "reviewer", 2),
                            round_id="model-human-field", human_fact_approvals=[{"resolved_by": "human"}])


def test_reviewer_human_label_cannot_claim_or_later_downgrade_authority(sources, script, tmp_path):
    ledger = opened(tmp_path, sources); validated = E.validate_script(script, sources)
    issue = {"id": "credential", "description": "Verify the credential", "status": "resolved",
             "resolution": "A model says the human approved it", "resolved_by": "human"}
    first = record(ledger, validated, issues=[issue])
    assert not first["approved"] and first["unresolved_critical"][0]["awaiting_human_approval"]
    issue["resolved_by"] = "reviewer"
    assert not record(ledger, validated, 2, issues=[issue])["approved"]
    actual = E.HumanFactApproval("credential", "human-input", validated.script_sha256, b"Synthetic real human-input boundary confirms the credential wording.")
    result = ledger.append_round(validated, writer=receipt(validated, "writer", 3),
                                 reviewer=receipt(validated, "reviewer", 3, issues=[issue]),
                                 round_id="round-3", human_fact_approvals=[actual])
    assert result["approved"]


def test_agreement_on_final_allowed_round_is_approval(sources, script, tmp_path):
    ledger = opened(tmp_path, sources, limit=2); validated = E.validate_script(script, sources)
    record(ledger, validated, reviewer_decision="revise")
    result = record(ledger, validated, 2)
    assert result["approved"] and not result["exhausted_without_approval"]


@pytest.mark.parametrize("limit", [0, 11, True, 2.5, "10"])
def test_round_cap_validation(tmp_path, limit):
    with pytest.raises(E.EditorialError, match="1 through 10"): E.RoundLedger.create(tmp_path / "invalid", limit)
    assert not (tmp_path / "invalid").exists()


def test_sessions_and_receipts_are_independent_unique_and_script_specific(sources, script, tmp_path):
    ledger = opened(tmp_path, sources); validated = E.validate_script(script, sources)
    with pytest.raises(E.EditorialError, match="independent actual sessions"):
        ledger.append_round(validated, writer=receipt(validated, "writer"), reviewer=receipt(validated, "reviewer", session="writer"), round_id="same-session")
    record(ledger, validated, reviewer_decision="revise")
    for writer, reviewer, round_id, match in [
        (receipt(validated, "writer", 2, session="reviewer"), receipt(validated, "new-reviewer", 2), "roles-swapped", "roles cannot"),
        (receipt(validated, "writer", 2), receipt(validated, "reviewer"), "reused-receipt", "unique identity"),
        (receipt(validated, "writer", 2), receipt(validated, "reviewer", 2), "round-1", "Round IDs"),
    ]:
        with pytest.raises(E.EditorialError, match=match):
            ledger.append_round(validated, writer=writer, reviewer=reviewer, round_id=round_id)
    old = E.ReviewReceipt.from_artifact("reviewer", "reviewer-2", {"decision": "agree", "script_sha256": E.sha256(b"different script"), "issues": []})
    with pytest.raises(E.EditorialError, match="stale agreement"):
        ledger.append_round(validated, writer=receipt(validated, "writer", 2), reviewer=old, round_id="stale")
    assert ledger.summary()["round_count"] == 1


@pytest.mark.parametrize("verdict", [
    {"decision": "partial", "script_sha256": E.sha256(b"script"), "issues": []},
    {"decision": "agree", "script_sha256": E.sha256(b"script"), "issues": "unreviewed"},
    {"decision": "agree", "issues": []},
    {"decision": True, "script_sha256": E.sha256(b"script"), "issues": []},
])
def test_partial_unknown_or_missing_verdicts_do_not_approve(verdict):
    with pytest.raises(E.EditorialError): E.ReviewReceipt.from_artifact("writer", "receipt", verdict)


def test_current_catalog_is_required_even_when_original_media_hash_unchanged(sources, script, tmp_path):
    ledger = opened(tmp_path, sources)
    changed = sources[0].to_dict(); changed["words"][0]["word"] = "Allow"
    new_sources = [E.TranscriptSource.from_dict(changed), sources[1]]
    del script["sections"][0]["segments"][0]["spoken_text"]
    validated = E.validate_script(script, new_sources)
    with pytest.raises(E.EditorialError, match="transcript catalog changed"):
        record(ledger, validated)
    assert ledger.summary()["round_count"] == 0


def test_stage_order_exact_script_and_horizontal_tail(sources, script, tmp_path):
    ledger = E.RoundLedger.create(tmp_path / "ledger"); validated = E.validate_script(script, sources)
    with pytest.raises(E.EditorialError, match="before picture editing"): record(ledger, validated)
    ledger.complete_transcripts(sources)
    with pytest.raises(E.EditorialError, match="before script work"): ledger.complete_transcripts(sources)
    record(ledger, validated)
    for next_stage in [E.Stage.MUSIC, E.Stage.GRAPHICS, E.Stage.FINAL]:
        with pytest.raises(E.EditorialError, match="no bypass"):
            ledger.advance(next_stage, artifact_sha256=E.sha256(b"asset"), script_sha256=validated.script_sha256)
    with pytest.raises(E.EditorialError, match="exact script SHA"):
        ledger.advance(E.Stage.PICTURE_DIALOGUE, artifact_sha256=E.sha256(b"cut"), script_sha256=E.sha256(b"another script"))
    for stage in [E.Stage.PICTURE_DIALOGUE, E.Stage.MUSIC, E.Stage.GRAPHICS]:
        ledger.advance(stage, artifact_sha256=E.sha256(stage.value), script_sha256=validated.script_sha256)
    for tail in [None, 9.99, float("nan"), True]:
        with pytest.raises(E.EditorialError):
            ledger.advance(E.Stage.FINAL, artifact_sha256=E.sha256(b"final"), script_sha256=validated.script_sha256, aspect="16:9", end_card_seconds=tail)
    result = ledger.advance(E.Stage.FINAL, artifact_sha256=E.sha256(b"final"), script_sha256=validated.script_sha256, aspect="16:9", end_card_seconds=10)
    assert result["stage"] == "final"
    assert [item["stage"] for item in result["stage_artifacts"]] == ["picture_dialogue", "music", "graphics", "final"]
    with pytest.raises(E.EditorialError, match="no bypass"):
        ledger.advance(E.Stage.FINAL, artifact_sha256=E.sha256(b"final"), script_sha256=validated.script_sha256, aspect="16:9", end_card_seconds=10)
    assert E.RoundLedger.load(ledger.path).summary()["stage"] == "final"


def test_vertical_tail_exemption():
    E.validate_end_card("9:16", None)
    E.validate_end_card("9:16", 0)
    with pytest.raises(E.EditorialError): E.validate_end_card("9:16", -1)
    with pytest.raises(E.EditorialError): E.validate_end_card("unknown", 20)


def test_append_failure_preserves_records_and_resume(sources, script, tmp_path, monkeypatch):
    ledger = opened(tmp_path, sources); validated = E.validate_script(script, sources)
    before = {p.name: p.read_bytes() for p in (ledger.path / "events").iterdir()}
    actual_publish = E._publish_exclusive
    def refused(*args, **kwargs): raise OSError("synthetic interrupted publication")
    monkeypatch.setattr(E, "_publish_exclusive", refused)
    with pytest.raises(OSError, match="interrupted"): record(ledger, validated)
    assert {p.name: p.read_bytes() for p in (ledger.path / "events").iterdir()} == before
    assert not ledger.summary()["approved"]
    monkeypatch.setattr(E, "_publish_exclusive", actual_publish)
    assert record(E.RoundLedger.load(ledger.path), validated)["approved"]


def test_changed_journal_and_symlink_records_are_refused(sources, script, tmp_path):
    ledger = opened(tmp_path, sources); record(ledger, E.validate_script(script, sources))
    latest = ledger.path / "events/0002.json"
    value = json.loads(latest.read_bytes()); value["payload"]["writer"]["session_id"] = "forged-writer"
    original = latest.read_bytes(); latest.write_bytes(E.canonical_json(value))
    with pytest.raises(E.EditorialError, match="event changed"): E.RoundLedger.load(ledger.path)
    latest.write_bytes(original)
    outside = tmp_path / "outside.json"; outside.write_bytes(original); latest.unlink(); latest.symlink_to(outside)
    with pytest.raises(E.EditorialError, match="symbolic-link"): E.RoundLedger.load(ledger.path)
    with pytest.raises(E.EditorialError, match="fresh ledger"): E.RoundLedger.create(ledger.path)


def test_concurrent_completed_rounds_remain_unique(sources, script, tmp_path):
    ledger = opened(tmp_path, sources); validated = E.validate_script(script, sources)
    def append(number):
        return record(E.RoundLedger.load(ledger.path), validated, number, reviewer_decision="revise")
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(append, [1, 2]))
    final = ledger.summary()
    assert final["round_count"] == 2 and not final["approved"]
    assert [r["number"] for r in final["rounds"]] == [1, 2]
    assert {r["round_id"] for r in final["rounds"]} == {"round-1", "round-2"}


def test_loaded_ledger_refuses_replaced_storage_before_writing(sources, script, tmp_path):
    ledger = opened(tmp_path, sources); validated = E.validate_script(script, sources)
    original = tmp_path / "preserved-ledger"; ledger.path.rename(original)
    outside = tmp_path / "unrelated-storage"; outside.mkdir(); ledger.path.symlink_to(outside, target_is_directory=True)
    with pytest.raises(E.EditorialError, match="storage directory changed"): record(ledger, validated)
    assert list(outside.iterdir()) == []
    assert E.RoundLedger.load(original).summary()["round_count"] == 0


def test_atomic_publish_preserves_existing_records_and_cleans_temporary(tmp_path):
    destination = tmp_path / "record.json"
    E.RoundLedger._publish(destination, {"version": 1, "complete": True})
    original = destination.read_bytes()
    with pytest.raises(FileExistsError): E.RoundLedger._publish(destination, {"version": 2})
    assert destination.read_bytes() == original
    assert list(tmp_path.glob(".pending-*")) == []
    assert json.loads(original) == {"version": 1, "complete": True}


def test_non_darwin_publish_retains_exclusive_hardlink_fallback(tmp_path, monkeypatch):
    monkeypatch.setattr(E.sys, "platform", "linux")
    destination = tmp_path / "fallback.json"
    E.RoundLedger._publish(destination, {"complete": True})
    with pytest.raises(FileExistsError): E.RoundLedger._publish(destination, {"complete": False})
    assert json.loads(destination.read_bytes()) == {"complete": True}


@pytest.mark.skipif(E.sys.platform != "darwin", reason="Darwin RENAME_EXCL contract")
def test_darwin_publish_does_not_depend_on_hardlink_support(tmp_path, monkeypatch):
    def unsupported(*args, **kwargs): raise OSError(45, "Operation not supported")
    monkeypatch.setattr(E.os, "link", unsupported)
    destination = tmp_path / "rename.json"
    E.RoundLedger._publish(destination, {"complete": True})
    assert json.loads(destination.read_bytes()) == {"complete": True}
    with pytest.raises(FileExistsError): E.RoundLedger._publish(destination, {"complete": False})


def test_smb_directory_publication_collision_reload_and_partial_refusal(sources, script, tmp_path, monkeypatch):
    def unsupported(*args, **kwargs): raise OSError(E.errno.ENOTSUP, "Synthetic SMB no exclusive rename or hardlink")
    monkeypatch.setattr(E, "_publish_exclusive", unsupported)
    ledger = opened(tmp_path, sources); validated = E.validate_script(script, sources)
    assert (ledger.path / "ledger.json").is_dir()
    first = record(ledger, validated, reviewer_decision="revise")
    event = ledger.path / "events/0002.json"; original = E.RoundLedger._record_bytes(event)
    with pytest.raises(FileExistsError): E.RoundLedger._publish(event, {"would_replace": True})
    assert E.RoundLedger._record_bytes(event) == original
    assert not E.RoundLedger.load(ledger.path).summary()["approved"]
    result = record(E.RoundLedger.load(ledger.path), validated, 2)
    assert result["approved"] and E.RoundLedger._record_bytes(event) == original
    latest = ledger.path / "events/0003.json"
    (latest / "COMMITTED.sha256").write_bytes(b"partial")
    with pytest.raises(E.EditorialError, match="commit is incomplete"): E.RoundLedger.load(ledger.path)


def test_smb_failure_before_commit_marker_is_never_approval(sources, script, tmp_path, monkeypatch):
    ledger = opened(tmp_path, sources); validated = E.validate_script(script, sources)
    def partial(destination, raw):
        destination.mkdir(); (destination / "record.json").write_bytes(raw[:20])
        raise OSError("Synthetic interrupted SMB record")
    def unsupported(*args, **kwargs): raise OSError(E.errno.ENOTSUP, "Unsupported")
    monkeypatch.setattr(E, "_publish_exclusive", unsupported)
    monkeypatch.setattr(E, "_publish_directory_record", partial)
    with pytest.raises(OSError, match="interrupted SMB"): record(ledger, validated)
    with pytest.raises(E.EditorialError, match="publication is incomplete"): E.RoundLedger.load(ledger.path)

"""Source-bound script review and an append-only local editorial ledger.

No model, media, network or GUI transport lives here. Adapters supply timestamped
sources and completed session verdicts; session IDs identify their actual runs,
not an authenticated identity that this module can independently establish.

Script segments use inclusive first_word/last_word indexes. Their spoken words
and source times are derived locally; prose belongs in the separate issue lists.
Raw JSON bytes retain their exact SHA. Mapping inputs use canonical JSON bytes.
"""
from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass, field
from enum import Enum
import fcntl
import errno
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sys
import tempfile
from typing import Any, Iterable, Mapping


class EditorialError(ValueError):
    """An actionable refusal; no approval or next stage is implied."""


def canonical_json(value: Any) -> bytes:
    try:
        return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
    except (TypeError, ValueError) as exc:
        raise EditorialError("Evidence must be finite, JSON-serializable data.") from exc


def sha256(data: bytes | str) -> str:
    return hashlib.sha256(data.encode("utf-8") if isinstance(data, str) else data).hexdigest()


def _hash(value: Any, label: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
        raise EditorialError(f"{label} must be an actual lowercase SHA-256 digest.")
    return value


def _text(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.strip() or "\x00" in value:
        raise EditorialError(f"Supply {label} as nonempty text.")
    return value


def _number(value: Any, label: str) -> float:
    try:
        finite = isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)
    except OverflowError:
        finite = False
    if not finite:
        raise EditorialError(f"{label} must be a finite number.")
    return float(value)


def _object(value: Any, allowed: set[str], required: set[str], label: str) -> Mapping:
    if not isinstance(value, Mapping) or set(value) - allowed or required - set(value):
        raise EditorialError(f"{label} has missing or unsupported fields; expected {sorted(allowed)}.")
    return value


def _json(value: bytes | str | Mapping) -> tuple[dict, bytes]:
    raw = canonical_json(value) if isinstance(value, Mapping) else value.encode("utf-8") if isinstance(value, str) else value
    if not isinstance(raw, bytes):
        raise EditorialError("Supply a JSON object or UTF-8 JSON bytes.")
    def pairs(items):
        result = {}
        for key, item in items:
            if key in result:
                raise EditorialError(f"Duplicate JSON field {key!r} is ambiguous.")
            result[key] = item
        return result
    try:
        parsed = json.loads(raw.decode("utf-8"), object_pairs_hook=pairs,
                            parse_constant=lambda value: (_ for _ in ()).throw(EditorialError(f"Nonfinite JSON value {value}.")))
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise EditorialError("Evidence must be a valid UTF-8 JSON object.") from exc
    if not isinstance(parsed, dict):
        raise EditorialError("Evidence must be a JSON object.")
    canonical_json(parsed)  # Also reject overflowing numeric literals in metadata.
    return parsed, raw


@dataclass(frozen=True)
class TranscriptWord:
    word: str
    start: float
    end: float

    def to_dict(self) -> dict:
        return {"word": self.word, "start": self.start, "end": self.end}


@dataclass(frozen=True)
class TranscriptSource:
    source_id: str
    source_sha256: str
    duration: float
    words: tuple[TranscriptWord, ...]

    def __post_init__(self):
        _text(self.source_id, "source_id"); _hash(self.source_sha256, "Source hash")
        duration = _number(self.duration, "Source duration")
        if duration <= 0 or not isinstance(self.words, (list, tuple)):
            raise EditorialError("A transcript source needs a positive duration and a timestamped word list (possibly empty).")
        normalized = []
        for item in self.words:
            if isinstance(item, TranscriptWord):
                word, start, end = item.word, item.start, item.end
            elif isinstance(item, Mapping):
                if not {"word", "start", "end"} <= set(item):
                    raise EditorialError("Every transcript word needs word/start/end; infer no missing timing.")
                word, start, end = item["word"], item["start"], item["end"]
            else:
                raise EditorialError("Transcript words must be timestamped records.")
            _text(word, "supplied word")
            start, end = _number(start, "Word start"), _number(end, "Word end")
            if not 0 <= start < end <= duration:
                raise EditorialError(f"Source {self.source_id}: word timing is reversed or outside the original duration.")
            # Alignment can overlap neighboring words, but their ordered endpoints
            # must not reverse: the last selected word must contain the whole span.
            if normalized and (start < normalized[-1].start or end < normalized[-1].end):
                raise EditorialError(f"Source {self.source_id}: timestamped words are out of order.")
            normalized.append(TranscriptWord(word, start, end))
        object.__setattr__(self, "duration", duration)
        object.__setattr__(self, "words", tuple(normalized))

    @classmethod
    def from_dict(cls, value: Mapping) -> TranscriptSource:
        _object(value, {"source_id", "source_sha256", "duration", "words"},
                {"source_id", "source_sha256", "duration", "words"}, "Transcript source")
        return cls(**value)

    def to_dict(self) -> dict:
        return {"source_id": self.source_id, "source_sha256": self.source_sha256,
                "duration": self.duration, "words": [w.to_dict() for w in self.words]}

    @property
    def transcript_sha256(self) -> str:
        return sha256(canonical_json(self.to_dict()))


def _sources(sources: Iterable[TranscriptSource] | Mapping[str, TranscriptSource]) -> dict[str, TranscriptSource]:
    if isinstance(sources, Mapping):
        if any(not isinstance(s, TranscriptSource) or key != s.source_id for key, s in sources.items()):
            raise EditorialError("Source catalog keys must match their TranscriptSource identities.")
        items = list(sources.values())
    else:
        items = list(sources)
    result = {}
    for source in items:
        if not isinstance(source, TranscriptSource) or source.source_id in result:
            raise EditorialError("Supply distinct TranscriptSource records; duplicate IDs are ambiguous.")
        result[source.source_id] = source
    if not result:
        raise EditorialError("Complete the timestamped source transcripts before writing a script.")
    return result


@dataclass(frozen=True)
class Issue:
    id: str
    description: str
    category: str
    severity: str = "critical"
    status: str = "open"
    resolution: str | None = None
    resolved_by: str | None = None

    @classmethod
    def from_dict(cls, value: Mapping, category: str) -> Issue:
        _object(value, {"id", "description", "severity", "status", "resolution", "resolved_by"}, {"id", "description"}, "Editorial issue")
        issue = cls(category=category, **value)
        _text(issue.id, "issue ID"); _text(issue.description, "issue description")
        if issue.severity not in ("critical", "warning") or issue.status not in ("open", "resolved"):
            raise EditorialError("Issue severity must be critical/warning and status open/resolved.")
        if issue.status == "resolved":
            _text(issue.resolution, "an issue resolution"); _text(issue.resolved_by, "who resolved the issue")
            if category == "fact_flags" and issue.resolved_by != "human":
                raise EditorialError("A scientific fact flag requires an explicit human resolution.")
        elif issue.resolution is not None or issue.resolved_by is not None:
            raise EditorialError("An open issue cannot also claim a resolution.")
        return issue

    @property
    def blocks_picture(self) -> bool:
        # A model can type "human" into JSON. That annotation is never a human
        # approval: the ledger requires separate trusted-boundary evidence.
        return self.category == "fact_flags" or self.resolved_by == "human" or (self.status == "open" and (self.severity == "critical" or self.category == "pickups"))

    def to_dict(self) -> dict:
        return {"id": self.id, "description": self.description, "category": self.category,
                "severity": self.severity, "status": self.status, "resolution": self.resolution, "resolved_by": self.resolved_by}


def _issues(values: Any, category: str) -> tuple[Issue, ...]:
    if not isinstance(values, list):
        raise EditorialError(f"{category} must be a separate issue list.")
    items = tuple(Issue.from_dict(value, category) for value in values)
    if len({x.id for x in items}) != len(items):
        raise EditorialError("Issue IDs must be unique within their list.")
    return items


@dataclass(frozen=True)
class SourceSegment:
    section: int
    segment: int
    source_id: str
    source_sha256: str
    transcript_sha256: str
    first_word: int
    last_word: int
    start: float
    end: float
    quoted_words: tuple[str, ...]

    @property
    def spoken_text(self) -> str:
        return " ".join(self.quoted_words)

    def to_dict(self) -> dict:
        return {"section": self.section, "segment": self.segment, "source_id": self.source_id,
                "source_sha256": self.source_sha256, "transcript_sha256": self.transcript_sha256,
                "first_word": self.first_word, "last_word": self.last_word, "start": self.start, "end": self.end,
                "quoted_words": list(self.quoted_words), "spoken_text": self.spoken_text}


@dataclass(frozen=True)
class ValidatedScript:
    script_json: bytes = field(repr=False)
    script_sha256: str
    source_catalog_sha256: str
    segments: tuple[SourceSegment, ...]
    issues: tuple[Issue, ...]

    @property
    def unresolved_critical(self) -> tuple[Issue, ...]:
        return tuple(x for x in self.issues if x.blocks_picture)

    def to_dict(self) -> dict:
        return {"script_sha256": self.script_sha256, "source_catalog_sha256": self.source_catalog_sha256,
                "segments": [s.to_dict() for s in self.segments], "issues": [x.to_dict() for x in self.issues],
                "unresolved_critical": [x.to_dict() for x in self.unresolved_critical]}


def _interval_union_seconds(intervals: Iterable[tuple[float, float]]) -> float:
    covered_until = -math.inf
    portions = []
    for start, end in sorted(intervals):
        if end > covered_until:
            portions.append(end - max(start, covered_until))
            covered_until = end
    return math.fsum(portions)


def script_duration_projection(script: ValidatedScript, sources: Iterable[TranscriptSource], *, end_card_seconds: float = 10) -> dict:
    """Conservative planning estimate, never evidence of delivered runtime.

    Credit capped word articulation once per physical source SHA, including
    across overlapping/replayed segments and alias source IDs. Raw selected
    word/span metrics still include every editorial occurrence. ASR overlap
    cannot count time twice, and neither gaps between words nor editorial joins
    prove a retained pause. Suspiciously stretched tokens remain capped; actual
    cuts still need source-audio checks. No unverified padding is credited.
    """
    catalog = _sources(sources)
    catalog_hash = sha256(canonical_json([catalog[key].to_dict() for key in sorted(catalog)]))
    if script.source_catalog_sha256 != catalog_hash:
        raise EditorialError("Duration planning requires the exact reviewed source catalog.")
    transcript_hashes = {key: source.transcript_sha256 for key, source in catalog.items()}
    tail = _number(end_card_seconds, "Post-talk end-card tail")
    if tail < 0: raise EditorialError("The end-card tail cannot be negative.")
    word_count = 0
    selected_articulation = []
    physical_source_intervals = {}
    for segment in script.segments:
        source = catalog.get(segment.source_id)
        if source is None or source.source_sha256 != segment.source_sha256 or transcript_hashes[segment.source_id] != segment.transcript_sha256:
            raise EditorialError("Duration planning requires the exact reviewed source catalog.")
        words = source.words[segment.first_word:segment.last_word + 1]
        word_count += len(words)
        intervals = [(word.start, min(word.end, word.start + max(.45, .12 * len(word.word)))) for word in words]
        selected_articulation.append(min(_interval_union_seconds(intervals), words[-1].end - words[0].start))
        # Editorial order need not follow source time. Union all selected
        # intervals using original time and physical identity, never alias ID.
        physical_source_intervals.setdefault(source.source_sha256, []).extend(intervals)
    selected_voice = math.fsum(selected_articulation)
    voice = math.fsum(_interval_union_seconds(intervals) for intervals in physical_source_intervals.values())
    return {"schema_version": 1, "script_sha256": script.script_sha256, "selected_words": word_count,
            "source_span_seconds": sum(s.end - s.start for s in script.segments),
            "selected_articulation_seconds": selected_voice,
            "repaired_narration_estimate_seconds": voice, "post_talk_tail_seconds": tail,
            "replay_articulation_seconds_not_credited": max(0.0, selected_voice - voice),
            "finished_estimate_seconds": voice + tail, "invented_nonverbal_seconds": 0,
            "unverified_pause_seconds_credited": 0,
            "projection_only": True, "source_audio_boundaries_verified": False,
            "final_rendered_file_duration_check_required": True}


def check_script_duration(projection: Mapping, minimum: float) -> None:
    required = _number(minimum, "Minimum finished duration")
    actual = _number(projection.get("finished_estimate_seconds"), "Script planning duration")
    if required <= 0: raise EditorialError("The minimum duration must be positive.")
    if actual < required:
        raise EditorialError(f"Duration review required: source-word planning estimate is {actual:.3f}s, below the {required:.3f}s minimum. Select more useful complete recorded explanation/process; do not invent narration or pad dead air. The final encoded file still needs its own duration check.")


def validate_script(script: bytes | str | Mapping, sources: Iterable[TranscriptSource] | Mapping[str, TranscriptSource]) -> ValidatedScript:
    """Derive exact source spans; validate spoken selection without inventing text."""
    catalog = _sources(sources)
    data, raw = _json(script)
    metadata = {"id", "title", "purpose", "join_notes", "notes"}
    _object(data, metadata | {"schema_version", "sections", "pickups", "coverage_gaps", "fact_flags"}, {"sections"}, "Script")
    if "schema_version" in data and (type(data["schema_version"]) is not int or data["schema_version"] != 1):
        raise EditorialError("Unsupported script schema; use schema_version 1.")
    sections = data["sections"]
    if not isinstance(sections, list) or not sections:
        raise EditorialError("A script needs source-bound sections before picture editing.")
    result = []
    for si, section in enumerate(sections):
        _object(section, metadata | {"segments"}, {"segments"}, "Script section")
        segments = section["segments"]
        if not isinstance(segments, list) or not segments:
            raise EditorialError("Each section needs source-bound segments; record missing pickups separately.")
        for di, segment in enumerate(segments):
            required = {"source_id", "source_sha256", "first_word", "last_word"}
            _object(segment, required | metadata | {"spoken_text", "transcript_sha256"}, required, "Spoken segment")
            source_id = _text(segment["source_id"], "source_id")
            if source_id not in catalog:
                raise EditorialError(f"Unknown source {source_id!r}; complete its transcript before selecting words.")
            source = catalog[source_id]
            if _hash(segment["source_sha256"], "Segment source hash") != source.source_sha256:
                raise EditorialError(f"Stale source hash for {source_id}; re-review the actual source and script.")
            if "transcript_sha256" in segment and _hash(segment["transcript_sha256"], "Transcript hash") != source.transcript_sha256:
                raise EditorialError(f"Stale transcript hash for {source_id}; select words from the current transcript.")
            first, last = segment["first_word"], segment["last_word"]
            if type(first) is not int or type(last) is not int or not 0 <= first <= last < len(source.words):
                raise EditorialError(f"{source_id}: use valid inclusive first_word/last_word indexes.")
            selected = source.words[first:last + 1]
            words = tuple(w.word for w in selected)
            spoken = " ".join(words)
            if re.search(r"(?:^|\s)[\[<{]\s*(?:pick[- ]?up|todo|tbd|to record|insert)\b|^(?:pick[- ]?up|todo|tbd|to record)\s*:", spoken, re.I):
                raise EditorialError("A spoken pickup placeholder is not recorded dialogue; list it in pickups.")
            if "spoken_text" in segment and segment["spoken_text"] != spoken:
                raise EditorialError(f"{source_id}: spoken_text must match the exact supplied words; fabricated/replacement speech is refused.")
            result.append(SourceSegment(si, di, source_id, source.source_sha256, source.transcript_sha256,
                                        first, last, selected[0].start, selected[-1].end, words))
    issues = tuple(issue for category in ("pickups", "coverage_gaps", "fact_flags") for issue in _issues(data.get(category, []), category))
    catalog_hash = sha256(canonical_json([catalog[key].to_dict() for key in sorted(catalog)]))
    return ValidatedScript(raw, sha256(raw), catalog_hash, tuple(result), issues)


INPUT_BINDING_ISSUE = "clauto-review-input-binding-required"


@dataclass(frozen=True)
class ReviewReceipt:
    session_id: str
    receipt_id: str
    artifact_json: bytes = field(repr=False)

    def __post_init__(self):
        for value, label in [(self.session_id, "actual session ID"), (self.receipt_id, "unique receipt ID")]:
            _text(value, label)
            if value != value.strip() or value.strip().lower() in {"unknown", "unreviewed", "pending", "placeholder"}:
                raise EditorialError(f"Supply the {label} from a completed actual session.")
        data, raw = _json(self.artifact_json)
        _object(data, {"decision", "script_sha256", "issues", "input_bound_provider_refusal"}, {"decision", "script_sha256", "issues"}, "Completed review verdict")
        if data["decision"] not in ("agree", "revise"):
            raise EditorialError("A completed verdict must explicitly say agree or revise; partial/failed streams cannot approve.")
        _hash(data["script_sha256"], "Explicit reviewed script hash")
        _issues(data["issues"], "review")
        if "input_bound_provider_refusal" in data:
            binding=data["input_bound_provider_refusal"]
            keys={"original_artifact_json","original_artifact_sha256","input_prompt_sha256","disposition"}
            _object(binding,keys,keys,"Input-bound provider refusal")
            original,original_raw=_json(binding["original_artifact_json"])
            if sha256(original_raw)!=binding["original_artifact_sha256"]:raise EditorialError("The original unverified refusal artifact changed.")
            _hash(binding["input_prompt_sha256"],"Delivered input prompt hash")
            if binding["disposition"]!="input-bound-refusal-not-model-identity-confirmation" or data["decision"]!="revise" or original.get("decision")!="revise" or original.get("script_sha256")==data["script_sha256"]:
                raise EditorialError("Input-bound refusals cannot approve or replace an already bound verdict.")
            expected=[{"id":INPUT_BINDING_ISSUE,"description":"The provider requested revision but did not confirm the supplied script identity. Its original critique remains diagnostic; a later verified exact-SHA verdict is required.","severity":"critical","status":"open"}]
            if data["issues"]!=expected:raise EditorialError("An input-bound refusal must retain only its protected critical binding issue.")
        object.__setattr__(self, "artifact_json", raw)

    @classmethod
    def from_artifact(cls, session_id: str, receipt_id: str, artifact: bytes | str | Mapping) -> ReviewReceipt:
        _, raw = _json(artifact)
        return cls(session_id, receipt_id, raw)

    @property
    def verdict(self) -> dict:
        return _json(self.artifact_json)[0]

    @property
    def artifact_sha256(self) -> str:
        return sha256(self.artifact_json)

    @property
    def is_input_bound_refusal(self) -> bool:
        return "input_bound_provider_refusal" in self.verdict

    @property
    def issues(self) -> tuple[Issue, ...]:
        return _issues(self.verdict["issues"], "review")

    def to_dict(self) -> dict:
        return {"session_id": self.session_id, "receipt_id": self.receipt_id,
                "artifact_json": self.artifact_json.decode("utf-8"), "artifact_sha256": self.artifact_sha256}

    @classmethod
    def from_dict(cls, data: Mapping) -> ReviewReceipt:
        keys = {"session_id", "receipt_id", "artifact_json", "artifact_sha256"}
        _object(data, keys, keys, "Stored review receipt")
        receipt = cls.from_artifact(data["session_id"], data["receipt_id"], data["artifact_json"])
        if receipt.artifact_sha256 != data["artifact_sha256"]:
            raise EditorialError("A saved review artifact changed; restore its original evidence.")
        return receipt


class Stage(str, Enum):
    TRANSCRIPTS = "transcripts"
    SCRIPT = "script"
    PICTURE_DIALOGUE = "picture_dialogue"
    MUSIC = "music"
    GRAPHICS = "graphics"
    FINAL = "final"


@dataclass(frozen=True)
class HumanFactApproval:
    """Supplied human-input evidence, never parsed from a model verdict.

    The orchestration/human-input boundary must authenticate who supplied this
    approval and its meaning. This local ledger preserves its exact evidence;
    neither an opaque ID nor an artifact hash authenticates a human by itself.
    """
    issue_id: str
    approval_id: str
    script_sha256: str
    artifact: bytes = field(repr=False)

    def __post_init__(self):
        _text(self.issue_id, "human-reviewed issue ID"); _text(self.approval_id, "actual human approval receipt ID")
        _hash(self.script_sha256, "Human-reviewed exact script SHA")
        raw = self.artifact.encode("utf-8") if isinstance(self.artifact, str) else self.artifact
        if not isinstance(raw, bytes): raise EditorialError("Supply the actual UTF-8 human approval evidence.")
        try: _text(raw.decode("utf-8"), "human approval evidence")
        except UnicodeError as exc: raise EditorialError("Human approval evidence must be UTF-8 text.") from exc
        object.__setattr__(self, "artifact", raw)

    def to_dict(self) -> dict:
        return {"issue_id": self.issue_id, "approval_id": self.approval_id, "script_sha256": self.script_sha256,
                "artifact": self.artifact.decode("utf-8"), "artifact_sha256": sha256(self.artifact)}

    @classmethod
    def from_dict(cls, data: Mapping) -> HumanFactApproval:
        keys = {"issue_id", "approval_id", "script_sha256", "artifact", "artifact_sha256"}
        _object(data, keys, keys, "Separate human approval receipt")
        value = cls(data["issue_id"], data["approval_id"], data["script_sha256"], data["artifact"])
        if sha256(value.artifact) != data["artifact_sha256"]:
            raise EditorialError("The supplied human approval evidence changed.")
        return value


def validate_end_card(aspect: str, end_card_seconds: float | None) -> None:
    if aspect not in ("16:9", "9:16"):
        raise EditorialError("Choose an explicit supported horizontal 16:9 or vertical 9:16 aspect.")
    if end_card_seconds is not None and _number(end_card_seconds, "End-card tail") < 0:
        raise EditorialError("An end-card tail cannot be negative.")
    if aspect == "16:9" and (end_card_seconds is None or end_card_seconds < 10):
        raise EditorialError("The horizontal final needs at least 10 seconds of end-card tail; vertical exports are exempt.")


def _publish_exclusive(temporary: str, destination: Path) -> None:
    """Publish complete same-directory bytes without replacing any prior leaf.

    SMB on macOS does not support hard links. Darwin's RENAME_EXCL (stdio.h)
    supplies the atomic server rename with replace-if-exists disabled. Never
    emulate this with exists()+rename(), which races and can overwrite evidence.
    """
    if sys.platform == "darwin":
        import ctypes
        library = ctypes.CDLL(None, use_errno=True)
        rename = library.renamex_np
        rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        rename.restype = ctypes.c_int
        if rename(os.fsencode(temporary), os.fsencode(destination), 0x00000004) != 0:
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error), os.fspath(destination))
    else:
        os.link(temporary, destination)


def _publish_directory_record(destination: Path, raw: bytes) -> None:
    """SMB fallback: an exclusive directory claim with a verified commit marker.

    Some macOS SMB mounts reject both hard links and RENAME_EXCL. mkdir is an
    atomic no-replace claim; exclusive child opens never replace prior evidence.
    A reader recognizes the record only after complete fsynced JSON and a matching
    fsynced SHA commit marker exist. Interrupted claims remain visibly incomplete.
    """
    destination.mkdir(mode=0o700)
    directory = os.open(destination, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    committed = False
    try:
        for name, content in [("record.json", raw), ("COMMITTED.sha256", sha256(raw).encode("ascii"))]:
            fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory)
            if name == "COMMITTED.sha256": committed = True
            with os.fdopen(fd, "wb") as stream:
                stream.write(content); stream.flush(); os.fsync(stream.fileno())
        os.fsync(directory)
    except BaseException:
        if committed:
            os.unlink("COMMITTED.sha256", dir_fd=directory)
        raise
    finally:
        os.close(directory)


@dataclass
class _State:
    stage: Stage = Stage.TRANSCRIPTS
    sources: dict[str, TranscriptSource] = field(default_factory=dict)
    rounds: list[dict] = field(default_factory=list)
    approved_script_sha256: str | None = None
    writer_sessions: set[str] = field(default_factory=set)
    reviewer_sessions: set[str] = field(default_factory=set)
    receipt_ids: set[str] = field(default_factory=set)
    round_ids: set[str] = field(default_factory=set)
    unresolved: dict[tuple[str, str, str], dict] = field(default_factory=dict)
    stage_artifacts: list[dict] = field(default_factory=list)
    human_fact_approvals: dict[str, dict] = field(default_factory=dict)


class RoundLedger:
    """At most ten immutable completed review rounds, with strict stage gates.

    complete_transcripts() opens SCRIPT. append_round() records both actual
    session verdicts without advancing picture. advance() records the next
    completed stage artifact and requires the exact approved script identity.
    A locked append-only journal makes successful writes durable and reloadable;
    abandoned temporary files never become approval or hide a completed round.
    """

    def __init__(self, path: Path):
        self.path = Path(path)
        if self.path.is_symlink() or not self.path.is_dir():
            raise EditorialError("Use an existing real local editorial-ledger directory.")
        self.path = self.path.resolve()
        directory = self.path.stat()
        self._directory_identity = (directory.st_dev, directory.st_ino)
        config = self._read(self.path / "ledger.json")
        _object(config, {"schema_version", "max_rounds"}, {"schema_version", "max_rounds"}, "Ledger configuration")
        if type(config["schema_version"]) is not int or config["schema_version"] != 1 or type(config["max_rounds"]) is not int or not 1 <= config["max_rounds"] <= 10:
            raise EditorialError("The editorial round limit must be an integer from 1 through 10.")
        self.max_rounds = config["max_rounds"]
        if (self.path / "events").is_symlink() or not (self.path / "events").is_dir():
            raise EditorialError("Ledger events must remain inside their original directory.")
        self._state()

    @classmethod
    def create(cls, path: Path, max_rounds: int = 10) -> RoundLedger:
        if type(max_rounds) is not int or not 1 <= max_rounds <= 10:
            raise EditorialError("The editorial round limit must be an integer from 1 through 10.")
        path = Path(path)
        # The caller owns the selected parent directory. Never replace a ledger,
        # follow a leaf alias, or create an unexpected storage parent.
        if path.exists() or path.is_symlink() or not path.parent.is_dir():
            raise EditorialError("Choose a fresh ledger folder under an existing local storage directory.")
        path.mkdir(); (path / "events").mkdir()
        cls._publish(path / "ledger.json", {"schema_version": 1, "max_rounds": max_rounds})
        return cls(path)

    @classmethod
    def load(cls, path: Path) -> RoundLedger:
        return cls(path)

    @staticmethod
    def _record_bytes(path: Path) -> bytes:
        if path.is_symlink():
            raise EditorialError("Ledger records cannot be symbolic-link aliases.")
        body, marker = (path / "record.json", path / "COMMITTED.sha256") if path.is_dir() else (path, None)
        if body.is_symlink() or (marker is not None and (marker.is_symlink() or not marker.is_file() or not body.is_file())):
            raise EditorialError("A ledger publication is incomplete or aliased; preserve its evidence and do not infer approval.")
        if body.stat().st_size > 16 * 1024 * 1024:
            raise EditorialError("A ledger record exceeds the bounded local evidence size.")
        raw = body.read_bytes()
        if marker is not None and marker.read_bytes() != sha256(raw).encode("ascii"):
            raise EditorialError("A ledger commit is incomplete or changed; it is not approval.")
        return raw

    @staticmethod
    def _read(path: Path) -> dict:
        return _json(RoundLedger._record_bytes(path))[0]

    @staticmethod
    def _publish(path: Path, value: dict) -> None:
        raw = canonical_json(value)
        if len(raw) > 16 * 1024 * 1024:
            raise EditorialError("A ledger record exceeds the bounded local evidence size.")
        fd, temporary = tempfile.mkstemp(prefix=".pending-", dir=path.parent)
        try:
            with os.fdopen(fd, "wb") as stream:
                stream.write(raw); stream.flush(); os.fsync(stream.fileno())
            try:
                _publish_exclusive(temporary, path)
            except OSError as exc:
                if exc.errno not in {errno.ENOTSUP, errno.EOPNOTSUPP, errno.ENOSYS}: raise
                _publish_directory_record(path, raw)
            directory = os.open(path.parent, os.O_RDONLY)
            try: os.fsync(directory)
            finally: os.close(directory)
        finally:
            try: os.unlink(temporary)
            except FileNotFoundError: pass  # RENAME_EXCL consumes the temporary.

    @contextmanager
    def _lock(self):
        self._check_storage()
        fd = os.open(self.path / ".lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally:
            os.close(fd)

    def _check_storage(self):
        if self.path.is_symlink() or self.path.resolve() != self.path or not self.path.is_dir():
            raise EditorialError("The ledger storage directory changed; reopen its original location.")
        directory = self.path.stat()
        if (directory.st_dev, directory.st_ino) != self._directory_identity:
            raise EditorialError("The ledger storage directory was replaced; preserve and reopen its original records.")

    def _state(self) -> tuple[_State, list[Path]]:
        self._check_storage()
        events_dir = self.path / "events"
        if events_dir.is_symlink() or events_dir.resolve().parent != self.path:
            raise EditorialError("Ledger events escaped the selected storage directory.")
        files = sorted(p for p in events_dir.iterdir() if not p.name.startswith(".pending-"))
        if len(files) > self.max_rounds + 5:
            raise EditorialError("The ledger has more records than its bounded workflow permits.")
        state, previous = _State(), None
        for index, path in enumerate(files, 1):
            if path.name != f"{index:04d}.json":
                raise EditorialError("The ledger journal has a missing or unexpected record; preserve and repair the evidence.")
            event = self._read(path)
            keys = {"kind", "previous_event_sha256", "payload", "event_sha256"}
            _object(event, keys, keys, "Ledger event")
            content = {key: event[key] for key in keys - {"event_sha256"}}
            if event["event_sha256"] != sha256(canonical_json(content)):
                raise EditorialError("A ledger event changed; restore its immutable record.")
            if event["previous_event_sha256"] != previous:
                raise EditorialError("An earlier ledger event changed; restore its immutable record.")
            self._apply(state, event["kind"], event["payload"])
            previous = sha256(self._record_bytes(path))
        return state, files

    def _apply(self, state: _State, kind: str, payload: dict) -> None:
        if kind == "transcripts":
            _object(payload, {"sources"}, {"sources"}, "Transcript completion")
            if state.stage != Stage.TRANSCRIPTS or not isinstance(payload["sources"], list):
                raise EditorialError("Transcripts can only be completed once, before script work.")
            state.sources = _sources([TranscriptSource.from_dict(x) for x in payload["sources"]])
            state.stage = Stage.SCRIPT
        elif kind == "round":
            keys = {"number", "round_id", "script_json", "script_sha256", "source_catalog_sha256", "writer", "reviewer", "human_fact_approvals"}
            _object(payload, keys, keys, "Editorial round")
            if state.stage != Stage.SCRIPT or state.approved_script_sha256 is not None:
                raise EditorialError("Review rounds belong before picture editing; an approved script is immutable in this ledger.")
            if len(state.rounds) >= self.max_rounds:
                raise EditorialError("The actual round limit is exhausted without agreement; stop for editorial review, not picture editing.")
            if type(payload["number"]) is not int or payload["number"] != len(state.rounds) + 1:
                raise EditorialError("Round numbers must be consecutive and cannot replace earlier evidence.")
            round_id = _text(payload["round_id"], "round ID")
            if round_id in state.round_ids:
                raise EditorialError("Round IDs must be unique; earlier rounds cannot be reused.")
            script = validate_script(payload["script_json"], state.sources)
            if script.script_sha256 != payload["script_sha256"]:
                raise EditorialError("A saved script artifact changed; re-review the exact bytes.")
            if script.source_catalog_sha256 != payload["source_catalog_sha256"]:
                raise EditorialError("The reviewed transcript catalog changed; begin a new source-bound review.")
            writer, reviewer = ReviewReceipt.from_dict(payload["writer"]), ReviewReceipt.from_dict(payload["reviewer"])
            if (writer.session_id == reviewer.session_id or writer.session_id in state.reviewer_sessions
                    or reviewer.session_id in state.writer_sessions):
                raise EditorialError("Writer and adversarial reviewer require independent actual sessions; roles cannot be exchanged.")
            if writer.receipt_id == reviewer.receipt_id or {writer.receipt_id, reviewer.receipt_id} & state.receipt_ids:
                raise EditorialError("Every completed session receipt needs a unique identity; do not count it twice.")
            if any(r.verdict["script_sha256"] != script.script_sha256 for r in (writer, reviewer)):
                raise EditorialError("Both verdicts must review the exact supplied script SHA; stale agreement is refused.")
            if not isinstance(payload["human_fact_approvals"], list):
                raise EditorialError("Separate human approval evidence must be a list of trusted-boundary receipts.")
            issue_groups = [("script", script.issues), ("writer", writer.issues), ("reviewer", reviewer.issues)]
            # Only a later exact-SHA provider receipt closes a host binding
            # refusal. Unbound provider issue resolutions are never applied.
            for origin, receipt in (("writer", writer), ("reviewer", reviewer)):
                if not receipt.is_input_bound_refusal:
                    state.unresolved.pop((origin, "review", INPUT_BINDING_ISSUE), None)
            fact_ids = {x.id for _, issues in issue_groups for x in issues if x.category == "fact_flags" or x.resolved_by == "human"}
            fact_ids.update(x["id"] for x in state.unresolved.values() if x.get("awaiting_human_approval"))
            for entry in payload["human_fact_approvals"]:
                approval = HumanFactApproval.from_dict(entry)
                if approval.script_sha256 != script.script_sha256 or approval.issue_id not in fact_ids:
                    raise EditorialError("Human approval must refer to this exact script SHA and an explicitly recorded issue requiring human review.")
                if approval.approval_id in state.human_fact_approvals:
                    raise EditorialError("Human approval receipt IDs are unique; earlier evidence is already preserved.")
                state.human_fact_approvals[approval.approval_id] = approval.to_dict()
            approved_facts = {(x["script_sha256"], x["issue_id"]) for x in state.human_fact_approvals.values()}
            # A clean later verdict cannot silently erase a recorded critical
            # defect. Its same-role, same-ID resolution must say what changed.
            for origin, issues in issue_groups:
                for issue in issues:
                    if origin in {"writer", "reviewer"} and issue.id == INPUT_BINDING_ISSUE:
                        if not (writer if origin == "writer" else reviewer).is_input_bound_refusal:
                            continue
                    key = (origin, issue.category, issue.id)
                    needs_human = (issue.category == "fact_flags" or issue.resolved_by == "human"
                                   or state.unresolved.get(key, {}).get("awaiting_human_approval", False))
                    if needs_human:
                        if issue.status == "resolved" and (script.script_sha256, issue.id) in approved_facts:
                            state.unresolved.pop(key, None)
                        else:
                            state.unresolved[key] = {"origin": origin, **issue.to_dict(), "awaiting_human_approval": True}
                    elif issue.status == "resolved":
                        state.unresolved.pop(key, None)
                    elif issue.blocks_picture:
                        state.unresolved[key] = {"origin": origin, **issue.to_dict()}
            unresolved = list(state.unresolved.values())
            approved = all(r.verdict["decision"] == "agree" for r in (writer, reviewer)) and not unresolved
            state.rounds.append({**payload, "approved": approved, "unresolved_critical": unresolved,
                                 "source_trace": [x.to_dict() for x in script.segments]})
            state.round_ids.add(round_id); state.receipt_ids.update([writer.receipt_id, reviewer.receipt_id])
            state.writer_sessions.add(writer.session_id); state.reviewer_sessions.add(reviewer.session_id)
            if approved: state.approved_script_sha256 = script.script_sha256
        elif kind == "stage":
            keys = {"stage", "artifact_sha256", "script_sha256", "aspect", "end_card_seconds"}
            _object(payload, keys, keys, "Stage completion")
            try: target = Stage(payload["stage"])
            except (ValueError, TypeError) as exc: raise EditorialError("Unknown editorial stage.") from exc
            stages = list(Stage)
            if state.stage == Stage.FINAL or stages.index(target) != stages.index(state.stage) + 1:
                raise EditorialError("Stage order is transcripts → script → picture/dialogue → music → graphics → final; no bypass.")
            if state.approved_script_sha256 is None or payload["script_sha256"] != state.approved_script_sha256:
                raise EditorialError("Picture and later stages require both sessions' approval of this exact script SHA.")
            _hash(payload["artifact_sha256"], "Completed stage artifact hash")
            if target == Stage.FINAL: validate_end_card(payload["aspect"], payload["end_card_seconds"])
            elif payload["aspect"] is not None or payload["end_card_seconds"] is not None:
                raise EditorialError("End-card evidence belongs to the final stage.")
            state.stage = target
            state.stage_artifacts.append(dict(payload))
        else:
            raise EditorialError("Unknown ledger event; do not infer completion.")

    def _append(self, kind: str, payload: dict) -> dict:
        with self._lock():
            state, files = self._state()
            if kind == "round":
                payload = {**payload, "number": len(state.rounds) + 1}
            self._apply(state, kind, payload)
            previous = sha256(self._record_bytes(files[-1])) if files else None
            event = {"kind": kind, "previous_event_sha256": previous, "payload": payload}
            self._publish(self.path / "events" / f"{len(files) + 1:04d}.json",
                          {**event, "event_sha256": sha256(canonical_json(event))})
            return self._summary(state)

    def complete_transcripts(self, sources: Iterable[TranscriptSource] | Mapping[str, TranscriptSource]) -> dict:
        catalog = _sources(sources)
        return self._append("transcripts", {"sources": [catalog[key].to_dict() for key in sorted(catalog)]})

    def append_round(self, script: ValidatedScript, *, writer: ReviewReceipt, reviewer: ReviewReceipt, round_id: str,
                     human_fact_approvals: Iterable[HumanFactApproval] = ()) -> dict:
        if not isinstance(script, ValidatedScript) or not isinstance(writer, ReviewReceipt) or not isinstance(reviewer, ReviewReceipt):
            raise EditorialError("Supply a source-validated script and completed writer/reviewer verdicts.")
        human = list(human_fact_approvals)
        if any(not isinstance(x, HumanFactApproval) for x in human):
            raise EditorialError("Do not infer human authority from model fields; supply separate HumanFactApproval evidence.")
        return self._append("round", {"round_id": round_id,
                                      "script_json": script.script_json.decode("utf-8"), "script_sha256": script.script_sha256,
                                      "source_catalog_sha256": script.source_catalog_sha256,
                                      "human_fact_approvals": [x.to_dict() for x in human],
                                      "writer": writer.to_dict(), "reviewer": reviewer.to_dict()})

    def advance(self, stage: Stage | str, *, artifact_sha256: str, script_sha256: str,
                aspect: str | None = None, end_card_seconds: float | None = None) -> dict:
        return self._append("stage", {"stage": stage.value if isinstance(stage, Stage) else stage,
                                      "artifact_sha256": artifact_sha256, "script_sha256": script_sha256,
                                      "aspect": aspect, "end_card_seconds": end_card_seconds})

    def _summary(self, state: _State) -> dict:
        approved = state.approved_script_sha256 is not None
        return {"schema_version": 1, "stage": state.stage.value, "max_rounds": self.max_rounds,
                "round_count": len(state.rounds), "approved": approved,
                "approved_script_sha256": state.approved_script_sha256,
                "exhausted_without_approval": len(state.rounds) >= self.max_rounds and not approved,
                "unresolved_critical": state.rounds[-1]["unresolved_critical"] if state.rounds else [],
                "transcripts": [{"source_id": s.source_id, "source_sha256": s.source_sha256,
                                 "transcript_sha256": s.transcript_sha256, "word_count": len(s.words), "duration": s.duration}
                                for s in state.sources.values()],
                "stage_artifacts": state.stage_artifacts,
                "human_fact_approvals": list(state.human_fact_approvals.values()),
                "rounds": state.rounds}

    def summary(self) -> dict:
        state, _ = self._state()
        return self._summary(state)

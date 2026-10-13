"""
Stage 3 — Graphic plan.

Reads the annotated script and turns her margin notes into a timed graphic plan, synced to
the word timings from Stage 1.

Two annotation routes, both supported:

  1. **Inline markers** in a .md / .txt script:
         [[GFX: key_term | text="Gluten" | asset=cutout:gluten_strand]]
         [[BROLL: macro of bubbles rising in the starter]]
         [[VO: this line is voice-over, not on camera]]

  2. **Word comments** in a .docx. Comment text is parsed with the same syntax; the commented
     run is used as the anchor phrase. This is the route to use if she'd rather write in Word.

Anchoring: each graphic is matched to the phrase it sits next to, then placed at that phrase's
timestamp in the transcript. Hold time comes from config.hold_seconds() — never guessed.

Output: build/plan/<project>.plan.json
"""

from __future__ import annotations

import argparse
import json
import re
import zipfile
from dataclasses import asdict, dataclass, field
from difflib import SequenceMatcher
from pathlib import Path
from xml.etree import ElementTree as ET

import cli
import config as C
import corrections as CR


MARKER = re.compile(r"\[\[\s*(?P<kind>[A-Z_]+)\s*:\s*(?P<body>.*?)\]\]", re.S)
KV = re.compile(r'(\w+)\s*=\s*"([^"]*)"')
NORMALIZE = re.compile(r"[^a-z0-9 ]+")

# Markdown scaffolding never gets spoken, so it must not pollute the anchor phrase.
MD_HEADING = re.compile(r"^\s{0,3}#{1,6}\s.*$", re.M)
MD_FENCE = re.compile(r"```.*?```", re.S)
MD_NOISE = re.compile(r"(^\s{0,3}[-*+>]\s+|[*_`~]+)", re.M)

# Only these cue kinds take a template name. For the rest, a bare first token is free
# text describing the shot — treating it as a template is what produced
# "unknown template 'bubbles rising in the starter'".
TEMPLATE_KINDS = {"GFX", "CHAPTER"}

W_NS = {
    "w": "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
}

VALID_KINDS = {
    "GFX",      # a graphic: title card, key term, diagram, gauge, comparison
    "BROLL",    # cut to b-roll
    "MACRO",    # cut to a macro insert
    "VO",       # voice-over section
    "CAM",      # camera / angle change
    "CHAPTER",  # chapter boundary + title card
    "NOTE",     # human note, carried through but not rendered
}

# Templates in templates/ that Stage 5 knows how to composite.
KNOWN_TEMPLATES = {
    "chapter_card", "key_term", "lower_third", "diagram",
    "gauge", "comparison", "stat", "quote",
}


@dataclass
class Cue:
    id: str
    kind: str
    template: str | None = None
    text: str = ""
    assets: list[str] = field(default_factory=list)
    anchor: str = ""            # phrase this cue sits next to in the script
    start: float | None = None  # resolved from the transcript
    hold: float | None = None
    end: float | None = None
    aspect: str = C.DEFAULT_ASPECT
    notes: str = ""
    unresolved: str | None = None


# --------------------------------------------------------------------------------------
# Parsing
# --------------------------------------------------------------------------------------

def norm(s: str) -> str:
    return NORMALIZE.sub("", s.lower()).strip()


def strip_markdown(text: str) -> str:
    """Remove anything that isn't spoken, so anchors match the transcript."""
    text = MD_FENCE.sub(" ", text)
    text = MD_HEADING.sub(" ", text)
    text = MD_NOISE.sub(" ", text)
    return re.sub(r"\s+", " ", text).strip()


def parse_body(body: str, kind: str = "GFX") -> dict:
    """`key_term | text="Gluten" | asset=cutout:gluten_strand` -> dict"""
    body = body.strip()
    out: dict = {"assets": [], "kv": {}}
    parts = [p.strip() for p in body.split("|")]
    if parts and "=" not in parts[0]:
        if kind in TEMPLATE_KINDS:
            out["template"] = parts[0]
        else:
            out.setdefault("free", []).append(parts[0])
        parts = parts[1:]
    for p in parts:
        if not p:
            continue
        m = KV.match(p)
        if m:
            k, v = m.group(1), m.group(2)
        elif "=" in p:
            k, v = (x.strip() for x in p.split("=", 1))
        else:
            out.setdefault("free", []).append(p)
            continue
        if k in ("asset", "assets"):
            out["assets"] += [a.strip() for a in v.split(",") if a.strip()]
        else:
            out["kv"][k] = v
    return out


def parse_markdown(path: Path) -> list[Cue]:
    text = path.read_text(encoding="utf-8", errors="replace")
    cues: list[Cue] = []
    for i, m in enumerate(MARKER.finditer(text)):
        kind = m.group("kind").upper()
        parsed = parse_body(m.group("body"), kind)
        # Anchor = the ~12 spoken words immediately before the marker.
        before = strip_markdown(MARKER.sub(" ", text[: m.start()]))
        anchor = " ".join(before.split()[-12:])
        cues.append(
            Cue(
                id=f"c{i+1:03d}",
                kind=kind,
                template=parsed.get("template") or parsed["kv"].get("template"),
                text=parsed["kv"].get("text", " ".join(parsed.get("free", []))),
                assets=parsed["assets"],
                anchor=anchor,
                aspect=parsed["kv"].get("aspect", C.DEFAULT_ASPECT),
                notes=parsed["kv"].get("note", ""),
            )
        )
    return cues


def parse_docx(path: Path) -> list[Cue]:
    """
    Read Word comments straight out of the package. python-docx doesn't expose comments,
    so we read word/comments.xml and word/document.xml and pair them by comment id.
    """
    cues: list[Cue] = []
    with zipfile.ZipFile(path) as z:
        names = set(z.namelist())
        if "word/comments.xml" not in names:
            return cues
        comments_xml = ET.fromstring(z.read("word/comments.xml"))
        doc_xml = ET.fromstring(z.read("word/document.xml"))

    # comment id -> comment text
    comments: dict[str, str] = {}
    for c in comments_xml.findall("w:comment", W_NS):
        cid = c.get(f"{{{W_NS['w']}}}id")
        txt = "".join(t.text or "" for t in c.iter(f"{{{W_NS['w']}}}t"))
        if cid:
            comments[cid] = txt.strip()

    # Walk the body, tracking which comment ranges are open, collecting anchored text.
    anchors: dict[str, list[str]] = {cid: [] for cid in comments}
    open_ids: set[str] = set()
    body_words: list[str] = []
    for el in doc_xml.iter():
        tag = el.tag.split("}")[-1]
        if tag == "commentRangeStart":
            open_ids.add(el.get(f"{{{W_NS['w']}}}id", ""))
        elif tag == "commentRangeEnd":
            open_ids.discard(el.get(f"{{{W_NS['w']}}}id", ""))
        elif tag == "t" and el.text:
            body_words.append(el.text)
            for cid in open_ids:
                anchors.setdefault(cid, []).append(el.text)

    for i, (cid, ctext) in enumerate(sorted(comments.items(), key=lambda kv: int(kv[0]))):
        m = MARKER.search(ctext)
        if m:
            kind, body = m.group("kind").upper(), m.group("body")
        elif ":" in ctext and ctext.split(":", 1)[0].strip().upper() in VALID_KINDS:
            kind, body = ctext.split(":", 1)[0].strip().upper(), ctext.split(":", 1)[1]
        else:
            kind, body = "GFX", ctext
        parsed = parse_body(body, kind)
        anchor = strip_markdown("".join(anchors.get(cid, [])))
        cues.append(
            Cue(
                id=f"c{i+1:03d}",
                kind=kind,
                template=parsed.get("template") or parsed["kv"].get("template"),
                text=parsed["kv"].get("text") or anchor or " ".join(parsed.get("free", [])),
                assets=parsed["assets"],
                anchor=anchor,
                aspect=parsed["kv"].get("aspect", C.DEFAULT_ASPECT),
                notes=parsed["kv"].get("note", ""),
            )
        )
    return cues


# --------------------------------------------------------------------------------------
# Anchoring to the transcript
# --------------------------------------------------------------------------------------

def build_index(words: list[dict]) -> tuple[list[str], list[dict]]:
    return [norm(w["word"]) for w in words], words


def locate(anchor: str, tokens: list[str], words: list[dict], min_score: float = 0.62):
    """
    Slide a window the length of the anchor across the transcript and take the best match.
    Returns (time, score) or (None, 0.0) if nothing matches well enough — an unanchored cue
    is reported, never silently placed.
    """
    a_tokens = [t for t in norm(anchor).split() if t]
    if not a_tokens or not tokens:
        return None, 0.0
    n = min(len(a_tokens), 12)
    needle = " ".join(a_tokens[-n:])

    best_score, best_i = 0.0, -1
    for i in range(0, max(1, len(tokens) - n + 1)):
        hay = " ".join(tokens[i:i + n])
        if not hay:
            continue
        score = SequenceMatcher(None, needle, hay).ratio()
        if score > best_score:
            best_score, best_i = score, i
    if best_i < 0 or best_score < min_score:
        return None, best_score
    # Place at the END of the matched phrase — the graphic lands as she finishes saying it.
    end_idx = min(best_i + n - 1, len(words) - 1)
    return round(float(words[end_idx]["end"]), 3), round(best_score, 3)


def infer_template(cue: Cue) -> str | None:
    if cue.template:
        return cue.template
    return {
        "CHAPTER": "chapter_card",
        "GFX": "key_term",
    }.get(cue.kind)


def resolve(cues: list[Cue], words: list[dict]) -> list[Cue]:
    tokens, wl = build_index(words)
    for cue in cues:
        cue.template = infer_template(cue)
        if cue.kind == "NOTE":
            continue
        t, score = locate(cue.anchor, tokens, wl)
        if t is None:
            cue.unresolved = f"anchor not found in transcript (best match {score:.0%})"
            continue
        cue.start = t
        wc = len(cue.text.split())
        cue.hold = round(C.hold_seconds(wc), 2)
        cue.end = round(cue.start + cue.hold, 3)
    return cues


def check_collisions(cues: list[Cue]) -> list[str]:
    """Graphics need GRAPHIC_GAP_MS of clean frame between them (taste_principles §5.4)."""
    issues: list[str] = []
    timed = sorted([c for c in cues if c.start is not None and c.end is not None], key=lambda c: c.start)
    gap = C.GRAPHIC_GAP_MS / 1000.0
    for a, b in zip(timed, timed[1:]):
        if b.start < a.end + gap:
            issues.append(
                f"{a.id} ({a.end:.2f}s) and {b.id} ({b.start:.2f}s) are {b.start - a.end:.2f}s apart "
                f"— needs ≥{gap:.2f}s of clean frame"
            )
    return issues


def check_pacing(cues: list[Cue], duration: float) -> list[str]:
    """taste_principles §9 — first graphic by 0:30, a pattern interrupt at least every 45s."""
    issues: list[str] = []
    beats = sorted(c.start for c in cues if c.start is not None and c.kind in {"GFX", "BROLL", "MACRO", "CAM", "CHAPTER"})
    if not beats:
        return ["no timed visual beats at all"]
    if beats[0] > C.FIRST_GRAPHIC_BY_SECONDS:
        issues.append(f"first visual beat at {beats[0]:.0f}s — should land by {C.FIRST_GRAPHIC_BY_SECONDS}s")
    prev = 0.0
    for b in beats:
        if b - prev > C.PATTERN_INTERRUPT_MAX_SECONDS:
            issues.append(f"{b - prev:.0f}s with no pattern interrupt (ends at {b:.0f}s)")
        prev = b
    if duration - prev > C.PATTERN_INTERRUPT_MAX_SECONDS:
        issues.append(f"{duration - prev:.0f}s with no pattern interrupt before the end")
    return issues


def check_templates(cues: list[Cue]) -> list[str]:
    return [
        f"{c.id}: unknown template '{c.template}' (known: {', '.join(sorted(KNOWN_TEMPLATES))})"
        for c in cues
        if c.template and c.template not in KNOWN_TEMPLATES
    ]


# --------------------------------------------------------------------------------------
# Entry
# --------------------------------------------------------------------------------------

SCRIPT_SUFFIXES = (".docx", ".md", ".txt")


def _is_candidate(p: Path) -> bool:
    # "~$" is Word's lock file for an open document — never the script itself.
    return p.is_file() and p.suffix.lower() in SCRIPT_SUFFIXES and not p.name.startswith("~$")


def has_cue_marker(path: Path) -> bool:
    """
    Does this file actually carry a cue marker of a kind Stage 3 recognises?

    Discovery requires evidence; an explicit instruction does not (style_guide [S-009]).
    The previous denylist was open by default: every document added to the project
    became a candidate script, and alphabetical order meant CLAUDE.md won.
    """
    try:
        if path.suffix.lower() == ".docx":
            with zipfile.ZipFile(path) as z:
                if "word/comments.xml" not in set(z.namelist()):
                    return False
                text = "".join(
                    t.text or ""
                    for t in ET.fromstring(z.read("word/comments.xml")).iter(f"{{{W_NS['w']}}}t")
                )
        else:
            text = path.read_text(encoding="utf-8", errors="replace")
    except (OSError, ValueError, zipfile.BadZipFile, ET.ParseError):
        return False
    return any(m.group("kind").upper() in VALID_KINDS for m in MARKER.finditer(text))


def find_script() -> Path | None:
    """Auto-discovery scans script/ and nowhere else — it is the canonical location."""
    hits = sorted(p for p in C.SCRIPT_DIR.glob("*") if _is_candidate(p))
    return hits[0] if hits else None


def find_stray_scripts() -> list[Path]:
    """
    Root documents carrying a real cue marker, for when script/ is empty.

    This covers the failure symmetric to picking the wrong file: she saves the script
    to the project root, and Stage 3 reports "no annotated script found" while the file
    sits in plain sight. Naming them is all this does — a root file never becomes a plan.
    """
    return sorted(p for p in C.ROOT.glob("*") if _is_candidate(p) and has_cue_marker(p))


def main(argv: list[str] | None = None) -> int:
    cli.preflight()
    ap = argparse.ArgumentParser(description="Stage 3 — build the graphic plan from the script")
    ap.add_argument("script", nargs="?", help="annotated .docx / .md / .txt")
    ap.add_argument("--transcript", help="*.words.json to anchor against")
    ap.add_argument("--project", default="video001")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)

    # An ACTIVE correction still carrying placeholder text is a rule that
    # constrains nothing while looking like it does — style_guide [S-016]. Checked
    # before any work, so it stops the run at the top rather than after a render.
    CR.gate()

    # An explicit path is trusted and always wins — no evidence check ([S-009]).
    if args.script:
        script = cli.resolve_or_exit(
            args.script, expect=(".docx", ".md", ".txt"), label="annotated script")
    else:
        script = find_script()

    if not script:
        stray = find_stray_scripts()
        if stray:
            print("! script/ is empty, but these root file(s) contain cue markers:")
            for p in stray:
                print(f"    {p.name}")
            print("\n  If one of them is the annotated script, move it into script/ —")
            print("  that is the only location Stage 3 discovers. To use one where it is,")
            print(f"  pass it explicitly:  stage3_plan.py {stray[0].name}")
            return 1
        print("! no annotated script found — put one in script/ (.docx or .md)")
        return 1

    cues = parse_docx(script) if script.suffix.lower() == ".docx" else parse_markdown(script)
    if not cues:
        print(f"! {script.name} parsed, but no annotations found")
        print("  inline:  [[GFX: key_term | text=\"Gluten\" | asset=cutout:gluten_strand]]")
        print("  or add Word comments using the same syntax")
        return 1

    print(f"Stage 3 — {len(cues)} cue(s) from {script.name}")

    tpath = cli.resolve_or_exit(args.transcript, expect=(".json",), label="transcript") \
        if args.transcript else next(iter(sorted(C.TRANSCRIPTS.glob("*.words.json"))), None)
    duration = 0.0
    if tpath and tpath.exists():
        tdata = json.loads(tpath.read_text())
        words = tdata["words"]
        duration = tdata.get("duration", 0.0)
        cues = resolve(cues, words)
        print(f"  anchored against {tpath.name} ({len(words)} words, {duration:.0f}s)")
    else:
        print("  ! no transcript — cues parsed but not timed (run stage 1 first)")

    issues = check_templates(cues) + check_collisions(cues) + (check_pacing(cues, duration) if duration else [])
    unresolved = [c for c in cues if c.unresolved]

    for c in cues:
        when = f"{c.start:7.2f}s" if c.start is not None else "  ——   "
        hold = f" hold {c.hold:.1f}s" if c.hold else ""
        print(f"  {when}  {c.kind:<8} {c.template or '-':<14} {c.text[:44]!r}{hold}")

    if unresolved:
        print(f"\n  ! {len(unresolved)} cue(s) could not be anchored:")
        for c in unresolved:
            print(f"    {c.id}: {c.unresolved}\n      anchor: {c.anchor[:70]!r}")
    if issues:
        print(f"\n  ! {len(issues)} plan issue(s):")
        for i in issues:
            print(f"    - {i}")

    if args.dry_run:
        return 0

    out = C.PLAN_DIR / f"{args.project}.plan.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(
        {
            "project": args.project,
            "script": script.name,
            "transcript": tpath.name if tpath else None,
            "duration": duration,
            "fps": C.FPS,
            "cues": [asdict(c) for c in cues],
            "issues": issues,
            "unresolved": [c.id for c in unresolved],
        },
        indent=2,
    ))
    print(f"\nStage 3 complete → {C.path_label(out)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

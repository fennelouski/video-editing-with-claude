#!/usr/bin/env python3
"""Read-only contract check of a synthetic or user-selected local handoff."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from xml.etree import ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
import editorial_workflow as E
import fcpxml


def verify(folder):
    sources = [E.TranscriptSource.from_dict(s) for s in json.loads((folder / "engine-sources.json").read_text())]
    script = E.validate_script((folder / "engine-script.json").read_bytes(), sources)
    handoff = json.loads((folder / "script-handoff.json").read_text())
    problems = fcpxml.validate(folder / "assembly.fcpxml")
    if problems:
        raise ValueError("; ".join(problems))
    clips = ET.parse(folder / "assembly.fcpxml").findall(".//spine/asset-clip")
    assert len(clips) == len(script.segments) == len(handoff["spans"])
    for clip, span, segment in zip(clips, handoff["spans"], script.segments):
        assert span["sourceID"] == segment.source_id
        assert span["sourceSHA256"] == segment.source_sha256
        assert (span["requestedIn"], span["requestedOut"]) == (segment.start, segment.end)
        assert clip.attrib["start"] == f'{span["startFrame"] * 1001}/24000s'
        assert clip.attrib["offset"] == f'{span["timelineFrame"] * 1001}/24000s'
        assert clip.attrib["duration"] == f'{(span["endFrame"] - span["startFrame"]) * 1001}/24000s'
    assert handoff["reviewOnly"] and not handoff["appliedToCut"] and not handoff["productionAuthorized"]
    schema = None
    if fcpxml.FCP_DTD.exists():
        # libxml's external DTD loader mishandles the application path's spaces
        # on this host. Copy the exact bytes to an ephemeral local leaf.
        with tempfile.TemporaryDirectory(prefix="clauto-script-dtd-") as temp:
            dtd = Path(temp) / "FCPXML.dtd"
            dtd.write_bytes(fcpxml.FCP_DTD.read_bytes())
            result = subprocess.run(["/usr/bin/xmllint", "--noout", "--dtdvalid", str(dtd), str(folder / "assembly.fcpxml")], capture_output=True, text=True)
            if result.returncode:
                raise ValueError(result.stderr)
            schema = True
    return {"engine_script_valid": True, "fcpxml_structural_valid": True,
            "fcpxml_installed_dtd_valid": schema, "segments": len(clips),
            "source_order": [s.source_id for s in script.segments], "applied_to_cut": handoff["appliedToCut"],
            "scope": "Interchange verification; actual Final Cut import and subjective listening are not attested."}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("folder", type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.folder.resolve()), indent=2))

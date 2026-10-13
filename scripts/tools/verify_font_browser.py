"""
verify_font_browser.py — check the built font in a real browser, not just in the feature file.

    python scripts/tools/verify_font_browser.py assets/fonts/HerMarker.woff2 --char a

`HANDOFF_claude_code.md` item 1: *"FontForge and fontmake disagree about `calt` ordering;
verify in an actual browser render, not just by inspecting the feature file."* A feature file
that reads correctly can still compile to tables that do nothing, and the pytest suite shapes
with HarfBuzz directly — which cannot answer the one question that matters most in practice:

**Is `calt` on by default?** taste_principles §3.2 requires it, because "the pipeline will not
remember to enable it". Shaping with an explicit feature list always passes that test whether
or not the font would behave in a browser that was given no instructions. So the check here
renders the same string twice, once untouched and once with `"calt" 0`, and compares.

Chrome is driven headless over a `file://` page with the font inlined as a data URI. If Chrome
is not installed this exits 0 with a notice rather than failing — it is a verification tool,
and the deterministic coverage lives in `tests/test_build_font.py`.
"""

from __future__ import annotations

import argparse
import base64
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import cli  # noqa: E402


CHROME_CANDIDATES = (
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "google-chrome",
    "chromium",
)

PAGE = """<!doctype html><html><head><meta charset="utf-8">
<style>
@font-face {{ font-family:"Probe"; src:url(data:font/woff2;base64,{b64}) format("woff2"); }}
body {{ background:#F2EDE1; color:#4A3C2E; margin:0; padding:16px; }}
.m {{ font-family:"Probe"; font-size:96px; white-space:pre; display:inline-block; }}
.off {{ font-feature-settings:"calt" 0; }}
</style></head><body>
<div><span class="m" id="on">{run}</span></div>
<div><span class="m off" id="offd">{run}</span></div>
<canvas id="cv" width="1600" height="180"></canvas>
<pre id="out">running</pre>
<script>
function fnv(d){{let h=2166136261>>>0;for(let i=3;i<d.length;i+=4){{h^=d[i];h=Math.imul(h,16777619)>>>0;}}return h.toString(16);}}
async function run(){{
  const res={{}}, text={run!r};
  await document.fonts.load('96px Probe'); await document.fonts.ready;
  res.fontLoaded = document.fonts.check('96px Probe');

  // calt on by default: alternates carry their own advances, so substitution moves the width.
  const a=document.getElementById('on').getBoundingClientRect().width;
  const b=document.getElementById('offd').getBoundingClientRect().width;
  res.widthDefault=+a.toFixed(2); res.widthCaltOff=+b.toFixed(2);
  res.caltOnByDefault = Math.abs(a-b) > 0.5;

  // Adjacent rendered glyphs must differ, measured on actual pixels.
  const cv=document.getElementById('cv'), ctx=cv.getContext('2d',{{willReadFrequently:true}});
  ctx.font='96px Probe'; ctx.textBaseline='alphabetic'; ctx.fillStyle='#4A3C2E';
  const xs=[]; for(let i=0;i<=text.length;i++) xs.push(ctx.measureText(text.slice(0,i)).width);
  ctx.clearRect(0,0,cv.width,cv.height); ctx.fillText(text,10,140);
  const hashes=[];
  for(let i=0;i<text.length;i++){{
    const x0=Math.max(0,Math.floor(10+xs[i])), w=Math.max(1,Math.ceil(xs[i+1]-xs[i]));
    hashes.push(fnv(ctx.getImageData(x0,20,w,150).data));
  }}
  res.glyphHashes=hashes;
  res.adjacentAllDiffer = hashes.every((h,i)=> i===0 || h!==hashes[i-1]);
  res.distinctForms = new Set(hashes).size;
  // Guard: hashing a blank canvas would make every check pass for the wrong reason.
  res.renderedSomething = new Set(hashes).size > 1 || hashes[0] !== '811c9dc5';
  document.getElementById('out').textContent='RESULT '+JSON.stringify(res);
}}
run().catch(e=>{{document.getElementById('out').textContent='RESULT {{"error":"'+e+'"}}';}});
</script></body></html>"""


def find_chrome() -> str | None:
    for candidate in CHROME_CANDIDATES:
        if Path(candidate).exists():
            return candidate
        found = shutil.which(candidate)
        if found:
            return found
    return None


def probe(woff2: Path, run: str, chrome: str) -> dict:
    b64 = base64.b64encode(woff2.read_bytes()).decode()
    with tempfile.TemporaryDirectory() as tmp:
        page = Path(tmp) / "probe.html"
        page.write_text(PAGE.format(b64=b64, run=run))
        proc = subprocess.run(
            [chrome, "--headless=new", "--disable-gpu", "--no-sandbox",
             "--virtual-time-budget=8000", "--dump-dom", page.as_uri()],
            capture_output=True, text=True, timeout=120,
        )
    match = re.search(r"RESULT (\{.*?\})", proc.stdout, re.S)
    if not match:
        raise RuntimeError(f"no result from the page; Chrome said:\n{proc.stderr[-800:]}")
    return json.loads(match.group(1))


def main(argv: list[str] | None = None) -> int:
    cli.preflight()
    ap = argparse.ArgumentParser(description="Verify calt in a real browser render")
    ap.add_argument("woff2", type=Path)
    ap.add_argument("--char", default="a", help="character to repeat")
    ap.add_argument("--repeat", type=int, default=6)
    args = ap.parse_args(argv)

    woff2 = cli.resolve_or_exit(args.woff2, expect=(".woff2", ".ttf"), label="font")

    chrome = find_chrome()
    if not chrome:
        print("- Chrome not found; skipping the browser check.")
        print("  tests/test_build_font.py covers shaping deterministically without it.")
        return 0

    run = args.char * args.repeat
    print(f"Rendering {run!r} in {Path(chrome).name}")
    result = probe(woff2, run, chrome)
    if "error" in result:
        print(f"! page error: {result['error']}")
        return 1

    for key, value in result.items():
        print(f"  {key}: {value}")

    checks = {
        "font loaded from woff2": result.get("fontLoaded"),
        "something actually rendered": result.get("renderedSomething"),
        "calt is on by default (§3.2)": result.get("caltOnByDefault"),
        "adjacent glyphs all differ": result.get("adjacentAllDiffer"),
        f"{args.repeat} distinct forms": result.get("distinctForms") == args.repeat,
    }
    print()
    for label, ok in checks.items():
        print(f"  {'✓' if ok else '✗'} {label}")

    if all(checks.values()):
        print("\nBrowser render agrees with the shaping tests.")
        return 0
    print("\n! the browser disagrees with the feature file — this is the case the handoff warns "
          "about, and the font is not shippable until it is resolved.")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())

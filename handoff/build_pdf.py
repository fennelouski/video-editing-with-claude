"""
build_pdf.py — the printable version of the same two lists.

    .venv/bin/python handoff/build_pdf.py

Generated from `content.py`, the same module the video is built from, so the two deliverables
cannot drift apart. Rendered through headless Chrome, which gives real typography and page
breaks without adding a PDF library.

The video is for deciding to start; this is for having on the desk while working. So it carries
the full character set — every glyph she needs, at a size she can read across a table — where
the video only shows enough of each row to make the point.
"""

from __future__ import annotations

import html
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "scripts"))
sys.path.insert(0, str(HERE))

import config as C          # noqa: E402
import content as CONTENT   # noqa: E402

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

CSS = """
@page { size: letter; margin: 16mm 15mm; }
:root {
  --bone:%(bone)s; --oat:%(oat)s; --kraft:%(kraft)s; --sage:%(sage)s;
  --moss:%(moss)s; --rust:%(rust)s; --walnut:%(walnut)s; --ink:%(ink)s; --stone:%(stone)s;
}
* { box-sizing: border-box; }
body { margin:0; font-family: Charter, Georgia, serif; font-size:10.2pt; line-height:1.45;
       color:var(--walnut); background:var(--bone); }
h1 { font-family:"Avenir Next",sans-serif; font-size:24pt; margin:0 0 1mm; color:var(--ink);
     letter-spacing:-0.01em; }
.sub { font-size:10.5pt; color:var(--stone); font-style:italic; margin:0 0 6mm; }
h2 { font-family:"Avenir Next",sans-serif; font-size:15pt; margin:0 0 1mm; color:var(--ink); }
.eyebrow { font-family:"Avenir Next",sans-serif; font-size:8.4pt; letter-spacing:.07em;
           text-transform:uppercase; color:var(--rust); margin:0 0 2mm; }
.tier { border:1pt solid var(--kraft); border-left:4pt solid var(--sage);
        background:rgba(232,223,200,.4); padding:5mm 6mm; margin:0 0 5mm; break-inside:avoid; }
.tier .amount { font-family:"Avenir Next",sans-serif; font-size:14pt; color:var(--ink); }
.tier .target { font-size:9.4pt; color:var(--rust); font-family:"Avenir Next",sans-serif; }
.tier .blurb { font-size:9.6pt; color:var(--moss); margin:1.5mm 0 3mm; }
.row { margin:0 0 2.6mm; }
.row .name { font-family:"Avenir Next",sans-serif; font-size:9.2pt; color:var(--stone);
             text-transform:uppercase; letter-spacing:.05em; }
.glyphs { font-family:"Arial Unicode MS","Menlo",monospace; font-size:15pt; color:var(--ink);
          letter-spacing:.10em; margin:.6mm 0 0; }
.row .note { font-size:9pt; color:var(--moss); margin:.8mm 0 0; }
.shortcut { background:var(--oat); border-left:3pt solid var(--rust); padding:4mm 5mm;
            margin:0 0 5mm; font-size:10pt; break-inside:avoid; }
.rules { margin:0 0 6mm; }
.rules li { margin-bottom:2mm; }
.rec { border:1pt solid var(--kraft); border-left:4pt solid var(--moss);
       background:rgba(232,223,200,.4); padding:5mm 6mm; margin:0 0 5mm; break-inside:avoid; }
.rec .why { font-size:9.4pt; color:var(--moss); margin:1.5mm 0 2.5mm; }
ol,ul { margin:2mm 0 0; padding-left:5mm; }
li { margin-bottom:1.4mm; }
b,strong { color:var(--ink); }
.footer { margin-top:6mm; padding-top:2.5mm; border-top:.8pt solid var(--kraft);
          font-size:9pt; color:var(--stone); }
.page-break { break-before:page; }
""" % C.PALETTE


def esc(text: str) -> str:
    return html.escape(text, quote=False)


def build_html() -> str:
    parts = [
        "<!doctype html><html lang='en'><head><meta charset='utf-8'>",
        "<title>What to make</title><style>", CSS, "</style></head><body>",
        "<h1>What to letter, what to film</h1>",
        "<p class='sub'>Two lists. The lettering is the long one — do it in whatever order "
        "suits you, but the first tier is where all the value is.</p>",
        f"<div class='shortcut'><b>Before you start:</b> {esc(CONTENT.CAPS_ONLY_NOTE)}</div>",
    ]

    parts.append("<p class='eyebrow'>List one &middot; the lettering</p>")
    for tier in CONTENT.TIERS:
        parts.append("<div class='tier'>")
        parts.append(f"<div><span class='amount'>{esc(tier.amount)}</span> "
                     f"<span class='target'>— {esc(tier.target)}</span></div>")
        parts.append(f"<p class='blurb'>{esc(tier.blurb)}</p>")
        for group in tier.groups:
            parts.append("<div class='row'>")
            parts.append(f"<div class='name'>{esc(group.title)}</div>")
            parts.append(f"<div class='glyphs'>{esc(group.glyphs)}</div>")
            if group.note:
                parts.append(f"<div class='note'>{esc(group.note)}</div>")
            parts.append("</div>")
        parts.append("</div>")

    parts.append("<div class='rules'><p class='eyebrow'>However you do it</p><ul>")
    for title, why in CONTENT.LETTERING_RULES:
        parts.append(f"<li><b>{esc(title)}.</b> {esc(why)}</li>")
    parts.append("</ul></div>")

    parts.append("<div class='page-break'></div>")
    parts.append("<p class='eyebrow'>List two &middot; the filming</p>")
    parts.append("<p class='sub' style='margin-bottom:5mm'>Three recordings. None of this has "
                 "been tested against real footage yet — only against audio I synthesised, "
                 "which by definition matches my own assumptions and finds nothing.</p>")
    for rec in CONTENT.RECORDINGS:
        parts.append("<div class='rec'>")
        parts.append(f"<h2>{esc(rec.title)}</h2>")
        parts.append(f"<div class='name' style='color:var(--rust)'>{esc(rec.length)}</div>")
        parts.append(f"<p class='why'>{esc(rec.why)}</p><ol>")
        for step in rec.steps:
            parts.append(f"<li>{esc(step)}</li>")
        parts.append("</ol></div>")

    parts.append(f"<div class='footer'>{esc(CONTENT.CLOSING)}</div>")
    parts.append("</body></html>")
    return "\n".join(parts)


def main() -> int:
    source = HERE / ".build" / "for-her.html"
    source.parent.mkdir(exist_ok=True)
    source.write_text(build_html(), encoding="utf-8")

    out = HERE / "what-to-make-first.pdf"
    result = subprocess.run(
        [CHROME, "--headless=new", "--disable-gpu", "--no-sandbox",
         "--virtual-time-budget=8000", "--no-pdf-header-footer",
         f"--print-to-pdf={out}", source.as_uri()],
        capture_output=True, text=True, timeout=120)
    if not out.exists():
        print("! Chrome did not produce a PDF:\n" + result.stderr[-500:])
        return 1

    pages = out.read_bytes().count(b"/Type /Page") or out.read_bytes().count(b"/Type/Page")
    print(f"  {out.name} — {out.stat().st_size // 1024} KB, ~{pages} page(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

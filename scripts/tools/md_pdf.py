"""
md_pdf.py — a build sheet someone can print, hand over, or read on a phone.

Stage 4 already produces build sheets and every video will produce another, so the conversion
belongs in the repo rather than in whatever was on the machine that day. It converts the subset
of Markdown these documents actually use — headings, tables, lists, block quotes, rules, bold,
italic, inline code — and stops there. A general Markdown implementation is a dependency, and
`pandoc` was not installed; twelve rules of regex were.

Rendering goes through headless Chrome, which is on this machine and honours real CSS.
`cupsfilter`, the other thing macOS ships, produced a zero-byte file on the first attempt.

    ./run tools/md_pdf.py cuts/intro001/build-sheet.md
"""

from __future__ import annotations

import argparse
import html
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import cli
import config as C

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

P = C.PALETTE
CSS = f"""
@page {{ size: A4; margin: 18mm 16mm; }}
* {{ box-sizing: border-box; }}
body {{ font: 10.5pt/1.55 -apple-system, "Helvetica Neue", sans-serif;
        color: {P['ink']}; background: {P['bone']}; margin: 0; }}
h1 {{ font-size: 21pt; margin: 0 0 2mm; color: {P['walnut']}; letter-spacing: -0.01em; }}
h2 {{ font-size: 14pt; margin: 9mm 0 3mm; padding-bottom: 1.5mm; color: {P['moss']};
      border-bottom: 1.5px solid {P['sage']}; break-after: avoid; }}
h3 {{ font-size: 11.5pt; margin: 6mm 0 2mm; color: {P['walnut']}; break-after: avoid; }}
p {{ margin: 0 0 2.5mm; }}
strong {{ color: {P['walnut']}; }}
code {{ font: 9.5pt/1.4 ui-monospace, Menlo, monospace; background: {P['oat']};
        padding: 0.4mm 1.2mm; border-radius: 1.5px;
        /* break-word, not anywhere: `anywhere` lets the column size itself to one character,
           which chopped `assets/textures/paper-grain.png` across three lines in a cell that
           had room for it. This keeps the path whole unless it genuinely cannot fit. */
        overflow-wrap: break-word; }}
del {{ color: {P['stone']}; }}
pre {{ background: {P['oat']}; padding: 3mm; border-radius: 2px; overflow-x: auto;
       border-left: 2.5px solid {P['kraft']}; }}
pre code {{ background: none; padding: 0; }}
hr {{ border: 0; border-top: 1px solid {P['kraft']}; margin: 7mm 0; }}
blockquote {{ margin: 0 0 3mm; padding: 0 0 0 4mm; border-left: 2.5px solid {P['sage']};
              color: {P['walnut']}; }}
ul, ol {{ margin: 0 0 3mm; padding-left: 5mm; }}
li {{ margin-bottom: 1mm; }}
table {{ border-collapse: collapse; width: 100%; margin: 0 0 4mm; font-size: 9.5pt;
         break-inside: auto; }}
th {{ background: {P['sage']}; color: {P['bone']}; text-align: left; font-weight: 600;
      padding: 1.8mm 2.2mm; }}
td {{ padding: 1.8mm 2.2mm; border-bottom: 1px solid {P['oat']}; vertical-align: top; }}
tr {{ break-inside: avoid; }}
tbody tr:nth-child(even) td {{ background: rgba(203,184,147,0.16); }}
td:first-child {{ color: {P['rust']}; font-weight: 600; white-space: nowrap; }}
"""


def inline(text: str) -> str:
    """Escape first, then re-introduce only the marks we chose to support."""
    out = html.escape(text)
    out = re.sub(r"`([^`]+)`", r"<code>\1</code>", out)
    out = re.sub(r"~~([^~]+)~~", r"<del>\1</del>", out)
    out = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", out)
    out = re.sub(r"(?<![*\w])\*([^*]+)\*(?!\*)", r"<em>\1</em>", out)
    return out


def row(line: str) -> list[str]:
    return [c.strip() for c in line.strip().strip("|").split("|")]


def to_html(md: str, title: str) -> str:
    body: list[str] = []
    lines = md.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()

        if not stripped:
            i += 1
        elif stripped.startswith("```"):
            block = []
            i += 1
            while i < len(lines) and not lines[i].strip().startswith("```"):
                block.append(html.escape(lines[i]))
                i += 1
            i += 1
            body.append("<pre><code>" + "\n".join(block) + "</code></pre>")
        elif re.fullmatch(r"-{3,}", stripped):
            body.append("<hr>")
            i += 1
        elif m := re.match(r"(#{1,3})\s+(.*)", stripped):
            body.append(f"<h{len(m[1])}>{inline(m[2])}</h{len(m[1])}>")
            i += 1
        elif stripped.startswith("|"):
            head = row(stripped)
            i += 1
            # The separator row is what distinguishes a table from a line that starts with a pipe.
            if i < len(lines) and re.fullmatch(r"\|[\s:|-]+\|", lines[i].strip()):
                i += 1
                cells = "".join(f"<th>{inline(c)}</th>" for c in head)
                rows = [f"<tr>{cells}</tr>"]
                while i < len(lines) and lines[i].strip().startswith("|"):
                    tds = "".join(f"<td>{inline(c)}</td>" for c in row(lines[i]))
                    rows.append(f"<tr>{tds}</tr>")
                    i += 1
                body.append(f"<table><thead>{rows[0]}</thead><tbody>"
                            + "".join(rows[1:]) + "</tbody></table>")
            else:
                body.append(f"<p>{inline(stripped)}</p>")
        elif stripped.startswith(">"):
            quote = []
            while i < len(lines) and lines[i].strip().startswith(">"):
                quote.append(lines[i].strip().lstrip(">").strip())
                i += 1
            paras = " ".join(quote).split("  ")
            body.append("<blockquote>"
                        + "".join(f"<p>{inline(p)}</p>" for p in paras if p.strip())
                        + "</blockquote>")
        elif re.match(r"[-*]\s+|\d+\.\s+", stripped):
            ordered = bool(re.match(r"\d+\.\s+", stripped))
            items = []
            while i < len(lines) and re.match(r"\s*([-*]|\d+\.)\s+", lines[i]):
                items.append(re.sub(r"\s*([-*]|\d+\.)\s+", "", lines[i], count=1))
                i += 1
                # A wrapped continuation line is indented and belongs to the item above it.
                while i < len(lines) and lines[i].startswith("  ") and lines[i].strip() \
                        and not re.match(r"\s*([-*]|\d+\.)\s+", lines[i]):
                    items[-1] += " " + lines[i].strip()
                    i += 1
            tag = "ol" if ordered else "ul"
            body.append(f"<{tag}>" + "".join(f"<li>{inline(x)}</li>" for x in items) + f"</{tag}>")
        else:
            para = []
            while i < len(lines) and lines[i].strip() and not re.match(
                    r"\s*(#{1,3}\s|\||>|```|-{3,}$|[-*]\s|\d+\.\s)", lines[i]):
                para.append(lines[i].strip())
                i += 1
            body.append(f"<p>{inline(' '.join(para))}</p>")

    return (f"<!doctype html><html><head><meta charset='utf-8'><title>{html.escape(title)}</title>"
            f"<style>{CSS}</style></head><body>{''.join(body)}</body></html>")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Markdown → PDF, via headless Chrome")
    ap.add_argument("source", help="a .md file")
    ap.add_argument("-o", "--out", help="output .pdf (default: alongside the source)")
    args = ap.parse_args(argv)

    src = cli.resolve_or_exit(args.source, expect=(".md", ".markdown"), label="markdown file")
    # Absolute, because Chrome is handed a file:// URI and a relative path has no such thing.
    out = (Path(args.out).expanduser() if args.out else src.with_suffix(".pdf")).resolve()

    chrome = CHROME if Path(CHROME).exists() else shutil.which("google-chrome")
    if not chrome:
        raise SystemExit("! headless Chrome renders the PDF and it is not installed.\n"
                         f"  Looked for {CHROME}. Install Chrome, or open the .md yourself.")

    html_path = out.with_suffix(".html")
    html_path.write_text(to_html(src.read_text(encoding="utf-8"), src.stem), encoding="utf-8")
    try:
        proc = subprocess.run(
            [chrome, "--headless=new", "--disable-gpu", "--no-pdf-header-footer",
             "--virtual-time-budget=4000", f"--print-to-pdf={out}", html_path.as_uri()],
            capture_output=True, text=True)
        if not out.exists() or out.stat().st_size == 0:
            raise SystemExit(f"! Chrome wrote no PDF:\n{proc.stderr[-600:]}")
    finally:
        html_path.unlink(missing_ok=True)

    print(f"  ✓ {out}  ({out.stat().st_size / 1024:.0f} kB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

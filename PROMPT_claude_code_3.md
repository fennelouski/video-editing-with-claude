# Prompt for Claude Code — round three

Copy everything below the line into Claude Code, run from `~/Documents/Videos`.

---

Stop handing me commands to run. You have terminal access; use it.

I pasted a command you gave me and got a stack trace, then relayed the stack trace back to you.
That round trip should not have existed. Two separate things went wrong and I want both fixed
as a class, not as instances.

## What actually happened

1. The Final Cut export is a **`.fcpxmld` bundle** — a directory containing `Info.fcpxml`. That
   is what FCP 11 produces by default, so it is what any human will hand any tool here. The
   script raised `IsADirectoryError` with a traceback.
2. `python` isn't on my PATH and `python3` is macOS's system 3.9 from Xcode, not the project
   venv. Nothing detected that or said so.

I've added two conventions to `CLAUDE.md` covering this. Read them before you start.

## 1. Do the work yourself

The export is sitting at `~/Desktop/smoke 9:16.fcpxmld`. Read it, run the inspection, and tell
me what Final Cut resolved `FFVideoFormatRateUndefined` to. Don't give me a command — run it.

From here on, ask me only for things that physically require me: clicking in a GUI, shooting
footage, or looking at rendered pixels. Everything else is yours.

That includes the caption check still outstanding. If importing the `.itt` genuinely requires
the Final Cut GUI, say so and tell me the two clicks — but check first whether you can verify
it another way, the same way reading the library SQLite replaced screenshot-reading.

## 2. Fix the class, not the instance

**Every entry point that takes a path from a human** must accept what a human will actually
hand it:

- `.fcpxmld` bundles → resolve the inner XML.
- A directory that isn't a bundle → say so in one sentence, don't traceback.
- Paths with spaces, colons, trailing slashes, `~`, and Finder aliases.
- A file that's the wrong kind entirely → name what it is and what was expected.

**Every entry point must check its interpreter.** If it's running outside the venv, or under a
Python that can't import the dependencies, say that in one line naming the fix — not an
`ImportError` forty frames deep. Consider a `./run` wrapper that always uses `.venv/bin/python`
so there is one correct invocation and it can't be got wrong.

**Then audit every other entry point for the same class of problem.** `run_pipeline.py`, all six
stages, `roundtrip.py`, `segment_sheet.py`, `build_font.py`, `smoke_package.py`, and anything
else that takes an argument. I want the fix applied everywhere it applies, not just where it
broke. Report what you found — if some were already fine, say which.

Add tests. A bundle path, a bare directory, a nonexistent path, and a wrong-type file should
each produce a clean one-line error and a non-zero exit, on every entry point.

## 3. Then carry on

Phase 7 (foley) as previously scoped, then Phase 8 (real footage — I'll shoot the clip when you
ask) and Phase 9 (camera matching, face detection).

Standing instructions unchanged: commit per phase with the reasoning, add a test for every bug
fixed, update the documents when a rule changes, and tell me when something in the spec is wrong
rather than working around it.

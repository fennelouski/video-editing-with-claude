# UX

One window, a sidebar, and a drop-friendly main area. Native SwiftUI, macOS 26 target as set in
the Xcode project (lower it if older Macs matter).

## 1. First launch: Setup

A full-window checklist. Each row has a state (waiting, working, done, needs you) and a Details
disclosure showing the live command output for people who care.

| Step | What happens | If it fails |
|---|---|---|
| Welcome | One sentence on what will be installed and roughly how big. Button: **Set Up** | |
| Homebrew | Detect `brew`. If missing, run the official installer; it needs an admin password and the Xcode Command Line Tools, so the app explains that first. | "Homebrew needs your Mac password" with a retry button |
| Tools | `brew install ffmpeg git python@3.11` | Show the failing package and a Retry |
| Claude Code | Detect `claude`. If missing, run Anthropic's installer (`claude install` once any bootstrap is present). | Link to install help |
| Sign in | `claude auth status`; if signed out, run `claude auth login` and show "Finish signing in in your browser". Poll status. | Retry; explain plan requirement |
| Engine | Clone this repo at a pinned tag to `~/Library/Application Support/Clauto Editor/engine`, create the venv, `pip install -r requirements.txt` | Retry; show last 20 log lines |
| Folders | Pick where **footage**, **assets**, **build** and **cuts** live. Defaults suggested; each has a Choose... button and a drop target. Writes `paths.json` in the engine (the same file `./run setup.py` writes). | |
| Check | Run `./run run_pipeline.py --dry-run` and translate preflight into green ticks. | Each red item has a fix button |

Setup is re-enterable from Settings, and every step is idempotent: running it twice changes
nothing.

## 2. Project list

Sidebar: projects with thumbnail, name, last edited, status chip (Draft, Needs assets, Cut ready,
Exported). **New Project** at the top. Empty state is a large drop zone: "Drop your footage here
to start".

## 3. New project

Two fields only: name and where footage is (drop a folder or files, or "Use the footage folder").
Everything else is filled in on the Brief screen, so starting is never blocked by decisions.

## 4. Project screen

Three tabs: **Brief**, **Files**, **Cut**. A persistent **Ask Claude** bar sits at the bottom of
all three.

### Brief

A form that doubles as the first message to Claude.

- **What is this video about?** Long text box.
- **Who is it for, and how long?** Audience, target length, aspect ratio (16:9 or 9:16).
- **Music.** Mood chips (calm, upbeat, curious...) plus free text, or drop a track. Only
  user-supplied or licensed files are used; the app says so.
- **Graphics.** Describe what you want shown; drop images; choose from the engine's templates
  (chapter card, key term, lower third, diagram, gauge, comparison, stat, quote).
- **Script.** Paste, type, or drop a `.md`, `.txt` or `.docx`. If there is no script, Claude drafts
  an annotated one from the brief and the transcript for the user to approve.
- **Avoid.** Things not to do.

The brief saves continuously to `brief.md` in the project. Changing it later marks the cut stale.

### Files

A grid of everything in the project, grouped: Footage, Audio, Music, Graphics, Scripts, Other.

- Drop anywhere. The app classifies by type (video, audio, image, text/doc) and shows where it
  put each file. Dropping on a group overrides classification. Ambiguous files (a WAV could be
  music or room tone) get a one-click "What is this?" chip.
- Footage is **referenced in place** by default, with an option to copy. The app never moves
  originals.
- Dropped text files are read and shown with a one-line summary Claude wrote, and can be marked
  "this is the script", "notes", or "reference".
- Each file has Reveal in Finder, Replace and Remove (removes the reference, never the file).

### Cut

- **Run** button with stage progress (Transcribe, Rough cut, Plan, Assets, Render). Each stage shows
  time elapsed and a plain-language line from the engine.
- **Needs assets:** when stage 4 stops, the build sheet becomes a checklist. Each item is a drop
  target: drop the file and the item ticks. "Run again" resumes from stage 4.
- **Needs your answer:** escalations (a claimed temperature, a mechanism) appear as cards with the
  claim, where it is in the script, and Confirm / Edit / Cut it.
- **Result:** preview player for the rough cut, the list of cut points with the reason for each, a
  transcript read back from the rendered audio, and buttons: Open in Final Cut Pro, Reveal in
  Finder, Export PDF of script and shot list.

## 5. Iterating

The **Ask Claude** bar is a conversation, not a form.

- The user types "make the intro shorter" or "the music is too busy under my voice".
- The app sends it to the project's Claude session with the current cut as context. Claude edits
  the picks, brief or script, reruns the needed stages (not the whole pipeline), and replies.
- Each run creates a **version** (v1, v2, ...) with the user's message as its label. A version list
  lets the user compare, restore, or branch.
- Suggestions appear as chips under the reply ("Shorter", "Different music", "More graphics") but
  free text is always the primary path.
- Stop button cancels the running process cleanly. Closing the window does not kill a run; it keeps
  going and posts a notification when done.

## 6. Settings

Folders, engine version and update, Claude account (sign out), default aspect and model choice,
"Show Details by default" toggle, Open engine folder, Collect diagnostics (zips logs for support;
nothing uploaded automatically).

## Copy and tone

Plain sentences, no jargon in the main UI ("cut points", not "EDL"; "missing pieces", not "assets
gate"). Every error: what happened, what to do, one button. Details are one click away, never
forced.

## Accessibility

Full keyboard operation, VoiceOver labels on every drop zone (with a Choose... button equivalent,
since drag and drop alone excludes people), respects Reduce Motion, no information by colour alone.

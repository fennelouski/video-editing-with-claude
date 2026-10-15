# Clauto Editor

A macOS app that lets someone make an edited video with Claude Code without ever opening Terminal.

Clauto Editor is the front door to the pipeline in this repo. It installs the tools, asks the
questions, takes the files, runs Claude Code in the background, and shows the result. The user
describes the video; Claude does the editing; the user reacts and asks for changes.

| Doc | Read it for |
|---|---|
| [PRODUCT.md](PRODUCT.md) | Who it is for, what it does, what it deliberately does not, open questions |
| [UX.md](UX.md) | Screens and flows: setup, new project, brief, drag and drop, iterate |
| [ARCHITECTURE.md](ARCHITECTURE.md) | How the app drives Claude Code, project folder format, installer, security |
| [ROADMAP.md](ROADMAP.md) | Milestones in build order, with what "done" means for each |
| [IMPLEMENTATION.md](IMPLEMENTATION.md) | Tested milestones, remaining requirements and acceptance limits |
| [VOICE_REVIEW.md](VOICE_REVIEW.md) | Explicit local voice review, saved-version timing, durable feedback and candidate instructions |

## The one-paragraph version

The app owns three things: **the machine** (Homebrew tools, Python environment, Claude Code, the
engine checkout), **the project folder** (footage, brief, script, music, graphics, outputs), and
**the conversation** (one Claude Code session per project, started and resumed with
`claude -p --output-format stream-json`). Everything the user types or drops becomes a file in the
project folder plus a message to Claude. Claude's replies and the pipeline's progress stream back
into the UI. The user never sees a command line unless they open the "Details" drawer.

## Ground rules

- **Not sandboxed.** The app launches `brew`, `python`, `ffmpeg` and `claude` and reads files
  anywhere the user points it. `ENABLE_APP_SANDBOX` is `NO` in the Xcode project. Distribution is
  Developer ID plus notarization (hardened runtime on), not the Mac App Store.
- **Files, not a database, are the source of truth.** A project is a folder a person could open in
  Finder and understand. SwiftData is allowed for the project list and UI state only.
- **The engine is this repo.** The app does not reimplement the pipeline. It installs it, pins it
  to a version, and calls it. Improvements to editing behaviour belong in the engine docs
  (`taste_principles.md`, `style_guide.md`), not in Swift.
- **Original footage is never modified, moved or uploaded by the app.** Projects reference it in
  place unless the user chooses to copy it in.

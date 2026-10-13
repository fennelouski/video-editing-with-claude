# Product

## Who it is for

Someone who films video but does not want to learn an editor or a command line. The first user is
the channel host this pipeline was built for; the second is anyone given the app by a friend. They
are comfortable with Finder and drag and drop. They are not comfortable with `brew` or
"permission denied".

## The job

> "Here is my footage and what I want. Make a first cut. Now change this."

Three promises:

1. **Setup is one window.** Open the app, press a button, wait. At the end everything works or the
   app says in one sentence what is wrong and offers the fix.
2. **Describing a video is typing and dropping.** No config files, no folder conventions to learn.
3. **Iteration is conversation.** Each change request is a message. Each result is a new, named,
   revertable version.

## What the app does

| Area | Behaviour |
|---|---|
| Setup | Detects and installs Homebrew, `ffmpeg`, `git`, Python 3.11, Claude Code, the engine and its venv. Signs the user in to Claude. Chooses where projects and footage live (the same four folders as `paths.json`: footage, assets, build, cuts). |
| Projects | Create, list, open, duplicate, archive. A project is a folder (see ARCHITECTURE). |
| Brief | A form plus free text: what the video is about, audience, length, aspect (16:9 / 9:16), tone, music wishes, graphics wishes, things to avoid. |
| Files | Drag and drop footage, audio, music, images, scripts, `.txt`/`.md`/`.docx`. The app sorts each into the right folder and tells Claude what arrived. |
| Run | Runs the pipeline stages, shows progress per stage, and surfaces the **build sheet** (missing assets) as a checklist the user can satisfy by dropping files. |
| Iterate | A chat-style panel: "tighten the intro", "swap the music for something calmer". Each turn produces a new version of the cut. |
| Output | Final Cut Pro FCPXML, captions, a preview MP4, and the script and shot list as PDFs. Reveal in Finder, open in Final Cut. |
| Review | Shows what Claude changed and why (the stage 2 join markers, the read-back transcript) so the user can trust or reject it. |

## What it deliberately does not do

- **No timeline editor.** The app does not compete with Final Cut. Fine editing happens there, from
  the FCPXML. The app is for briefing, first cuts, and iteration by instruction.
- **No generated footage or imagery.** The engine's rule (`style_guide.md` [S-001]) carries over.
  Missing assets produce a build sheet, never an AI substitute.
- **No cloud service, accounts, or telemetry in v1.** Footage never leaves the Mac except as
  Claude Code sends context to Anthropic under the user's own Claude login.
- **No store distribution, no sandbox.** Distribution is a notarized DMG from nathanfennel.com.
- **No silent decisions about facts.** Anything scientific or numeric is escalated to the user
  (`config.ESCALATE_TO_HUMAN`); the UI shows these as "Needs your answer" cards.

## Conflict with the engine's rules

`CLAUDE.md` says "Don't add a web UI. Two people use this, both comfortable in a terminal."
Clauto Editor is a native app, not a web UI, and it widens the audience, so that line is updated.
The rest of the engine's non-negotiables stand and the app must not work around them: no flattened
masters, 23.976 timebase, 120 ms silence floor, no generated assets, chemistry escalated.

## The look is currently one look

The engine encodes a single house style (cut cardboard, marker on paper, Sage and Oat palette).
For v1 the app ships that look and says so plainly. Supporting other looks needs the engine to
grow a "style pack" (palette, fonts, textures, rules) that `config.py` loads instead of constants.
That is an engine change, tracked in ROADMAP M6, not an app feature.

## Success measures

- A new user on a clean Mac reaches a first rough cut with no Terminal use.
- Median setup time under 15 minutes on a normal connection (WhisperX and its model are the large
  downloads).
- Every failure shows one sentence plus a button. No raw stack traces in the main UI.
- Re-running the same brief on the same footage yields the same cut (the engine is deterministic).

## Decisions

- **Whisper model is the user's choice at setup.** The download is accepted; the app offers the
  trade-off instead of forcing the largest model (see UX.md, Setup, "Transcription model").
- **Updates use Sparkle**, the same mechanism and signing setup as Straight Up Browser. See
  ARCHITECTURE.md, "Updates".
- **Bundle id stays `com.nathanfennel.Clauto-Editor`.**
- **Engine updates are separate from app updates:** pinned tagged releases, applied on consent.

## Open questions

1. **Whose Claude.** The app uses the user's own Claude login. Does the user need a paid plan, and
   what does the app do when a rate limit hits mid-run? (Plan: pause, show reset time, resume.)
2. **Other editors.** Final Cut only for now because the engine emits FCPXML. DaVinci and Premiere
   import FCPXML or XML with caveats; deferred.
3. **Her assets.** The cutouts, textures and marker font are one person's scans. A second user
   needs either their own or a bundled neutral set. Decide before M6.
4. **Sparkle key sharing.** Reuse the Browser's EdDSA key or generate a separate one (see
   ARCHITECTURE.md, "Updates").

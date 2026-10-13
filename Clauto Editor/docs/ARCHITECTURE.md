# Architecture

## Shape

```
Clauto Editor.app (SwiftUI, not sandboxed)
 ├─ SetupService      detect / install brew, tools, claude, engine, venv
 ├─ ProjectStore      project folders on disk + SwiftData index for the sidebar
 ├─ FileIntake        classify dropped files, place or reference them
 ├─ ClaudeSession     one per project: spawns `claude`, streams events
 ├─ PipelineRunner    runs engine stages via ./run, parses progress
 └─ VersionStore      snapshots of cut outputs per iteration
        │ spawns
        ▼
   claude (Claude Code CLI)  ──reads/writes──►  project folder + engine
        │ runs
        ▼
   engine (this repo): ./run run_pipeline.py ...  → ffmpeg, python, WhisperX
```

Swift owns UI, process supervision and file handling. Claude Code owns judgement and edits to the
brief, script and picks. The engine owns the deterministic editing work. Neither Claude nor the app
reimplements the other's job.

## Where things live

| Thing | Location |
|---|---|
| App support | `~/Library/Application Support/Clauto Editor/` |
| Engine checkout (pinned tag) | `.../engine/` with `.venv` inside |
| Logs | `.../logs/` (setup, per-project runs) |
| Projects | user-chosen, default `~/Movies/Clauto Editor/<Project>/` |
| Original footage | wherever the user keeps it; referenced, never moved |

### Project folder (the source of truth)

```
My Video/
  clauto-project.json     name, aspect, engine version, claude session id, created, schema version
  brief.md                what the user typed; the first message to Claude
  CLAUDE.md               generated: project rules + pointer to the engine docs (see below)
  paths.json              this project's footage/assets/build/cuts/script locations
  footage/                symlinks or copies, a-cam b-cam broll macro audio
  assets/                 music, cutouts, textures, graphics the user dropped
  script/                 script.md (annotated)
  notes/                  dropped text files and reference material
  cuts/                   outputs per version: v001/, v002/ ...  (fcpxml, captions, preview, PDFs)
  build/                  engine scratch output; safe to delete
  .clauto/                conversation log, run history, UI state
```

Rules: a person can understand it in Finder; copying the folder to another Mac plus its footage
reproduces the project; deleting `build/` and `.clauto/` loses nothing the user wrote.

## Driving Claude Code

Flags below were confirmed against `claude --help` (Claude Code 2.1.296). Event payload shapes are
**not** confirmed and must be checked with a real run in M2 before the parser is written.

| Need | Mechanism |
|---|---|
| Non-interactive turn | `claude -p "<message>"` run with the project folder as working directory |
| Streaming progress | `--output-format stream-json` (needs `--verbose` with `-p`; confirm), optionally `--include-partial-messages` |
| Continue the same conversation | `--session-id <uuid>` on the first turn, then `--resume <uuid>` |
| Let Claude see the engine and project | working directory = project; `--add-dir <engine>` |
| Limit what it may do | `--allowedTools` and `--permission-mode`; no interactive approvals exist in a GUI turn, so the allowlist must cover what the pipeline needs |
| Pass project rules | project `CLAUDE.md`, plus `--append-system-prompt` for per-run context |
| Sign-in state | `claude auth status`; sign in with `claude auth login` |

A turn is one process. The app never keeps a pty open. Cancel sends SIGINT then SIGTERM. Output is
parsed line by line, shown in the Ask Claude panel (assistant text, tool activity as short status
lines) and appended to `.clauto/conversation.jsonl`. Tool calls are shown as "Running transcribe...",
not as commands, with the real command in Details.

### Project CLAUDE.md

The app generates one per project so Claude starts oriented:

- Where the engine is, and "run the pipeline only with `./run` from the engine folder".
- The project folder layout above and which files the user owns (`brief.md`, `script/`, `notes/`).
- The non-negotiables from the engine `CLAUDE.md`, by reference to it, not copied, so they cannot
  drift.
- Behaviour contract for the app: reply in plain language; never ask the user to run a command;
  when something is missing say exactly which file to drop; escalate science to the user;
  write results to `cuts/vNNN/`.

### Iteration loop

1. User message arrives (or Run is pressed).
2. App snapshots the current `cuts/vNNN/` pointer and sends the turn.
3. Claude edits `brief.md`, `script/`, or the picks and calls the minimum stages needed
   (`--from N`), because the engine supports resuming.
4. App detects outputs, copies them to `cuts/v(N+1)/`, labels the version with the user's message.
5. Failure leaves the previous version current; nothing is overwritten.

## Pipeline progress

The engine prints stage banners today. M2 adds `--progress json` to `run_pipeline.py` so each stage
emits `{"stage":3,"state":"start|done|fail","detail":"..."}` lines. The app parses those; it does
not scrape human text. The build sheet (`build-sheet.md`) and read-back transcript are parsed from
their files.

## Engine changes this app needs

Small, additive, and covered by the engine's own tests. Each is a prerequisite for the milestone
named.

| Change | Why | Milestone |
|---|---|---|
| `CLAUTO_PATHS` env var: path to a `paths.json` that overrides the repo-root one | `paths.json` is per machine today; the app needs per project | M1 |
| Add `script` and `templates` keys to `paths.json` and `config.py` | `SCRIPT_DIR` is hard-wired to `ROOT/script` | M1 |
| `--progress json` on `run_pipeline.py` | Structured progress | M2 |
| Non-interactive `setup.py` (`--footage ... --assets ... --build ... --cuts ...`) | Setup without prompts | M1 |
| Machine-readable preflight (`--dry-run --json`) | Setup "Check" step and Needs-assets list | M1 |
| Versioned engine releases (git tags, `ENGINE_VERSION`) | Pinning and updates | M1 |
| Whisper model choice: a `CLAUTO_WHISPER_MODEL` env var (or `whisper_model` in `paths.json`) read by `stage1_transcribe`, replacing the hard-coded default | Setup model choice | M1 |
| Model prefetch command (`./run stage1_transcribe.py --download-model NAME`) | Download during setup, with progress | M1 |
| Style pack loading | Other looks | M6 |

## Installer details

- Every step is idempotent and reports `{state, detail}`; the UI is a pure function of that.
- Homebrew's installer is interactive (admin password, Command Line Tools). Run it in a
  small embedded terminal view or hand off to Terminal.app with a clear "Come back here when it
  finishes" screen. Do not fake or script the password prompt.
- Apple Silicon and Intel both: resolve `brew` at `/opt/homebrew/bin` then `/usr/local/bin`; do not
  rely on the user's shell `PATH`, because a GUI app does not inherit it. Build an explicit `PATH`
  for every child process.
- Python: use `python@3.11` from brew, not Apple's system Python. The venv is created with that
  interpreter by absolute path.
- Large downloads (PyTorch, Whisper model) show real progress bars (bytes), and can be resumed.
- Offline or failed downloads leave a half-installed state that the next run detects and repairs.

## Updates (Sparkle)

The app updates itself the way Straight Up Browser does (see that repo's `DEPLOYMENT.md`,
`scripts/release.sh` and `Browser-Info.plist`). Reuse the pattern; do not invent a second one.

| Piece | Clauto Editor |
|---|---|
| Framework | Sparkle 2.6 or later via Swift Package Manager (`https://github.com/sparkle-project/Sparkle`) |
| Updater | `SPUStandardUpdaterController` started at launch; a "Check for Updates..." menu item |
| Feed | `https://nathanfennel.com/downloads/clauto-editor-appcast.xml` (own filename; the downloads folder already holds other apps' feeds) |
| Download | `https://nathanfennel.com/downloads/Clauto-Editor.dmg`, notarized and stapled |
| Info.plist keys | `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks` = true, `SUAutomaticallyUpdate` = true (silent install, live after next relaunch) |
| Signing | Developer ID Application certificate; Sparkle EdDSA signature on every appcast entry; notarization with the `notary` keychain profile |
| Release script | `scripts/release.sh` modelled on the Browser's: clean tagged commit on `origin/main`, tests, archive, export, notarize, DMG, `generate_appcast`, validation, provenance file |

**Not sandboxed means simpler.** The Browser needs `SUEnableInstallerLauncherService` and a
`mach-lookup` entitlement exception because it is sandboxed. Clauto Editor is not, so omit both and
do not copy that entitlement block. Verify on a real update that the installer works without them.

**Signing key.** The EdDSA private key lives in this Mac's Keychain (service
`https://sparkle-project.org`, account `ed25519`); it must never change for an installed app. Two
options, decide before the first release:

- *Reuse the Browser's key* (the default `generate_appcast` picks up): one key to back up, and the
  Browser's `sparkle-bin` tools work as is. If it leaks, both apps are affected.
- *A separate key* (`generate_keys --account clauto-editor`, passed to the tools): isolates the
  apps, costs a second secret to back up.

Whichever is chosen, put the public half in `SUPublicEDKey` and write the choice into this doc.

**Hosting and the AWS migration.** The DMG and appcast are static files in the nathanfennel.com
repo (`public/downloads/`). That site is under the AWS migration policy: until the cutover, a
release deploy goes to both Vercel and AWS from the same commit, and after cutover to AWS only.
`release.sh` must not hard-code a host-specific step; the publish step is "commit the files to the
website repo and deploy it by that repo's verified command". Check the appcast URL from the live
domain after every publish, because skipping or botching it means installed copies never update.

**Engine updates are not app updates.** Sparkle replaces the `.app`. The engine checkout and venv
live in Application Support and are updated by the app from tagged releases, on user consent, never
mid-run. Each app version declares the engine versions it supports.

**Debug builds** must not check for updates (the Browser does the same with `startsUpdater`).

## Security and trust

- Not sandboxed, so the app can run any child process and read any path the user gives it. Treat
  every dropped file as untrusted data: never execute it, never interpolate its text into a shell
  command, and pass paths as arguments, not through `sh -c`.
- Dropped text is content for Claude, not instructions for the app. The project `CLAUDE.md` tells
  Claude that notes and scripts are material to work from; the allowlist limits damage if it
  disagrees.
- Claude's tool allowlist is scoped to the project folder and engine. No network tools beyond
  what the CLI itself needs.
- Secrets: the app stores none. Sign-in belongs to Claude Code's own keychain handling.
- Hardened runtime and Developer ID signing, then notarize. Sparkle ships signed; no
  `disable-library-validation` unless a measured need appears.
- Logs can contain file names and paths; "Collect diagnostics" shows what it includes before
  saving and uploads nothing.

## Swift conventions

- SwiftUI, Observation (`@Observable`) for state; Swift concurrency for processes
  (`Process` + `AsyncStream` of lines).
- The Xcode template's `Item` model and the placeholder `ContentView` are removed in M0.
- Child processes go through one `ProcessRunner` that sets the environment, captures output to the
  log, supports cancellation and returns a typed result. No `Process` use elsewhere.
- Tests: unit tests for classification, the stream parser, path and `PATH` building, project
  folder reading and writing; the installer is tested behind a protocol with a fake runner.
  UI tests cover the drop-to-classify flow.

## Failure modes to design for up front

| Situation | Behaviour |
|---|---|
| Claude rate limit mid-run | Pause, show reset time, resume the same session |
| Signed out during a run | Stop cleanly, show Sign in, resume |
| Footage drive unplugged | Missing-file chips on the Files tab; run refuses with the names |
| Disk nearly full | Warn before transcribe and render (ProRes alpha layers are large) |
| Engine update breaks a project | Projects record engine version; update never applies mid-run; old version restorable |
| User edits `brief.md` outside the app | App watches the file and marks the cut stale |

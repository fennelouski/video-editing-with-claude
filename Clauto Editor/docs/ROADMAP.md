# Roadmap

Ordered so each milestone is usable and testable on its own. "Done" is observable, not a feeling.

## M0: Clean slate

- Delete the template `Item` model and placeholder `ContentView`; set up the sidebar and empty
  states.
- Sandbox off (done), hardened runtime on, app icon placeholder, bundle id decision.
- `ProcessRunner` with environment building, cancellation, and tests.
- Add Sparkle (SPM, 2.6+), the updater controller (off in Debug), and the plist keys, so updates
  are in from the first signed build rather than bolted on at the end. Signing key is decided
  and generated (ARCHITECTURE.md, "Updates"); back it up.

**Done when:** the app launches to an empty project list and can run `ffmpeg -version` with a
correct explicit `PATH`, from a normal Finder launch (not Xcode).

## M1: Setup

- Engine changes: `CLAUTO_WHISPER_MODEL` and model prefetch, `CLAUTO_PATHS`, `script`/`templates` keys, non-interactive `setup.py`,
  `--dry-run --json`, engine version tags.
- `SetupService` for Homebrew, tools, Claude Code, sign-in, engine, venv, transcription model
  choice (measure the real download sizes), folders, final check.
- Setup window per UX.md section 1.

**Done when:** on a fresh macOS user account, a person with no Terminal use gets to a green final
check, and running Setup again changes nothing.

## M2: One turn with Claude

- `ClaudeSession`: spawn, stream, parse, cancel, resume. Capture real stream-json samples first and
  commit them as test fixtures.
- Project folder creation, generated project `CLAUDE.md`, Ask Claude panel (text only).
- Engine `--progress json`.

**Done when:** the user types a message in a project and sees Claude's reply and tool activity
stream live, and a second message continues the same conversation after an app restart.

## M3: Brief and files

- Brief form writing `brief.md`; Files tab with drag and drop, classification, referencing vs
  copying; text and `.docx` drops; "What is this?" resolution.
- Script drop and drafted-script approval flow.

**Done when:** dropping a mixed bag (video, WAV, JPEG, `.md`, `.docx`) lands each file in the right
place, shown correctly in Files, with nothing moved or altered at its original location.

## M4: First cut

- `PipelineRunner` with stage progress, Needs-assets checklist with drop-to-satisfy, Needs-your-answer
  cards, resumable runs.
- Result view: preview, cut points with reasons, read-back transcript, Open in Final Cut.

**Done when:** raw footage plus a brief becomes a rough-cut FCPXML that opens in Final Cut, with
every stop (missing asset, escalation) resolved from the UI.

## M5: Iteration and versions

- Version store and compare/restore/branch; targeted re-runs (`--from N`); suggestion chips;
  stale-cut detection; notifications when a background run finishes; rate-limit pause and resume.

**Done when:** five consecutive change requests produce five labelled versions, any of which can be
restored, and none overwrote another.

## M6: Beyond one person's look

- Engine style packs (palette, fonts, textures, rules) selected per project.
- Neutral bundled starter pack so a second user is not blocked on custom scans.
- Engine update button with pinned releases.

**Done when:** a second user with their own materials produces a cut in a different look without
editing engine code.

## M7: Ship

- `scripts/release.sh` adapted from Straight Up Browser: notarized DMG, signed appcast at
  `nathanfennel.com/downloads/clauto-editor-appcast.xml`, validation, provenance. Publish through
  the website repo's current deploy policy.
- Verify an end-to-end update: install build N, publish N+1, confirm it self-updates.
- Crash and log collection (local only), first-run onboarding polish, accessibility pass.

**Done when:** a notarized DMG installs on a clean Mac without Gatekeeper warnings, passes the
M1 to M5 acceptance flows, and a published newer build installs itself on the older one.

## Risks

| Risk | Mitigation |
|---|---|
| Install size and time (PyTorch, Whisper) | Early measurement in M1, model-size choice, resumable downloads |
| Claude Code CLI output format changes | Fixtures plus a version check; pin a tested range and warn outside it |
| Headless Claude cannot ask for permission | Tight allowlist designed in M2; fail with a clear "needs permission" message, not a hang |
| Sparkle key lost or swapped | Back up the Keychain item; never change the key after release |
| One look only | Said plainly in the UI; M6 is the real fix |
| Engine assumptions of two terminal users | Each engine change in ARCHITECTURE.md is small, tested and additive |

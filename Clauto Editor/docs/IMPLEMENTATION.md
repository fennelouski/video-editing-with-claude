# Implementation checklist

Baseline: upstream `556b0ae` (13 October 2026). Work lives on local branch
`codex/clauto-native-foundation` in a separate clone. Nothing is pushed.

## Scope and document reconciliation

Read the product, architecture, UX and roadmap documents, engine CLAUDE.md, README,
SETUP, taste principles, correction log, handoff, historical implementation prompts,
font and molecular-kit specifications. No repository AGENTS.md or .agents/skills
directory exists at this upstream revision or in the import checkout. Applicable
macOS build/run, SwiftUI and Swift concurrency skills guide implementation.

The native app drives the deterministic engine; it is not a timeline editor.
House style, 24000/1001 timing, breath floor, native captions, human science review,
missing-asset gates and editable Final Cut handoff remain engine responsibilities.
The older handoff's “no web UI” statement is consistent with the native app.
Historical “no test suite” statements predate the committed suite and are not a
reason to discard existing tests.

Nathan's current authorization takes precedence over future product flows:
no Claude turns, private footage/transcript uploads, paid services, new credentials,
App Store upload or publication. Conversation and Run controls explain their pending
milestones. Debug Sparkle checks are disabled. Final Cut is not launched.

Real projects default to `/Volumes/Videos/Food Videos/Katie YouTube/Projects/Clauto Editor`.
Media references and project build/cuts stay there. Synthetic tests use disposable
temporary directories; Xcode build artifacts stay in this source checkout.
Drive validation refuses missing volume mounts before creating folders.

## Existing import work

After coordinating with the import owner, copied the reviewed external-path fixes,
source-name collision detection, storage guard, Canon ingestion utility and their
tests into this clone. No private paths.json/storage.json, LaunchAgent, import receipts,
footage or model caches were copied. The ONE R transfer belongs to another task and
was neither restarted nor duplicated. Existing engine dependency packages are read
by a local development venv overlay; the owner's checkout/venv is not modified.

## Requirements

| Milestone / requirement | Status | Evidence or remaining work |
|---|---|---|
| M0 remove template Item/SwiftData UI | Implemented | Native sidebar, empty state, Brief/Files/Cut views |
| M0 explicit PATH, argument-safe process runner | Implemented | Real tool/literal-argument/both-pipe tests |
| M0 bounded output, line streaming, timeout/cancel | Implemented for direct child | Process tests; process-tree cancellation must precede pipeline supervision |
| M0 sandbox off, hardened runtime, bundle ID | Implemented | Xcode settings; macOS minimum corrected from 26.5 to 26.0 |
| M0 Sparkle + menu + public key/feed | Implemented | Sparkle 2.10.0 resolved; Debug updater off; signed release/update untested |
| M0 Finder launch + ffmpeg acceptance | Partial acceptance | Normal app bundle launch/window verified; same runner passes real ffmpeg test; interactive setup check remains blocked |
| M1 project paths, script/templates, model selection | Implemented | CLAUTO_PATHS / CLAUTO_WHISPER_MODEL and subprocess tests |
| M1 noninteractive folder setup | Implemented | Repeated setup with spaces in paths; missing drive refused |
| M1 machine-readable preflight | Implemented | --dry-run --json emits readiness/problems without stages or writes |
| M1 model prefetch command | Implemented, not executed | Speech + alignment loading hook; real download sizes/resume/cache verification pending |
| M1 automated installer/sign-in/clean-user account | Pending | Read-only setup checklist and folder chooser implemented; no installer claimed |
| M1 tagged engine releases | Pending | ENGINE_VERSION is explicitly 0.1.0-dev; no stable release tag claimed |
| M2 project folder/CLAUDE.md | Implemented | Schema-checked JSON, brief.md, paths.json, visible folders |
| M2 engine JSON progress | Implemented | Asset-gate/stream-channel tests |
| M2 ClaudeSession and verified stream fixtures | Blocked by current session scope | Capture real CLI events only during separately authorized external-AI test |
| M3 brief autosave and project reopen | Implemented | Form persists brief.md; actor reload avoids stale manifest overwrite |
| M3 type classification/reference/copy/remove | Implemented | Mixed intake, source preservation, rollback and containment tests; edited copied scripts retained in visible removed-files/ |
| M3 audio/music ambiguity | Implemented | What-is-this menu relocates project reference, never original |
| M3 folder intake and explicit group drop | Implemented | References supported files individually; no linked-directory discovery assumption |
| M3 aspect/model project preferences | Implemented | Manifest + paths.json persist settings |
| M3 docx reading/summary, replace, script approval | Pending | DOCX intake is preserved/copied; no parser or fabricated summary |
| Projects duplicate/archive/thumbnails | Pending | Create, list, open and recent-project restore implemented |
| M4 pipeline runs/assets/science/result review | Pending | Honest read-only project check; no generated cut claimed |
| M5 versions/compare/restore/branch/stale-cut/watch/rate-limit | Pending | No cut version is fabricated |
| M6 style packs/neutral assets/engine update | Pending | One house style stated in UI |
| M7 notarized DMG/appcast/live update/diagnostics | Pending | Local Debug app only, no publication or signing credentials |
| Independent second reviewer | Pending | Separate local review pass and automated evidence complete; no second-reviewer result claimed |
| Accessibility | Partial | Native controls, labels, keyboard choose equivalents; full VoiceOver/drop UI pass pending |

## Verification record

Verified locally on macOS 26.6.2 with Xcode 27.0:

- Full engine suite: **551 passed**. After final manifest validation/model-prefetch
  additions, the relevant CLI/config/project contract tests were re-run: **122 passed**.
- Swift core: **14 tests passed**, including complete concurrency diagnostics, real
  ffmpeg, timeout/cancel, literal arguments, large stdout/stderr, mixed intake,
  rollback, containment, preference persistence, folder drops and edited-script preservation.
- Native app Debug build and all Xcode test targets compile successfully.
- `script/build_and_run.sh --build-only` stages `dist/Clauto Editor.app` and verifies
  its signature. The built plist contains the specified bundle ID, 26.0 minimum,
  Sparkle feed and dedicated public key. This is a local ad-hoc Debug build; Xcode
  disables hardened runtime for ad-hoc signing. Release signing/notarization remain untested.
- The normal bundle launch produced the real native empty-project window. Its
  sidebar, New/Open Project controls and Setup button were inspected through
  accessibility and screenshot. No Final Cut launch or private-media access occurred.
- Read-only NAS metadata confirms the app's mount comparison accepts the actual
  `/Volumes/Videos` mount; missing-drive refusal passes a separate test.

The graphical Xcode test host stalled in dyld before app code ran, with both
unsigned and ad-hoc test builds. Core tests use the exact same source files through
the root SwiftPM verification package and pass. Normal app launch works.
Interactive computer-use verification then failed with “native pipe closed before
response”; it was not retried blindly. Full create/brief/drop UI acceptance and
VoiceOver checks remain **unverified**. A meaningful create-and-autosave UI test is
written and compiled, but is not represented as passing.

A separate review pass fixed stale manifest overwrites, retained edited copied
scripts on removal, repaired omitted Sparkle plist keys, and rejected partial
project manifests instead of silently falling back into the engine repo. No
separate human/agent reviewer result is claimed; an independent second reviewer
should inspect the local commits before merging into the import owner's checkout.

The entire product is not complete when these foundation checks pass.

## Local build and evidence

Run the app with `./script/build_and_run.sh`; build without UI with `--build-only`.
The Debug runner provides this checkout as the engine and uses the NAS project default.
Use `swift test --scratch-path .artifacts/SwiftPM -Xswiftc -strict-concurrency=complete`
for core verification. Xcode remains the app build; the package is only a test harness.

Local logs: `.artifacts/build.log`, `test-build.log`, `core-tests.log`,
`engine-tests.log`, `engine-contract-final.log`. These are gitignored, as are the
app bundle, venv and build scratch. The development venv's `.pth` overlay depends
on the import task's already-installed dependency packages; it is not a portable
clean-machine install and must be replaced by the M1 installer.

## Next usable increments

Finish clean-machine setup/model measurement and process-tree cancellation first.
Then capture an authorized real Claude CLI stream fixture and implement one resumable
turn, followed by the asset/science gates and synthetic first-cut acceptance.
Keep engine version pinning explicit and never bypass the read-back or asset gates.

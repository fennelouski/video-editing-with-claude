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
App Store upload or publication. Change requests persist locally; the UI does not
pretend Claude answered or applied them. Run drives the local engine with explicit
plan approval. Debug Sparkle checks are disabled. Final Cut is not launched during
development/testing.

Real projects default to `/Volumes/Videos/Food Videos/Katie YouTube/Projects/Clauto Editor`.
Media references and project build/cuts stay there. Routine synthetic tests use disposable
temporary directories; full cached-model acceptance uses an explicitly marked synthetic
NAS project. Xcode build artifacts stay in this source checkout.
Drive validation refuses missing volume mounts before creating folders.
Execution revalidates each run's writable paths and pinned engine; asset-library
intake creates project-owned references. Hugging Face offline flags, local-only speech
model loading, and the Python socket guard stop implicit model downloads in GUI runs.
This is not an operating-system network sandbox. The engine runs local file inputs.

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
| M0 bounded output, line streaming, timeout/cancel | Implemented | Separate POSIX process groups; INT→TERM→KILL; redirected descendants and caller cancellation after parent exit covered |
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
| M3 script approval and explicit selection | Implemented | Brief text becomes project-owned script.md; a run pins its snapshot instead of selecting an older alphabetical draft |
| M3 docx reading/summary and Replace | Pending | DOCX intake and engine comments parsing are preserved; GUI preview/summary/replace are absent |
| Projects duplicate/archive/thumbnails | Pending | Create, list, open and recent-project restore implemented |
| M4 local first-cut orchestration | Implemented, synthetic acceptance passed | Actual cached large-v3 transcription/read-back, stages 1–3 pause, explicit plan approval, strict asset gate, alpha rendering, captions and saved version tested on NAS |
| M4 missing pieces and asset quality | Implemented | Choose/drop and strict engine recheck; missing files, alpha, size and variant warnings stop before render; no green tick merely for a drop |
| M4 scientific fact/number approval | Partial | Entire saved plan requires human approval; individual Confirm/Edit/Cut escalation cards remain pending |
| M4 result review | Implemented, partial acceptance | Synthetic GUI preview reaches 00:08 without a crash; tab return resets to paused; read-back and reasons retained; actual Final Cut import remains unverified |
| M4 script/shot-list PDF | Implemented | Native CoreText exporter; exact approved MD/TXT, read-back, frame-snapped shot list, removed spans and asset checklist; Word attachment notice; unique exports, containment and multipage/Unicode checks; GUI export visually verified |
| M5 versions/compare/restore | Implemented | Numbered/labeled immutable folders, comparison player, current-version pointer; five-version preservation test |
| M5 version provenance | Implemented | Approved-plan hash, exact approved script, snapshotted brief/plan/read-back; generated media copied permanently; distinct source/saved hashes and schema flags; installed DTD validates saved bytes before updating current |
| M5 stale brief | Implemented | Brief changes show a warning without modifying prior cut; broader file/watch invalidation remains pending |
| M5 local conversation queue | Implemented | User requests persist in notes/conversation.json across reopen; no assistant response or rerun is fabricated |
| M5 Claude changes/branch/watch/rate-limit/notifications | Pending/blocked | Live Claude requires separately authorized fixture capture; branch, export watch, rate-limit retry and completion notifications are absent |
| M6 style packs/neutral assets/engine update | Pending | One house style stated in UI |
| M7 notarized DMG/appcast/live update/diagnostics | Pending | Local Debug app only, no publication or signing credentials |
| Independent second reviewer | Complete for this increment | Separate read-only review of workflow, PDF/provenance, saved serialization and native player lifecycle; 35 routine core tests passed, 2 opt-ins skipped; GUI and cached-model acceptance run by main agent |
| Accessibility | Partial | Native controls, labels, keyboard choose equivalents; full VoiceOver/drop UI pass pending |

## Verification record

Verified locally on macOS 26.6.2 with Xcode 27.0:

- Full engine suite at the preceding milestone: **559 passed**. The focused app contracts also
  passed: **13 tests**, including explicit approved-script dispatch.
- Swift core: **35 routine tests passed; 2 opt-in tests skipped**, including complete concurrency diagnostics, real
  ffmpeg, timeout/cancel, literal arguments, large stdout/stderr, mixed intake,
  rollback, containment, preference persistence, folder drops and edited-script preservation.
  Workflow coverage includes approval invalidation, strict real engine asset gating,
  malformed progress/settings, reopened runs, five versions, permanent media references,
  stale brief, edited timeline receipts and two descendant-cancellation cases. New checks
  cover PDF pagination/Unicode, approved-script provenance, actual shot timings, export
  containment, uppercase scripts and saved-schema failure rollback.
- The opt-in full cached-model synthetic acceptance separately passed in **62.047 seconds**.
  A developer-written narration, local system speech and synthetic grey clip/placeholder
  assets exercised actual stages 1–5 with large-v3 and the cached alignment model, all
  network guards enabled. Both saved final and rough-cut FCPXML pass the engine's semantic
  checks and installed Final Cut DTD; captions and read-back exist; the source SHA is unchanged.
- Native app Debug build and all Xcode test targets compile successfully.
- `script/build_and_run.sh --build-only` stages `dist/Clauto Editor.app` and verifies
  its signature. The built plist contains the specified bundle ID, 26.0 minimum,
  Sparkle feed and dedicated public key. This is a local ad-hoc Debug build; Xcode
  disables hardened runtime for ad-hoc signing. Release signing/notarization remain untested.
- Normal bundle launch produced the native empty-project window. Isolated QA bundles with
  separate identifiers/preferences then verified creation, brief autosave, script approval,
  queued requests and project opening. The chooser now starts at the configured NAS root.
  Cut preview played the synthetic 8-second clip to completion; returning after a tab switch
  yields a paused player at zero. GUI PDF export succeeded and both rendered pages were
  visually inspected. No Final Cut launch or private-media access occurred in app acceptance.
- Read-only NAS metadata confirms the app's mount comparison accepts the actual
  `/Volumes/Videos` mount; missing-drive refusal passes a separate test.

The graphical Xcode test host stalled in dyld before app code ran, with both
unsigned and ad-hoc test builds. Core tests use the exact same source files through
the root SwiftPM verification package and pass. Normal app launch works.
Computer-use connectivity was intermittent and later recovered. Native UI actions above
were verified through accessibility and screenshots; automated Xcode UI tests are compiled,
not represented as passing. GUI drop/plan approval and full VoiceOver checks remain unverified.
Cut initially aborted inside the system _AVKit_SwiftUI bridge. A small @MainActor
NSViewRepresentable now owns AVPlayerView, replaces its player only on URL change, and
pauses/releases it during dismantling. Actual synthetic GUI playback verifies the fix.

An independent second agent reviewed the workflow and reproduced failures with
synthetic inputs. Fixed findings include process-tree/caller cancellation, stale
reference removal, script-header round trips, escaping writable paths, malformed
plans/settings, asset-format mismatches and hidden quality warnings, nonblocking
timeline validation, URL aliases/trailing slashes, wrong script selection, and
source-versus-saved timeline validation provenance. The later review covered exact script
provenance, Word-note separation, shot-list timing and the native player lifecycle. It passed
35 routine core tests and found no remaining blocker in the reviewed source. It did not use
GUI, private media or Claude. See [REVIEW.md](REVIEW.md) for scope and acceptance limits.

The entire product is not complete when these foundation checks pass.

## Local build and evidence

Run the app with `./script/build_and_run.sh`; build without UI with `--build-only`.
The Debug runner provides this checkout as the engine and uses the NAS project default.
Use `swift test --scratch-path .artifacts/SwiftPM -Xswiftc -strict-concurrency=complete`
for core verification. Xcode remains the app build; the package is only a test harness.

Local logs: `.artifacts/build.log`, `test-build.log`, `core-tests.log`,
`engine-tests.log`, `engine-contract-final.log`, `synthetic-acceptance-final.log`,
`build-playback-fix.log`, `test-build-playback-final.log`. These are gitignored, as are the
app bundle, venv and build scratch. The development venv's `.pth` overlay depends
on the import task's already-installed dependency packages; it is not a portable
clean-machine install and must be replaced by the M1 installer.

## Current workflow and limits

Add original media, choose the asset library and already-installed model cache, and
approve an annotated script. Run Current Inputs produces a separate run snapshot.
The engine currently finishes one narration source per invocation: select it
explicitly when several clips exist. The app preserves other footage but does not
claim multicamera/multi-source assembly. It pauses after planning; approve the saved
plan's facts, numbers and timing, then resolve any missing or unsuitable pieces.
Rendering never receives --no-verify, --allow-missing or --skip-preflight.

A completed cut becomes current only when stage completion, unchanged plan approval,
timeline hash-bound source validation, present local media and read-back are confirmed.
Versions preserve generated layers; originals remain referenced in place. The source
validation receipt is named *.source-validation.json. URI rewrites have a separate
*.snapshot.json recording source/saved hashes and the installed schema result. Foundation's
inferred standalone declaration and preserved DOCTYPE state caused a saved-cut failure;
serialization now rebuilds the named DOCTYPE, reparses the emitted bytes and applies the
installed DTD before changing current. The UI uses the saved-schema flag and marks legacy
versions as unverified. Actual Final Cut import remains unverified.

The full synthetic acceptance project is beneath
`Synthetic Acceptance 2026-10-13-1646/projects/Synthetic acceptance only-EBD0976F`
under the NAS Clauto Editor project root. Its `acceptance-result.json` at the fixture root
records saved-schema validation and source preservation. The earlier 6DF32081 test project's
pre-fix version is retained as failed serialization evidence, not presented as an accepted cut.
All placeholder artwork is marked synthetic and is unsuitable as production house assets.
The helper `scripts/tools/synthetic_acceptance.py` refuses existing destination folders and
prepares local speech/media without external AI or downloads. The opt-in test is enabled by
`CLAUTO_SYNTHETIC_ACCEPTANCE_ROOT`; routine tests skip it deliberately.

GUI drop/plan approval, full VoiceOver, and automated graphical test-host execution remain
unverified. Disk-full/NAS-disconnect during
a long render, closing-window/quit supervision, completion notifications, richer
missing-file replacement and concurrent app instances still need acceptance work.
Live requests stay queued until a separately authorized real Claude session exists.

## Next usable increments

Finish clean-machine setup/model measurement and wider GUI/accessibility acceptance.
When external-AI testing is separately authorized, capture a real Claude CLI stream
fixture and implement one resumable turn. Complete scientific escalation cards,
multisource assembly, notifications and branch/watch.
Keep engine version pinning explicit and never bypass the read-back or asset gates.

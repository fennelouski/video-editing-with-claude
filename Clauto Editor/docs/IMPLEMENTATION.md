# Implementation checklist

Baseline: upstream `556b0ae` (13 October 2026), reconfirmed against public main
before the later local increment was saved. Work lives on local branch
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

Nathan's current authorization takes precedence over future product flows.
GUI acceptance uses synthetic media and local engine execution; no live Claude
transport, paid fallback, new credentials, App Store upload or publication is enabled.
A separately authorized private pizza-planning CLI turn is outside GUI acceptance
and does not complete M2. Change requests persist locally; the UI does not
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
| M2 ClaudeSession and verified stream fixtures | Partial, synthetic only | Typed provisional adapter persists each line, resumes identity, rejects unbound/malformed/denied results, recovers interrupted turns and cancels; no live app transport, and compatibility with separately captured real CLI events remains unverified |
| M3 brief autosave and project reopen | Implemented | Form persists brief.md; actor reload avoids stale manifest overwrite |
| M3 type classification/reference/copy/remove | Implemented | Mixed intake, source preservation, rollback and containment tests; edited copied scripts retained in visible removed-files/ |
| M3 audio/music ambiguity | Implemented | What-is-this menu relocates project reference, never original |
| M3 folder intake and explicit group drop | Implemented | References supported files individually; no linked-directory discovery assumption |
| M3 aspect/model project preferences | Implemented | Manifest + paths.json persist settings |
| M3 script input and explicit selection | Implemented, synthetic acceptance | Brief text or an explicitly chosen MD/TXT/DOCX becomes an immutable project input. New runs pin that copy and its receipt; earlier run inputs stay unchanged. Input selection grants no editorial/factual/production approval. |
| M3 project creative references | Implemented, bounded local acceptance | Exact-byte style/taste documents retain role, SHA and Library provenance; native intake, immutable version copies, legacy sidecar recovery and frozen run snapshots tested. Reference documents do not enter narration discovery. |
| Script-first independent review and stage ordering | Engine/CLI implemented; native draft review implemented, paired approval pending | Native Transcript tab adds exact-catalog-bound stable rows, keep/exclude, order, comments, separate graphic fields, immutable checkpoints/undo and review-only export. Paired ledger approval and applying source spans remain pending. Source-index/script-SHA ledger, human-evidence gate and ten actual round limit stay separate. See SCRIPT_FIRST_WORKFLOW.md and TRANSCRIPT_REVIEW.md. |
| M3 docx reading/summary and Replace | Partial | Explicit replacement, including changes at the same original path, preserves earlier project copies, Word bytes/comments and prepared runs. Bounded engine XML/comment parsing is tested. GUI content preview/summary and full OOXML validation remain. |
| Projects duplicate/archive/thumbnails | Pending | Create, list, open and recent-project restore implemented |
| M4 local first-cut orchestration | Implemented, synthetic acceptance passed | Actual cached large-v3 transcription/read-back, stages 1–3 pause, explicit plan approval, strict asset gate, alpha rendering, captions and saved version tested on NAS |
| M4 ordered narration from several clips | Implemented, synthetic acceptance passed | Explicit GUI order, frozen schema-2 source/key manifest, real assembled read-back, original source/time provenance, aggregate evidence required before saving; two-source cached-model acceptance passed |
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
| Independent second reviewer | Complete for this increment | Read-only workflow, PDF/provenance, saved serialization, native player, multisource, selected-camera import/proof and synthetic conversation reviews; 45 routine core tests passed independently, two opt-ins skipped; acceptance limits recorded in REVIEW.md |
| Accessibility | Partial | Authored controls retain semantic labels and keyboard choose equivalents; full VoiceOver/drop UI pass pending |

## Verification record

Native transcript review increment (14 October, overnight work): the final full
core suite passed **77 routine tests**, with five opt-ins skipped (82 registered
cases). Eighteen new routine transcript tests cover source/copy identity, global
row order, explicit exclusion, separate annotation fields, immutable checkpoints,
undo, stale writers, escaped duplicate keys, containment, backwards timing,
oversized-write refusal, edits arriving during actual repository I/O, and
pending saves/Undo during exit. The source-only independent reviewer reproduced
three defects during development; all have fixes and regressions. Native quit
dialog interaction is still unverified.

The actual saved yeast catalog passed local NAS acceptance through the same native
repository: **27 sources, 914 rows, 11,900 words**, unchanged input catalog hash,
saved/reopened row order and annotations, and a unique review-only selection export.
Only a new labelled QA project was written; the live Sheet, source media, v7 and
expansion proposal remained untouched. Source media were not read or re-hashed in
this acceptance. The final Debug app build and strict signature check passed
without launching the app. Four new synthetic offscreen transcript captures
passed independent static craft/layout review. Interactive typing, pointer,
keyboard traversal, VoiceOver, source playback and actual quit interaction remain
pending. Applying source-span selections and paired-review approval are separate
unfinished integration. See [TRANSCRIPT_REVIEW.md](TRANSCRIPT_REVIEW.md).

The later local FCPXML handoff repair uses one shared integer-frame ownership
rule for connections, chapter markers and stage-5 TODO markers. This prevents
duplicate connections at float-adjacent boundaries and preserves cues on clips
that serialize to a one-frame minimum. The current focused FCPXML/stage-5 suite
passes **61 tests** (49.48 seconds), including regressions from real boundary
values and synthetic metadata fixtures. No native Final Cut import was attempted;
the active import and existing checkout remain undisturbed. This engine repair
does not complete native UI or full-motion editorial acceptance.

Latest bounded increment (14 October): source-bound duration projection and the
CLI review adapter pass **142 synthetic tests** in the latest focused run. The
adapter scope repair passed95 independently reviewed cases; the projection module
passed77 focused cases after replay protection. Planning time counts overlapping
capped word intervals once across all reused selections of the same physical
source and credits no unverified gaps or joins. This is a lower estimate, not an
eight-minute articulation prerequisite: a protected duration-evidence issue lets
source-valid drafts reach real review while keeping production blocked. Saved
revision briefs survive resume; an older approval cannot
inherit new constraints. Completed pairs are reconciled from original terminal,
prompt and script evidence before more calls. A provider revision with an empty
or mismatched string hash can count only as an explicitly input-bound refusal, carrying a
protected critical identity issue; its original critique cannot close issues or
approve. An unbound agreement is rejected. Missing verdict receipts and unknown
receipt metadata stop before further provider calls. Larger prior source-valid
drafts may supply unapproved revision material, never approval or extra rounds. The current
private edit still needs actual editorial agreement, human facts and delivered
runtime checks. No video approval follows from these tests.

The custom app workspace passed an isolated Debug Xcode build and strict bundle
signature verification. Fourteen synthetic UI captures passed bounded independent
design review after repairs; physical pointer/drop/keyboard, VoiceOver and valid
live playback acceptance remain pending. The running app and Final Cut were not
replaced or launched during this increment. The preceding full-engine checkpoint
passed **787 tests**; native core passed **59 routine tests**, with four opt-ins
skipped. These earlier broader checks precede the latest142-test CLI increment.

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

### Later local increment

- Ordered multisource narration passed the full engine suite at its checkpoint:
  **568 tests**. The later focused multisource and selected-camera import/proof suite
  passed **47 tests**. This is not a claim that the full suite was repeated after every
  tool addition.
- Actual two-source cached-model acceptance passed in **66.527 seconds**. Both saved
  final and rough-cut FCPXML pass engine checks and the installed DTD. The saved final
  timeline references both originals, the handoff shot list names the second source,
  the assembled read-back is required, and both original hashes remain unchanged.
  Evidence: `acceptance-result.json` under the NAS project root's
  `Synthetic Multisource Acceptance 2026-10-13-b94e073a` folder. An earlier failed
  two-source fixture is preserved as failed evidence.
- Multisource frame/source mapping, copied intake keys, approval manifest hash,
  aggregate output selection and failure rollback have regression coverage. This
  implements ordered narration assembly; multicamera selection/synchronization is
  still separate work. The new GUI ordering controls have not received interactive
  acceptance.
- The build runner no longer terminates all existing app instances. `--build-only`
  builds/stages/verifies the bundle without launching or interrupting a user session.
- The provisional Claude adapter has only an injected synthetic transport. Its
  default transport is disabled, non-fixture transports are refused, and no app
  preference can enable a network turn. Fixture tests are explicitly synthetic;
  current CLI payload compatibility still requires separately authorized capture.
  The final core run passed **45 routine tests**, with **2 opt-in tests skipped**;
  all eight synthetic conversation tests passed. Complete concurrency diagnostics
  and the native Debug bundle build/signature verification passed.
- Selected ONE R import and A/B proof tools were added for local correction work.
  Import opens card ancestors and source files with no-follow descriptors, pins
  known sizes/identity, verifies NAS read-back hashes, and creates a fresh local
  receipt. It cannot write evidence to the card. The proof tool checks source and
  output ranges, preserves primary-camera audio, and enforces the configured crop
  ceiling. Synthetic tests cover symlink swaps, changed files, descriptor cleanup,
  receipt containment and short secondary-camera rejection. No missing original
  has been imported merely because these tests passed.

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
Later increment logs are `multisource-full-engine-tests.log`,
`multisource-acceptance.log`, `engine-increment-final.log`, `core-tests-current.log`,
`claude-fixture-tests.log` and `app-increment-final.log`.

## Current workflow and limits

Add original media, choose the asset library and already-installed model cache, and
approve an annotated script. Run Current Inputs produces a separate run snapshot.
Select and order narration clips explicitly. Each run freezes that order and its
original source keys; the assembled read-back and source time map accompany the
saved cut. The app preserves other footage. Automatic multicamera selection and
synchronization remain pending. It pauses after planning; approve the saved
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
multicamera selection/synchronization, notifications and branch/watch.
Keep engine version pinning explicit and never bypass the read-back or asset gates.


## Expanded local workflows (14 October)

See `EXPANDED_FEATURES.md` for all eight requested features and remaining acceptance.
Timed feedback binds project/version/timeline/range identity. Optional duration
limits are persisted and frozen, checked against the frame-aligned retained EDL
and actual emitted/saved FCPXML, and preserve the previous current cut on failure.
Duration failures retain their editorial review message instead of entering the
missing-assets flow.

Global new-project export defaults and project overrides support 720p/1080p/2160p.
Runs freeze resolution, aspect and model, reject missing/changed metadata, and
verify actual sequence dimensions before saving. Raster spacing, motion, shadows,
captions and safe areas scale together. FCPXML resources retain source dimensions
and rates separately from the chosen sequence format.

Saved cuts can produce immutable local derivatives in `build/derivatives/<UUID>/`:
selected ranges, portrait/landscape output, fit/fill framing and position, captions,
graphical layers and local audio effects. Gain, filters, compression and echo
create separate PCM dialogue; an optional project sound is placed at sample-aligned
time. Full decode, hashes and true peak are checked before completion. The native
service validates the parent, chosen range/framing/effects and output receipt,
retains the original engine contract and records only completed derivatives.
Unsupported animated transforms/volume, nested/transition effects or missing
source spans fail with a review message. GUI acceptance and support for additional
timeline effects remain pending. The app does not open Final Cut during export.


## Native source-span review checkpoint (15 October)

`TRANSCRIPT_REVIEW.md` records the integrated requirements and remaining gates.
The native source map now preserves arbitrary passage order using original clip
coordinates and exact saved revision/catalog hashes. Local source verification
checks complete media and declared original-transcript bytes, actual audio-segment
coverage and file drift. Bounded original-passage previews use separate transport
identity for each revision/span, completed exact seeks and forward-only controls.
Playback is verified at check time; it does not consume immutable frozen bytes.

An explicit local source-review acknowledgment is separate from authenticated
human fact review, paired editorial approval, graphic approval and rendering.
A durable project association blocks legacy whole-clip prepare/resume/snapshot
paths after transcript review intake, including damaged-pointer recovery cases.
No new cut is started. Fourteen synthetic source-map regressions plus the existing
core cases pass; 91 routine cases pass with five opt-ins skipped. Actual saved
catalog mapping passed separately in a new NAS QA project without media reads,
Sheet access or rendering. Native playback/seek/drift-pause and broader graphical
accessibility acceptance remain pending.


## Synthetic native source-span rendering (15 October)

The native renderer now integrates a separate deterministic engine worker for
factory-issued synthetic QA projects. It freezes stable-ID source spans and exact
review acknowledgment bytes, verifies originals, renders fixed-grid ProRes/PCM,
validates actual decoded counts/timing/FCPXML and publishes only a synthetic review
pointer under the review lock. Destination descriptors, exclusive files, a
no-replace bundle rename and final directory/hash checks protect failure cases.
Production gates and existing cuts remain untouched. Exact supported behavior,
synthetic decoded-output tests, storage-failure simulations and the check-time
identity limitation are in `SOURCE_SPAN_RENDERING.md`. Native GUI production
application and actual editorial/fact approval remain pending.


## Asynchronous voice-review increment (15 October)

[VOICE_REVIEW.md](VOICE_REVIEW.md) records the requirements, reused VoiceKit source,
implementation and limits. Explicit player/device selection and microphone controls,
speech-onset timing, seeks/pauses/version changes, stable notes/transcript history,
durable editing drafts, failure recovery and serialized local candidate preparation
are implemented. Distinct immutable instruction artifacts protect the reviewed cut.
Actual candidate timeline editing and rendered movie delivery remain unfinished;
NAS/source and all editorial/production approval gates are unchanged.

Final native validation reports 137 registered cases (131 passed, six opt-ins skipped),
including 29 mocked voice-review cases. Debug builds without launch. Debug and Release
microphone entitlements and signatures are checked separately in the handoff. Actual
microphone capture, permission prompts, model downloads, interactive VoiceOver,
private footage processing and new cut generation were not performed. Independent
review details and precise final evidence are in the task-local handoff rather than
implied by earlier milestone acceptance counts above.

## Explicit review-candidate integration (15 October)

[VOICE_CANDIDATE_EDITS.md](VOICE_CANDIDATE_EDITS.md) records the next tested
increment. Explicit Remove/Protect actions and reviewed frame ranges now compile
into a separate approved plan. A bounded renderer uses exact unlinked read-only
local APFS snapshots and persistent NAS output, checks decoded frames/audio,
preserves watched-version pointers and parent XML, and exposes verified in-app
candidate playback. A separate new review project imports the latest completed
Pizza Yeast v7 with its exact original technical receipt and input bytes.

| Requirement | Current result | Remaining boundary |
|---|---|---|
| Apply finalized feedback to actual edits | Implemented for explicit review-movie frame removals/protection | No semantic free-text edit guessing or camera-layer application |
| Preserve parent/source mapping | Implemented and checked | Mapping is watched-master frames; original native XML is reference lineage |
| Render and verify candidates | Implemented for supported SDR/grid/audio inputs | Not production or new editorial/fact approval |
| Actual Videos NAS publication | Generated-media acceptance passed | Old source renderer SMB zero-link gate remains intact |
| Latest Pizza test workflow | Verified v7 review import and canonical launcher | See actual app launch receipt; no v8 assumed |
| Capture/accessibility acceptance | Mock and semantic coverage remains | Real microphone and interactive VoiceOver pending |

Final exact test/build/review counts and source revision are in the local status
receipt and handoff. This increment does not complete every documented app feature.

## Playback commands and paused-frame comments (15 October)

[PLAYBACK_AND_FRAME_COMMENTS.md](PLAYBACK_AND_FRAME_COMMENTS.md) is the user guide
and supported-input contract. Native Playback menu commands route to a selected
saved-version player in the key window, with a configurable skip interval and
text/modal/seek guards. A paused-frame comment freezes the rational clock and full
saved-version identity before asynchronous extraction. Raw PNG evidence and
normalized circle/ellipse vectors persist separately, with explicit Save/Cancel,
mark undo/removal, original-frame revision history, source checks and idempotent
save recovery. The existing Remove/Protect candidate workflow remains separate.

This is another bounded, tested increment. It does not claim all product documents
are implemented, production camera-layer editing is available, or real microphone
and interactive VoiceOver acceptance has completed. Final source/test/build and
independent-review receipts are task-local, alongside earlier milestone evidence.

## Guided voice setup and app-first priority (15 October)

Nathan requested completing Clauto's app workflows before further Pizza editing.
The voice setup increment includes the recognition engine and an explicit guided
Get started flow inside Clauto: native consent, input discovery, on-device asset
preparation, progress, cancellation and retry. It replaces the external Dictate
installation instruction. This changes the product's former no-install policy:
an explicit setup action may prepare Apple's local assets; opening a project or
ordinary capture cannot. Development has used synthetic providers without actual
permission requests, model downloads or app launch.

Continuous steering with approximately 120 seconds of feedback inactivity before
packet preparation is the next requirement. Microphone off remains a privacy
control; it must not be required to begin processing feedback. Broader original
product requirements above and native accessibility acceptance remain tracked,
and no publication or live external conversation service is implied.

## Continuous steering (15 October)

The next increment removes microphone shutdown as a prerequisite for feedback
processing. Cards save continuously; 120 seconds without meaningful feedback seals
an immutable numbered packet and starts local proposal preparation. New feedback
continues while work runs and supersedes stale proposals. Unsubmitted drafts are
retained as context and never become instructions. Idle scheduling is durable,
transactional, idempotent, and independent of playback-clock or meter activity.
Paused-frame comments can coexist with capture; explicit timing boundaries remain.

Exact cut-plan compilation is automatic for supported, resolved packets. Rendering
still uses the previously implemented explicit exact-plan approval. Full automatic
candidate rendering/version selection and recognition while watching a candidate
need further work; existing provenance boundaries are retained. No live external
conversation or semantic editor is enabled by this increment.

App-first completion remains the priority. The remaining original-product work
includes script/source-span apply and DOCX replacement flows, scientific escalation
cards, project duplicate/archive/thumbnails, broader watch/invalidation and style
packs, clean-user setup, and native interaction/accessibility acceptance. Live
Claude transport, signed public distribution and update delivery also need their
appropriate runtime/environment checks; no external private context or publication
is authorized by the local development work. The requirements table above records
individual implementation and acceptance limits rather than claiming completion.

## One-action candidate preview (15 October)

After continuous steering has prepared a resolved concrete edit plan, Approve and
create preview saves its exact approval and immediately starts the verified local
renderer. The former second Render action is no longer needed. Duplicate clicks
join one task and durable same-plan approvals are idempotent. Quit joins approval
writes and prevents a render starting after exit has begun. Rendering remains
separate from applying/publishing a production edit, with the existing source,
frame/audio and storage checks; private-media runtime acceptance is deferred.

## Candidate playback feedback (15 October, M10)

- [x] Give each verified rendered preview a separate durable review identity and
  candidate-local clock, preserving the original comment/onset and parent lineage.
- [x] Permit ongoing capture through source/candidate transitions with explicit
  version boundaries, no nested candidate ownership, and safe return to the paused
  source. Unavailable/boundary-spanning speech needs clarification.
- [x] Reuse the continuous feedback panel and typed drafts during candidate playback.
  Further exact plans still need the existing approval before rendering; they
  never apply themselves to a production cut or overwrite a source version.
- [x] Verify root inputs and each candidate's completion, plan, approval, proof,
  movie/timeline identity and bounded lineage before attaching feedback.
- [ ] Native candidate-player/microphone timing and VoiceOver acceptance, held
  during foreground work. Broader semantic editing and original product gaps remain.

Earlier milestones' candidate-capture restriction describes their historical scope;
this increment replaces it. Background synthetic checks do not imply native UI
acceptance, private-project rendering, publication, or full app completion.

M10 inherited-protection correction: earlier protected original frames project
through each candidate's verified retained fragments as separate constraints.
Original note text, onset, target and revision are untouched. A child removal
cannot overlap these constraints; revise the source protection and create a new
source candidate to change it. Native provenance recomputes the projection, and
the renderer separately checks inherited constraints against parent lineage.
Each opening is cancellation/generation owned, so navigation during verification
cannot seize a feedback clock after its surface has closed.

M10 history ownership correction: the controller retains each opening/playing
candidate's history row by its own presentation token, alongside the newest eight
entries. New feedback packets cannot evict the row that owns a candidate sheet or
retarget its clock. Failure, navigation or closing releases only that opening's
retention. Pure rolling-history regression supplements the source lifecycle review.

M10 test scheduling correction: historical full runs exposed timing assumptions
under concurrent native builds and synthetic renders. Transcript checkpoint tests
now hold an injected default-no-op async gate after capturing the submitted draft;
frame capture tests await the actual preparation state, and real synthetic render
tests allow a bounded 90-second completion window. Existing write/revision/output
assertions remain. Historical failures remain in their original logs; only final
frozen-source results support acceptance. Production autosave remains 250ms.

## Local spoken range proposals (15 October, M11)

- [x] Interpret complete English timed commands locally: remove/cut/delete or
  keep/protect/preserve, absolute clocks/seconds/minutes, next/previous seconds,
  and from here for a stated duration. Common number words and decimal seconds
  are supported. Relative ranges use original onset, never ASR completion time.
- [x] Keep original transcript, onset, target, revision and saved directives intact.
  Separate plan proposals explain their source and proposed times; frame rounding,
  inherited protections, source checks and existing approval remain mandatory.
- [x] Refuse negated, conditional, compound, unsupported or out-of-movie commands
  rather than guessing/clamping. Explicitly selected action plus complete range
  remains authoritative; mismatched partial selections ask for clarification.
- [x] Offer Use times from comment for typed feedback. This deliberate action
  fills visible range/action controls at the selected player's current clock; the
  original typed comment stays unchanged, and Save/plan approval remain separate.
- [x] Global capture status identifies the actual candidate, with Mic Off labeled
  as a privacy control. No stop/finalize prerequisite was added.
- [ ] Broader semantic editing of arbitrary language, source sentences, camera or
  graphics layers and script application remain. This bounded local interpreter
  is not a live external conversation provider or unrestricted AI editor.

Synthetic acceptance exercises raw final speech -> exact proposed range -> existing
approval -> verified local movie, preserving original feedback and source identity.
Native recognition/player/VoiceOver acceptance remains held with the foreground.

M11 review correction: number words accept a hyphen only for an exact recognized
tens-plus-unit compound such as twenty-one. Leading, trailing, repeated, spaced
or negative-word hyphens are refused; they cannot silently become positive edits.
Independent rejected v1 parser evidence and its earlier build remain preserved.

## Saved script inputs and explicit replacement (15 October, M12)

- [x] Choose the exact Markdown, UTF-8 text or Word document in Files, or save
  text from Brief. A checksummed immutable selection publishes through the project
  manifest last. Brief selection never overwrites a user's existing script.md.
- [x] Replace a script explicitly, including an updated Word document saved at
  the same source path. Keep its logical file ID, original bytes, previous project
  copy, selection receipt and all prepared run inputs. Stale file rows refuse a
  later replacement rather than silently selecting different content.
- [x] New runs copy only the selected script and its receipt, pin both hashes,
  and check the input on resume and before cut publication. Existing production,
  transcript and plan approval gates remain. Selecting a script is input choice,
  not approval of its claims or permission to render a production cut.
- [x] A removed, missing or changed selection requires choosing a script again;
  it cannot revive an old alphabetical/legacy draft. Legacy projects with no saved
  selection history keep their previous discovery behavior, with new runs hashed.
- [x] Conventional Word document/comment XML is read without rewriting the ZIP.
  Duplicate entries, oversized/encrypted parts, declarations and unsupported roots
  are refused. Swift selection bounds the source to 16 MiB and checks the ZIP
  signature; complete content validation occurs in the engine, not in the picker.
- [ ] Native picker/layout/VoiceOver acceptance is held with the foreground.
  Word preview/summary, broader Office format support, paired source-span approval
  and applying reviewed source spans remain separate unfinished work.

Synthetic coverage includes same-path Word edits with changed comments, prior-run
preservation, stale rows, interrupted/invalid selections, copied-source edits,
symlink refusal, missing/tampered receipts, manifest pointer loss, rehashed run
settings, concurrent Brief autosave, uppercase legacy input, and existing saved
cut provenance. No private media, recognition assets or native UI were exercised.

M12 v2 review corrections: Word XML uses encoding-aware Expat declaration handlers
before ElementTree parsing. UTF-8 and UTF-16 LE/BE document/comment fixtures,
with/without BOM, reject DTD/entity declarations and preserve ordinary Unicode.
All ProjectRepository manifest writers now hold a shared per-project advisory
lock from the fresh manifest read through atomic publication. Separate actors
cannot silently overwrite a successful script choice with a stale Brief manifest.
Contention waits up to two seconds, with cancellation; a longer conflict reports
that the change was not saved. The rejected v1 and its evidence remain unchanged.

M12 v3 closes SS-03: Brief drafts have local ownership tokens, independent of
script-save responses. Every manifest mutation increments an optional persisted
revision under the shared lock; the store ignores an older acknowledged project
and overlays its still-owned Brief draft. An old save cannot clear a newer draft.
Quit flushing retries retained Brief drafts and waits for acknowledgements; active
project updates or failed saves keep the unsaved-work decision explicit. Pure
state regressions and the independent no-window controller probe cover ordering;
the native quit dialog and picker remain unobserved during the foreground hold.

M12 v4 closes SS-04: draft ownership and revision comparisons include the canonical
project folder, not only its UUID. Opening/restoring a second different folder
with an already-listed project UUID explicitly refuses the copy before selecting
or updating it. No edit is silently redirected to the original folder. Filesystem
aliases of the same canonical folder remain usable. Opening same-ID backup copies
alongside the original remains unsupported until a deliberate project duplication
workflow assigns distinct identities and review histories.

M12 v5 closes SS-05/06: an open Project captures its physical directory device/
inode in ephemeral state. This identity never enters its portable manifest.
Replacing a folder at the same pathname cannot borrow the old folder's draft,
hide the restored selection behind an old revision, or accept a stale project
mutation/new-run/resume request. Presentation comparisons use normalized canonical
path strings plus physical identity, so a genuine symlink alias with a different
URL directory hint remains the same project. Same-ID copies or replaced roots
already listed in the current session are explicitly refused before selection;
fresh session restoration captures the intended current folder. Native behavior
after an actual NAS reconnect remains unobserved during the foreground hold.

M12 v6 closes SS-07: create/open return canonical pinned-root handles. Writers
reload manifest and Brief through the directory descriptor already held by their
lease, then verify the fresh project ID and physical identity against that lease.
Remaining intake destinations use its canonical root. Retargeting an input alias
while a write waits cannot mix another project's metadata into the locked folder.
Manifest publication also verifies the supplied root scope. Brief reads are
bounded to 64 MiB; malformed/non-UTF-8 or replaced input is refused. Synthetic
contention coverage asserts both project identities and the other manifest bytes.

M12 v7 closes SS-08: Start Cut checks the originally chosen project against the
reopened physical root after awaiting Brief autosave, before preparing any run.
A same-path replacement or changed project ID is refused. A retained unsaved Brief
also blocks preparation, so a failed autosave cannot silently feed older words
into the cut. Synthetic root-replacement and draft-acknowledgement checks cover
the policy; native Start Cut interaction remains held.

## Newly requested review tools (15 October)

| Requirement | Current state | Next acceptance |
|---|---|---|
| Circle/ellipse on an exact paused saved frame | Implemented in earlier frame-comment milestone | Latest native inline/popout/fullscreen and accessibility pass held |
| Highlight/freehand, selectable regions, typed/dictated tagged notes | M13 adds highlights/freehand, selectable editable regions and typed labels/notes; direct region dictation remains pending | Extend normalized geometry, retain raw dictation/version/frame provenance, test edit/undo/reopen and accessible coordinate alternatives |
| Project-local people with user-assigned names and @mentions | Requested; not implemented | Anonymous on-device detection, stable local IDs, explicit name/uncertain-match confirmation, typed/spoken disambiguation, correction/unassign and export control |

Spatial annotations are frame-bound unless a separately verified tracking record
exists. People processing must not infer real identities or use external face or
identity services. Full tracking, merge/split and cross-frame continuity are not
claimed by the existing frame-comment implementation. These additions must not
delay delivery of already reviewed Pizza playback/feedback features.

## M13: drawing and typed region notes

Saved-frame comments now support highlight rectangles, bounded freehand strokes
and click-to-pin circular details alongside earlier circles/ellipses. Regions
have stable IDs, individual labels/typed notes, selection, coordinate resize,
delete and undo/redo. Delayed field callbacks retain their original region ID
and cannot retarget a newly selected or deleted mark. Earlier records omit the
new optional fields and retain their encoded bytes.

The stored request preserves exact saved-version movie/timeline/input provenance,
rational playback clock, decoded frame time, PNG hash and normalized geometry
inside the video, excluding letterbox bars. This is the saved edit's frame; an
original-camera time mapping is not implied. Revised comments retain the earlier
record and frozen image. No video is modified or production approval inferred.

Source-level controls include a mark list, bounds fields and an explicit point
list as keyboard alternatives to dragging. Synthetic tests cover geometry, old
record compatibility, region text preservation, delayed callbacks, resize/undo
and saved revision provenance. Native gestures, layout, inline/popout/fullscreen
focus and VoiceOver remain unobserved during the foreground hold. Direct region
dictation with retained raw ASR, candidate-frame notes, project-local person IDs,
name disambiguation, anonymous detection and tracking remain pending. See
`SPATIAL_FRAME_NOTES.md` for bounds and the acceptance scope.

M13 v2 corrections: preserve closed freehand loops, pin frame-comment I/O to the
original physical project root, and retain immutable save attempts across failure.
Late region edits cannot reuse a committed record ID; retries preserve the earlier
revision and then save newer words. Native interaction acceptance remains held.

## Concurrent first project saves

A synthetic negative control on unchanged M13 reproduced a first-use race:
concurrent Brief and script writes can fail to open their not-yet-created shared
lock. Existing local draft ownership preserves the words, but the operation
requires retry. The correction opens an existing lock or creates it exclusively,
then retries only bounded creation/interruption conflicts while checking the
pinned root. The same two-second budget covers creation and lock contention;
symlinks, wrong file types, cancellation and replaced roots still refuse. A
regression starts both first writes on eight fresh projects and verifies the
latest Brief, exact selected script and manifest revision. The independent people
prototype is excluded from this correction. Native first-use interaction remains
unobserved during the foreground hold.


## Background frame-grid validation

The common frame verifier moves synchronous sample scanning off Swift's shared cooperative workers onto a bounded owned serial queue. Cancellation promptly releases the awaiting task, refuses late publication and retains physical capacity until the underlying operation ends. All existing timestamp/decoder/provenance checks remain. A synchronous OS/NAS read is not forcibly interruptible; there is no hard I/O deadline. See [FRAME_CAPTURE_BACKGROUND_IO.md](FRAME_CAPTURE_BACKGROUND_IO.md). People/Vision implementation is excluded from this correction, and native/NAS/full-product acceptance remains held.

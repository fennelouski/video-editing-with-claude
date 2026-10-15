# Approved design refresh — implementation checklist

Nathan approved building the ten-part design on 2026-10-15. This checklist
tracks local incremental work after `ea7ff6e`; it is not full acceptance,
release authorization, or permission to publish the public repository.
The implementation owner remains the sole source writer. Preserve the active
import checkout, native-tools WIP, NAS project media, and prior audit receipts.

| Requirement | Current increment | Remaining acceptance / implementation |
| --- | --- | --- |
| Eleven semantic themes, Homey default | Stable IDs, persisted choice, original palettes/material treatments, native Standard colors/buttons/fonts, native text-area color refresh, contrast tests, offscreen renders of all eleven themes at two sizes and Standard light/dark | Render every interaction state; increased contrast, text scaling, selection/focus/disabled pairs; refine authored material references |
| One command architecture | Shared typed registry, native menu/palette, navigation, configured skips, J/K/L, rational frame steps/non-drop timecode, versions/pane commands | Active-window/IME/physical keyboard acceptance; contextual availability and palette restoration matrix |
| Selectable app text | Root text selection, native text areas, copyable timecodes/errors and single tooltip text | Audit all app-owned labels and controls; preserve honest native menu/button exceptions; physical selection precedence |
| Bare-video play/pause | Mouse-up action with movement threshold, focused Space/JKL/frame keys, explicit-control command guards | Physical click, drag, controls and annotation exclusion checks |
| Native macOS PiP | Public AVPlayerView controls, retained delegate, start/fail/stop/restore lifecycle and external ownership | Actual native PiP acceptance. Public SDK has no programmatic start operation; start uses the visible AVKit control |
| Custom detached video | Store/window-scoped stable session and one reparented AVPlayerView, close-to-dock, threshold drag, video-window fullscreen/Escape, display recovery and idle controls | Offscreen same-player/item/paused-clock detach/dock passed; actual video pixels, transition failures, focused controls, screen unplug and physical window tests remain |
| Compact copy / one tooltip | New compact review workspace and microphone controls; global delayed/Option tooltip with selectable text | Measured before/after copy comparison, full-app removal pass, rapid hover/focus/Option acceptance |
| Original icon | Existing original editable geometry and complete macOS asset catalog retained | Recheck small-size readability against new default; no other platform app target exists |
| Explicit local voice and feedback cards | Existing on-device provider, explicit target/mic controls/meter, provisional/final notes, original onset/history/reanchor/candidate isolation; measured signed rate and rate-change epochs; spoken-order cards; explicit merge/split, retained parent/anchor lineage, stale/candidate invalidation and late-ASR protection; ambiguous-reference flags; final idea groups from reported audio runs, captured silence, explicit topic cues and inter-run transport boundaries; restart-durable raw typed drafts, compare-and-swap conflict protection and idempotent explicit Save | Real permitted microphone and native desktop acceptance |
| Adaptive three panes | Versions/assets left, stable video/timeline center, independent feedback scroll right; pane toggles/focus and compact project rail; detached placeholder; synthetic compact/large renders with long feedback preserve video geometry | Large-text renders, repeated focus, persistence across themes and navigation |

## Validation boundaries

- Actual private Pizza Yeast v7 passed the prerequisite seek/pause/exact-frame,
  circle add/undo/redo/remove and five-second skip probe. Source/current pointer
  were unchanged; private PNGs stayed in memory; no Sheet write. Receipt:
  `.artifacts/pizza-v7-frame-controls-validation.json` (ignored/local only).
- Core tests use synthetic media/clocks. Native structure tests construct
  offscreen views/windows and synthetic media; they do not establish foreground,
  physical interaction, native PiP, VoiceOver or external-display acceptance.
- Existing running review bundle is not overwritten. New builds use isolated
  `.artifacts/DesignRefreshBuild`; no independent phone or Final Cut operations.
- Frame comments remain bound to their synchronously frozen version/frame.
  Voice target selection remains explicit. ASR completion time never substitutes
  for speech onset. No new permission, model download or external audio service.
- The versioned app design principles copies distributed by another task are
  preserved separately from this feature payload until their owner reconciles them.
- Main-sync owner reviews exact immutable payload/build receipts before testable
  handoff. No push, merge, deployment or upload has been performed here.

## Milestone 2 — manual feedback cards

- Merge adjacent finalized cards from the same saved version, or split after an
  exact opening phrase at a Unicode-safe word/punctuation boundary. Original
  cards, ASR history, onset anchors and revisions remain in the ledger.
- New cards require a newly confirmed range and Protect/Remove action. The app
  does not infer split word timestamps or expand the original protection range.
- Card order follows captured audio/session order, including older ledgers and
  nested splits. Delayed ASR cannot resurrect a retired parent. Stale operations,
  unsaved drafts and changed revisions refuse atomically; retried operation IDs
  cannot duplicate children. Old candidates are invalidated.
- A delayed draft on a retired card remains visible as selectable read-only text
  until discarded. Card transactions join the tracked save queue synchronously;
  quit waits for them before reporting a successful flush.
- Synthetic regression tests cover these invariants and the exact checksum of a
  ledger generated by the committed pre-M2 encoder. GUI/physical acceptance is
  still pending. Natural speech segmentation and restart-durable new typed
  composers are separate increments, not claimed here.

## Milestone 3 — reported speech timing and conservative idea groups

- VoiceKit retains the public SpeechAnalyzer attributed text/audio ranges.
  Partial recognition stays one provisional card. Final speech can divide at
  real run boundaries after a continuously captured pause of at least 1.2 seconds,
  an explicit sentence/topic cue, or a seek/pause/version/rate boundary between
  runs. A multiword run is never divided using invented word times.
- This is a local deterministic grouping rule, not semantic AI topic detection.
  The entire original utterance and reported timing runs are retained; each card
  uses its reported speech onset. Shifted first-word timing, incomplete/overlapping
  coverage, Unicode-invalid ranges or a boundary inside a run need manual timing
  resolution. Missing microphone packets are not classified as silence.
- Final ASR waits for late captured-clock packets before grouping. A manual edit,
  cancellation, merge/split, stopped session or wrong capture attempt cannot be
  replaced by late automatic groups. Original candidate and watched-version
  isolation continue to apply. No microphone, permission request, model download,
  external speech service or private footage is used by these synthetic checks.

## Player identity and rate guard correction

- Player creation pins the movie's path and fast file signature before creating
  its decoder. The asynchronously prepared full target must match that opening
  snapshot and a fresh signature check before an endpoint can publish.
- Explicit voice selection uses the immutable target held by the watched player;
  it does not recompute a new disk identity for an already-open decoder. Changed
  saved media refuses binding and leaves the microphone off.
- Rates outside the supported signed −4…4 ledger range, including nonfinite
  values, record an unavailable interval with no target. Original feedback stays
  durable and unresolved, and returning to a supported clock creates a boundary.
  Such a rate cannot poison the durable save queue or supply a guessed anchor.

## Milestone 5 — appearance and observed player availability

- Custom themes synchronize SwiftUI and native hosting-window appearance. Standard
  inherits the application's effective appearance, observes system-color changes,
  and resolves semantic native title colors again when those change. Sheet roots
  without authored window controls also receive the selected native appearance.
  Detached video keeps its independent dark controls. No production code changes
  the application's or system's appearance.
- The compact Projects menu uses a visible folder glyph and rail-text tint, rather
  than an inherited accent that disappeared on two dark sidebar colors. Native
  close/minimize/zoom buttons remain visible in Standard.
- Explicit watched-player selection and derived playback availability invalidate
  their controls immediately. Ordinary clock ticks do not rebuild the mic control.
  Starting capture samples readiness, finite time and supported rate again before
  saving a session or opening the microphone. Invalid clocks immediately break
  continuity without fabricating timestamps; the first valid recovery boundary
  survives ordinary timestamp backpressure. Speech crossing that gap remains
  durable and needs manual timing resolution.
- A protected modified-entry component harness renders all eleven themes at
  900×640 and 1440×900 using synthetic media/text only. Standard light/dark checks
  compare application, hosting-window and view appearance plus actual pixels.
  A separate root without window controls checks native sheet appearance. Long
  feedback preserves video geometry; offscreen detach/dock retains one AVPlayer,
  its item and paused clock. Test windows refuse ordering and activation is
  prohibited; the existing private review process remains alive.
- These are component-source checks, not acceptance of the exact Release app's
  startup, decoded video pixels, physical keyboard/selection, PiP/fullscreen,
  external displays, accessibility or VoiceOver. Foreground native acceptance
  remains pending. Live speech is blocked by the existing missing speech grant
  and local model; no permission or model download was requested.
- At M5, new typed composers survived pane/view replacement in memory; restart-
  durable new typed drafts and idempotent Save remained for M6 below. The
  approximate 90% explanatory-copy reduction has not been measured or accepted.

## Milestone 6 — durable new typed feedback

- New typed drafts retain exact text, unfinished range strings, action and the
  original explicitly selected version target in the existing project ledger.
  Typing before a player is selected stores an unbound draft; it never selects a
  player or starts capture. View replacement and restart recover the same draft.
- Autosave waits 250 milliseconds after typing stops. Dirty drafts and their
  writes participate in quit flushing. A failed or conflicting save retains the
  local text, reports failure and prevents a false successful flush. Another
  controller's saved draft cannot be overwritten without a matching saved base;
  reloading that draft requires an explicit product confirmation after copying.
- Explicit Save freezes the fields while its tracked transaction runs. A stable
  per-content-revision submission ID atomically creates one note and receipt and
  removes the draft. Retrying that exact submission returns the same note, even
  after an uncertain response; an old delayed autosave cannot resurrect it.
  Further edits use a new submission ID. Changed movie files or invalid ranges
  refuse finalization while retaining the stored raw draft.
- Optional ledger fields preserve checksums from the pre-draft encoder. Draft and
  receipt counts, text sizes, revisions and selected-target identities are bounded.
  Synthetic tests cover restart, immediate Save/quit, retry/stale writes, two
  controllers, invalid data, changed movies and explicit version binding.
- This increment is developed and tested in the background. App launch and
  interactive acceptance remain deferred while Nathan uses the foreground for
  taxes. The prior M5 synthetic component renders are retained only for that pin;
  they do not establish runtime acceptance of these new typed controls.

## Milestone 7 — guided voice setup

- The in-app Get started action requests native consent, finds an available input,
  prepares Apple's on-device speech assets with progress and cancellation, then
  starts review for the originally selected verified movie. The VoiceKit engine
  is already included in Clauto. Another dictation app is no longer a prerequisite.
- Retry preserves granted consent and a valid explicit input; otherwise setup
  chooses the system default input. An unavailable input is explained in place.
  Native macOS privacy denial exposes the relevant system privacy control, since
  applications cannot grant themselves access after a user denies consent.
- Opening a project never starts setup. Ordinary capture cannot request access,
  install assets or silently fall back to a different microphone. Setup completion
  after navigation cannot start the replacement player's microphone. Quit joins
  cancellation and late progress cannot revive a cancelled setup.
- Source and synthetic-provider tests run in the background. No model installation,
  native consent request, live capture, app launch or foreground interaction was
  performed during development. Those runtime checks remain pending.
- Nathan's continuous steering requirement supersedes the earlier stop/finalize
  workflow: live feedback should continue while roughly two minutes of inactivity
  forms a packet for longer work. That next increment remains pending here.

## Milestone 8 — continuous steering and idle packets

- Live partial/final cards keep saving while capture remains on. Meaningful speech
  revisions, manual note changes, merge/split operations and draft edits restart a
  120-second feedback deadline. Playback clocks, microphone levels, identical ASR
  repeats and save acknowledgements do not. Microphone off is a privacy control;
  it is not required to begin packet/proposal preparation.
- A project transaction seals one immutable numbered packet containing the exact
  visible notes, revisions, original words, final/unfinished status, anchors and
  issues. Unsubmitted typed/transcript drafts remain visibly non-instructional
  context. Duplicate transactions across repositories return the same packet.
  Later packets retain earlier protections alongside new feedback.
- Candidate claims bind the packet and exact saved movie/note revisions, with one
  existing processing lease. Fresh feedback remains live while a job runs; stale
  output is retained as superseded history and the next quiet packet can proceed.
  Paused-frame comments no longer require microphone shutdown; their transport
  pause still creates the existing explicit timing boundary.
- Pending autosaves prevent an old timer or intervening clock write from sealing
  pre-keystroke feedback. Quit cancels the idle timer and saves drafts without
  waiting two minutes. Reopen resumes the saved deadline without starting capture.
- After a resolved packet, deterministic local proposal preparation starts
  automatically. Exact edit-plan compilation follows automatically for supported
  movies. Unfinished/ambiguous timing, draft context and conflicting instructions
  require clarification. No synthetic ASR finalization or free-text semantic edit
  guessing occurs. Existing explicit exact-plan approval and rendering gates stay
  intact; automatic rendering/version promotion and feedback while watching a
  rendered candidate remain subsequent work. Candidate playback currently requires
  capture to be off to protect its distinct timing/provenance.
- Core tests use synthetic providers and injected short delays; deterministic
  repository tests verify the full 120-second boundary, concurrent packet/claim
  behavior, immutable protection context, drafts, active capture, supersession and
  quit/restart. No native app, speech API, foreground or private-media operation
  was performed. Native UX and the full ten-part design remain unaccepted.

M8 independent-review corrections: packet-bound input and completion require the
entire current packet, including its activity revision, provisional speech and
draft context. The first local draft keystroke cancels owned preparation and queues
invalidation before its delayed autosave. A generation-owned half-second lease
watch resumes a ready packet after another repository releases its worker, without
resetting the idle date or stopping foreign work. Quit cancels/joins this watcher;
Keep Editing explicitly resumes durable packet scheduling without restarting capture.
These cases have independent regression tests and supersede the first M8 freeze.

Typed drafts now have an explicit Discard confirmation. Discard compares the exact
persisted base, freezes and tracks its transaction through quit, and records a
bounded tombstone so delayed autosaves or stale submissions cannot revive that
draft ID. Exact retries return the same discard; conflicts retain both local and
saved text. Truly empty typed context no longer blocks a proposal. Superseding a
prepared packet returns unowned unchanged notes to ready, allowing a replacement
after temporary draft context is cleared. The busy-lease watcher retries temporary
read failures at its bounded interval and clears its matching generation on exit.

## Milestone 9 — one approval creates the preview

- Reviewing the concrete frame plan now offers Approve and create preview. That
  single explicit action persists the exact plan approval and starts the existing
  verified local renderer automatically. It no longer requires a separate Render
  click. Voice feedback and new packet capture can continue during rendering.
- Duplicate approval clicks join one owned task. Identical durable approvals are
  idempotent across repositories, preserving one receipt. Failed/changed approvals
  cannot start rendering. Existing local snapshot, source/provenance, frame/audio,
  storage, and unchanged watched-version gates remain in force.
- Approval tasks participate in quit flushing. If quitting begins while approval
  waits for storage, it can finish saving without launching a late render. An
  interrupted preview has an explicit retry control; active rendering shows its
  progress/cancel controls instead. Cancellation is handled without a failure banner.
- Synthetic integration verifies one action produces one complete 24-frame movie,
  one approval/preview bundle, exact decoded output and unchanged watched-version
  pointer; concurrent approval and quit/storage waiting have dedicated coverage.
  No private footage, NAS, app launch, native speech or foreground test was used.
- This is explicit review-plan approval, not automatic interpretation of arbitrary
  speech, production fact approval, automatic version promotion, or recognition
  while watching a candidate. Those broader workflows and native acceptance remain.

M9 verification correction: draft-autosave waiting is injectable for deterministic
concurrency tests; production still waits 250ms. The pending-draft regression now
holds/releases a synthetic gate rather than assuming a wall-clock sleep is shorter
than autosave during parallel renders. A delayed same-plan approval replay after
completion reuses the existing preview; explicitly Create another preview remains
a separate user action. The initial full-suite timing failure is retained locally.

M9 approval owns the project slot through the synchronous handoff to rendering.
Manual Retry/Create controls are disabled and their controller entry is guarded
while approval is pending; a two-version storage-lock regression verifies another
already-approved candidate cannot take that slot. Quit and delayed-replay checks
remain in place. Earlier frozen M9 builds are superseded by this corrected pin.

An active renderer may report cancellation as a cancelled process result wrapped
in a workflow error. The controller also checks its task cancellation state in the
general catch, preventing a failure banner for an ordinary Cancel. A synthetic
runner test waits for actual render progress before cancelling and verifies cleanup.

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

M10 review correction: every sheet opening has a fresh immutable identity, and
controller attachment checks a separate binding generation after registration
waits. A delayed earlier registration cannot publish a previous decoder's clock
even if a caller accidentally reuses a token. A held-storage regression exercises
this race. Closing a candidate cannot end a later opening with a different token.

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

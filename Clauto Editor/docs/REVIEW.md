# Independent local workflow review

## Native transcript review — 14 October 2026

A separate read-only reviewer inspected the exact final transcript models,
repository/controller, native tab/inspector, captured-project integration and
termination hook. It independently passed 18 routine synthetic tests, skipped
the real-catalog opt-in, and ran additional actual-I/O probes. No remaining
reproduced blocker was found after these fixes:

- Cap encoded checkpoint/export/draft bytes before publication, so a large comment
  cannot advance the current pointer to a file that exceeds the read limit.
- Reject descending word starts and backwards row intervals; preserve raw terminal
  alignment overrun as a review flag rather than deleting it. Selected bounds
  inspect all words, not just the row's last endpoint.
- Wait for in-flight Undo and other review operations during normal Quit, as well
  as autosave. MainActor continuations settle the operation without a tight loop.

The independent I/O probe and routine regression confirm that comments, Keep and
graphic requests arriving during a write persist in a later checkpoint. The
review also checked exact catalog/hash pinning, full stable-row coverage, escaped
duplicate keys, immutable revisions/undo, stale-writer refusal, filtered reorder,
project-captured callbacks and exports that never assert approval or apply a cut.

A separate design reviewer accepted four synthetic offscreen transcript captures
and the source layout: readable type and intact controls, coherent existing craft
direction, and a compact Back-to-passages path. It performed no live UI actions.

These reviews did not run private NAS acceptance or inspect real media. The owner
separately verified the saved 27-source, 914-row catalog locally. Native pointer,
keyboard traversal, VoiceOver, playback and termination/dialog interaction remain
unverified. Paired-ledger approval and applying source spans remain unfinished.

## Earlier foundation review

Reviewed 13 October 2026 by a separate read-only agent. It used disposable synthetic
inputs and tests, and did not edit files, use GUI/private media, or invoke Claude.

Scope: ProcessRunner, ProjectRepository, WorkflowRepository, PipelineService,
EditorStore, ProjectView and their engine contracts. This review covers the local
workflow increment; it is not a claim that the entire product is complete.

## Findings fixed

- Cancellation originally stopped escalation after the parent exited. POSIX group
  supervision now retains the group leader until INT→TERM→KILL finishes. Calling-task
  cancellation also covers draining pipes after the parent has exited.
- Removing a stale file record could leave a moved music reference. Operations now
  reload the canonical manifest record. Brief field headings also round-trip safely.
- Writable settings could redirect asset drops/output into shared folders. Project
  containment is enforced at preparation, each phase, drops and snapshot creation.
- Malformed plan/settings could pass approval or leave a stuck running record.
  Required arrays/paths are validated before recording a running phase.
- Wrong asset extension support and hidden quality warnings undermined the gate.
  AIFF/JPEG handling is consistent; GUI runs require strict alpha/size/variant checks.
- Timeline validation errors were printed while stage 5 returned success. They now
  fail the stage. A source timeline must match its hash-bound validation receipt.
- macOS directory aliases and trailing slashes hid reopened runs. Identity checks
  compare resolved paths. Explicit approved-script selection defeats filename-order
  selection of old drafts.
- Saved timeline URI rewrites changed its bytes. Versions retain source validation
  separately and record both source/saved hashes; schema availability is visible.
- Request persistence could clear a newer draft. The UI clears only submitted text.
- PDF reports could select an older alphabetical script or substitute Word notes. Versions
  now pin the approved script; legacy plans resolve that exact name; DOCX remains an
  attached original with an explicit notice. Shot timings are checked against the saved
  XML and use frame-snapped timeline/source values. Uppercase scripts survive snapshots.
- Final acceptance caught Foundation's inferred standalone declaration conflicting with
  the external DTD. Serialization now rebuilds a named DOCTYPE, reparses the saved bytes,
  and validates against the installed Final Cut DTD before updating current. A forged
  source receipt cannot bypass saved-schema validation; failed snapshots leave no partial
  version and keep the previous cut current. Source/saved schema flags stay distinct.
- Main-agent GUI testing found a runtime abort in the system SwiftUI AVKit bridge. A
  narrow @MainActor AVPlayerView representable owns the player, guards URL replacement,
  and pauses/releases it during dismantling. The reviewer checked source/SDK lifecycle;
  the main agent subsequently verified synthetic playback to completion and tab return.

## Final independent result

35 routine Swift core tests passed; 2 explicit opt-ins skipped in the independent run.
These include the actual engine strict asset-gate process, reopen, approval, cancellation,
version, saved-schema rollback and PDF/provenance regressions. 12/12 engine contracts passed
in the independent run; the main final contract run includes one additional explicit
script-dispatch test. Whitespace checks and native build succeeded. No remaining
blocking finding was found in the reviewed increment.

## Remaining acceptance limits

Main-agent actual-model synthetic transcription-to-cut acceptance passes, including both
saved FCPXML engine/DTD checks and original-source preservation. Native GUI create/autosave,
script approval, queued requests, open, playback and PDF export are verified. GUI drop/plan
approval, full VoiceOver, and actual Final Cut import remain unverified. Live Claude
integration is absent. Synthetic placeholder assets are not production house artwork.
Final main-agent build/test counts and the wider requirements checklist live in
[IMPLEMENTATION.md](IMPLEMENTATION.md).

## Later increment review

The same independent reviewer inspected ordered multisource narration and its
source/key manifest, timeline mapping, aggregate read-back and saved-version gates.
Fixed findings covered copied intake keys, narration order preservation, source-local
removed spans, frame tolerance at source boundaries, empty assembled speech, and
fallback to an individual clip's artifacts when aggregate evidence is missing.
Synthetic checks passed; actual two-source cached-model acceptance was performed
separately by the main agent. Interactive GUI narration ordering remains unverified.

The selected ONE R import/proof review reproduced four gaps and verified their
fixes: descriptor-anchored card ancestors defeat symlink swaps, evidence cannot be
written to the card or overwrite an existing receipt, expected sizes are rechecked
after source fingerprinting, and a short secondary-camera input cannot become a
successful frozen-frame proof. A shared destination-descriptor leak on failed
source open was also fixed with ExitStack and a regression check. The reviewer
independently passed **34 synthetic import/proof tests**. Live missing-footage import
and physical camera synchronization remain unverified.

The provisional synthetic-only Claude adapter review found three additional gaps:
an unbound result could succeed without any session identity, a process crash could
lose partial streamed output, and malformed denial/result fields could be treated
as successful output. Results now require an observed matching identity, each
received line persists running text/events before UI callbacks, and supplied fields
must have the expected types. Cancellation uses the specific turn identity so a
late handler cannot stop a newer turn.

The final independent run passed **45 routine core tests**, including eight
synthetic conversation fixtures; **two opt-ins skipped**. Whitespace was clean and
no remaining blocking finding was found in the reviewed synthetic adapter. There
is no live Claude transport or verified real CLI event capture, so M2 remains
incomplete. An external planning attempt with private transcripts was initially
rejected by automatic approval review before execution. A later separately
authorized CLI planning turn was allowed after the original direct-human approval
was supplied. That private turn is outside this synthetic adapter review and does
not verify the app's live integration.


## Expanded-workflow independent review (14 October)

The separate read-only reviewer checked duration gates, frozen output settings,
raster resolution scaling and the selected-version derivative engine. Review found
and reproduced missing-field bypasses, fixed pixel tokens, lost connected framing,
filename quoting, malformed XML errors, parent hash drift, silent animated-volume
flattening and a cross-language half-frame rounding mismatch. Each was corrected
with a focused regression. The model fallback now uses saved legacy settings;
new settings carry a paired schema marker and symmetric equality checks. Exact
parent bytes are bound before parsing, unknown automation is refused, and captions
use a fixed safe working-directory leaf. Native request/receipt verification and
engine pinning were added; the final independent recheck found no remaining code blocker in this bounded
increment. It passed 185 combined Python tests, a 54-test narrow recheck and
29 routine native workflow tests, with two opt-ins skipped. Direct native SFX
identity/timing/hash refusal regressions were subsequently added and passed locally.
GUI and scientific/visual acceptance remain separate and pending. The review used synthetic media only.

## Script review duration and recovery checks (14 October)

The independent reviewer reproduced inflated duration from overlapping ASR words
and invented join pauses, lost minimums on resume, prior approval bypassing a new
brief, and review pairs lost between provider completion and journal publication.
Regression tests now cap articulation by measured interval union, retain immutable
hash-linked revision records, persist constraint incompatibility across resumes,
and refuse new turns until missing or unknown verdict receipts are reconciled.
Successful provider output whose observed identity or denial metadata is unverified
cannot silently become a failed attempt that resets accounting.

Final bounded review passed **93 synthetic tests** and whitespace checks, with no
remaining concrete blocker in the reviewed duration/adapter changes. It performed
no provider calls, private-media access, NAS writes or GUI activity. This verifies
the mechanism, not delivered runtime, editorial quality, scientific facts or
authorization for an actual external provider call.

The following scope review found that requiring480s of capped articulation before
review overconstrains a finished video that may include useful recorded process.
Source-valid drafts now reach both actual reviewers with an adapter-owned critical
duration-evidence issue. Models cannot omit or resolve it by assertion. Paired
editorial agreement can be recorded while picture remains blocked on local timing
or actual human evidence; no invented B-roll credit is added. This adapter repair
passed95 independently reviewed cases. Replay protection then unions qualifying
articulation by physical source SHA, including alias IDs and overlapping/repeated
selections; raw word/span totals remain distinct. The projection module passed77
focused cases. The latest combined local run passed142 cases, including recovery
of complete provider pairs, altered evidence refusals, receipt reuse, cap
exhaustion, and refusal-only input binding. The raw provider result stays intact;
an unbound agreement cannot be recovered as approval. Only a later verified
exact-SHA receipt closes the host identity marker. Larger unapproved prior drafts
are source-validated revision material and carry no review or approval credit.
Encoded MP4 duration still
needs ffprobe/decode validation; FCPXML duration alone does not prove delivery.

Independent recovery review found a symlinked round ancestor could escape the
original output directory. Recovery, seed selection and accounting now reject
round/attempt/role aliases before artifact reads or writes. Six synthetic
regressions assert foreign files remain unchanged and no round is journaled.

The independent reviewer reproduced all 132 focused cases after the containment
repair and found no concrete blocker for completed revise responses with empty
or mismatched string SHA. Missing/non-string SHA and other malformed response
shapes remain fail-closed; this recovery does not invent completed valid verdicts.

The provider-rate-error repair passes 142 independently reproduced focused cases.
The CLI can emit first-party HTTP429 with subtype success while is_error=true.
Recovery accepts this only with matching prompt/session/terminal evidence, a
rejected rate event, no actual verdict or tools, and no contradictory saved
result/refusal/repair artifact. Calls remain blocked before the provider reset.
The original completed writer can be paired once with a fresh missing reviewer;
its original script and receipt are preserved. This does not extend the round cap.

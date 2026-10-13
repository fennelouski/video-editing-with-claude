# Independent local workflow review

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
incomplete. An external planning attempt with private transcripts was rejected by
automatic approval review before execution; direct human permission is still
required to override the original privacy restriction.

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

## Final independent result

29/29 Swift core tests passed, including the actual engine strict asset-gate process,
reopen, approval, cancellation and version regressions. 12/12 engine contracts passed
in the independent run; the main final contract run includes one additional explicit
script-dispatch test. Whitespace checks and native build succeeded. No remaining
blocking finding was found in the reviewed increment.

## Remaining acceptance limits

GUI/VoiceOver checks, a full actual-model transcription-to-cut run, and Final Cut
import of rewritten timelines remain unverified. Live Claude integration is absent.
Final main-agent build/test counts and the wider requirements checklist live in
[IMPLEMENTATION.md](IMPLEMENTATION.md).

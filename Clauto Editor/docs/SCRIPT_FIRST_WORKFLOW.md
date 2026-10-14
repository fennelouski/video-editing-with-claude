# Script-first editorial workflow

The edit now has a source-bound review ledger in `scripts/editorial_workflow.py`.
It records actual completed review receipts and blocks picture, music and graphics
until their preceding stages are confirmed. This supplements the existing native
pipeline; a native script-review screen and live GUI provider transport remain pending.

## Requirements checklist

- [x] Preserve timestamped source transcripts and original media identity.
- [x] Select spoken material using source SHA and inclusive word indexes; derive
  exact words and time ranges locally instead of trusting replacement narration.
- [x] Reject missing sources, stale hashes, fabricated words, invalid timestamps,
  ambiguous JSON and spoken pickup placeholders.
- [x] Keep pickups, coverage gaps and fact flags separate from recorded speech.
- [x] Require writer and reviewer receipts from independent observed sessions,
  each explicitly agreeing to the same exact saved script SHA.
- [x] Preserve actual script/verdict bytes, receipt identities and earlier issues.
  An omitted issue remains unresolved until its own role explicitly resolves it.
- [x] Cap completed review rounds at ten. Exhaustion is never approval.
- [x] Treat a model's `resolved_by="human"` as an annotation. Actual human fact
  evidence must be supplied separately by a trusted human-input boundary and bound
  to the issue and script SHA. The pure ledger cannot authenticate a person.
- [x] Enforce order: transcripts → approved script → picture/dialogue → music →
  graphics → final. Horizontal final requires at least ten seconds after dialogue;
  vertical delivery is exempt.
- [x] Offer a bounded, transcript-only existing-Claude-Pro CLI adapter in
  `scripts/claude_script_review.py`. It enables only the client's JSON formatter;
  code, file and browser tools, MCP, raw media,
  persistent sessions or paid API fallback. Caller must have actual user consent
  for that transcript purpose; command-line arguments do not grant permission.
- [x] Verify observed session IDs and completed provider results. Interrupted,
  cancelled, timed-out, denied or malformed attempts do not count as review rounds.
- [x] Add project creative-reference intake for `style_guide.md` and
  `taste_principles.md`, retaining exact original bytes, SHA, role and provenance.
- [x] Preserve distinct Library versions even when their content bytes match.
  Exact repeated attachments are deduplicated; prior versions remain retained.
- [x] Freeze creative-reference versions into each new native pipeline run,
  validating them against saved provenance instead of silently falling back.
- [x] Make run-selected guides available to engine planning/review stages through
  explicit hash-verified paths. Keep them out of narration script discovery.
- [x] Write generated watch/roundtrip corrections to a separate run-owned overlay
  when a guide is pinned; both original rules and overlay corrections remain binding.
- [ ] Integrate the review ledger, editable script selections and actual trusted
  human-approval inputs into the native editor UI.
- [ ] Apply approved selections to picture with source-audio boundary checks,
  natural breaths/room tone and a rendered-output readback.
- [ ] Complete local picture acceptance, tracked localized grade, final music,
  actual-artwork graphics, native captions and editable Final Cut handoff.
- [ ] Make per-run generated correction overlays available to later new runs as
  explicitly reviewed project correction versions.

## Incremental validation

Synthetic tests cover source grounding, issue carry-forward, independent role
identity, the actual round cap, human-evidence gates and stage ordering. Adapter
tests cover malformed/missing identities, disabled paid transport variables,
context changes and cancellation cleanup. Native reference tests cover exact-byte
provenance, same-content version updates, changed origins, frozen version changes,
cleared snapshot identities, and ancestor symlink escapes.

Actual project imports are opt-in local acceptance tests; routine tests use only
synthetic material. An isolated Xcode build does not launch or replace the running
editor. Codec, visible UI, subjective edit and scientific acceptance are separate
checks and must never be inferred from passing unit tests.

## Using the CLI adapter

Supply an existing authorized Claude executable, a timestamped source catalog,
the exact source-context file and its SHA, and a new output directory. The adapter
creates immutable local evidence for each writer draft, writer verification and
independent adversarial review. Those three turns comprise one review round.

If there is editorial disagreement, it revises and reviews again within the cap.
Failed source validation gets at most three technical writer repairs within that
round; those attempts are preserved and never counted as completed review rounds.
Resumption verifies the original input identity and retains the actual ledger
count; it cannot silently reset the ten-round limit or change the source pack.
If only actual human approval remains, it records that specific blocker. It never
renders media or advances the picture stage itself. Failed attempts and earlier
versions remain available for diagnosis; use a new output directory for recovery.

Katie's creative references govern the video identity. Clauto's own app brand is
specified separately in its design documents. Latest explicit project feedback
has precedence over older guide defaults; genuine contradictions remain recorded.

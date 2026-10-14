# Script-first editorial workflow

The edit now has a source-bound review ledger in `scripts/editorial_workflow.py`.
It records actual completed review receipts and blocks picture, music and graphics
until their preceding stages are confirmed. This supplements the existing native
pipeline. The native Transcript tab now supports project-owned source-row drafts,
ordering, exclusion, separate annotations and review-only export; paired-ledger
approval and live GUI provider transport remain pending. See [TRANSCRIPT_REVIEW.md](TRANSCRIPT_REVIEW.md).

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
- [x] Apply an explicit latest finished-duration brief during paired review. A conservative
  source-word planning estimate counts overlapping articulation once and excludes
  all unverified gaps, joins and suspiciously stretched alignment tokens. It
  cannot invent nonverbal padding. This lower estimate does not prove that useful
  recorded process coverage or verified natural timing cannot satisfy the goal.
  A host-owned critical duration-evidence issue blocks production when evidence
  is missing; models cannot remove it by prose or omission. Source-valid drafts
  still reach actual writer/reviewer sessions. Native project duration bounds,
  assembled timeline and the actual decoded/ffprobed export remain the final
  duration authority. B-roll overlays add zero runtime.
- [x] Record changing revision goals separately without replacing source inputs or
  resetting actual rounds. Immutable hash-linked directive records retain the
  effective brief even when a resume omits the directive option. A new brief cannot
  inherit an older approval. Writer and reviewer receive the latest brief and all
  carried unresolved issues; original receipts remain retained.
- [x] Offer a bounded, transcript-only existing-Claude-Pro CLI adapter in
  `scripts/claude_script_review.py`. All tools are disabled; plain JSON responses
  are validated locally. It enables no code, file or browser tools, MCP, raw media,
  persistent sessions or paid API fallback. Caller must have actual user consent
  for that transcript purpose; command-line arguments do not grant permission.
- [x] Verify observed session IDs and completed provider results. Interrupted,
  cancelled, timed-out, denied or malformed attempts do not count as review rounds.
- [x] Stop resumption before new provider turns if a completed writer/reviewer
  pair has not reached the journal. Recover the original receipts first; a crash
  between paired completion and publication cannot silently reset the round cap.
- [x] Recover a completed rejection with empty/mismatched string script SHA only
  as a distinct input-bound refusal. Original terminal/result bytes, session and
  receipt remain intact. Both START/FINISH prompt hashes and delivered script
  bytes must match; original unbound issue resolutions never apply. Its protected
  critical identity marker closes only after a later exact-SHA provider receipt.
  Unbound agreement is refused, and the recovered rejection consumes a round.
- [x] Supply larger prior source-valid writer drafts as explicitly unapproved
  revision material, with original provider result provenance and no round credit.
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
- [x] Add a native source-bound draft review screen with stable row ordering,
  explicit keep/exclude, comments, requested graphics, imported suggestions,
  immutable checkpoints and review-only export.
- [ ] Integrate paired-review ledger approval and actual trusted human-approval
  inputs into the native editor UI; apply approved selections to the engine.
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
context changes, cancellation cleanup, saved minimums, prior-approval constraints
and interruption before paired receipt publication. Native reference tests cover exact-byte
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
An explicit directive can set a minimum finished duration and target, and request
an earned question/reveal before a natural mid-video break with payoff afterward.
Such a note never configures an advertising platform, inserts a fake ad or gap,
guarantees ad serving, or grants new permission to upload.
If both agree editorially and only actual human or local duration evidence remains,
it records editorial consensus with production blocked instead of burning rounds
to force extra talk. The pure CLI has no external process-timing evidence intake
yet; such source-bound useful inserts require local verification, never invented
time. It never
renders media or advances the picture stage itself. Failed attempts and earlier
versions remain available for diagnosis. Resume the original source-bound ledger;
creating a new output directory does not authorize resetting actual review counts.

Katie's creative references govern the video identity. Clauto's own app brand is
specified separately in its design documents. Latest explicit project feedback
has precedence over older guide defaults; genuine contradictions remain recorded.

A verified first-party usage-limit failure never counts as a completed review.
The CLI success-subtype/error-flag variant requires terminal HTTP429, matching
prompt/session/receipt, rejected-rate evidence and absence of any saved verdict
or refusal. Resume only after its reported reset; preserve a completed writer
and obtain the missing independent reviewer, then count that original pair once.
No quota bypass, paid fallback or extra review round is implied.

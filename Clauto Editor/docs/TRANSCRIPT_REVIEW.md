# Native transcript review milestone

The native Transcript tab imports a saved complete transcript catalog and keeps
source speech separate from editorial choices. It uses the existing Clauto craft
palette, typography, authored icons and controls. This is a local review workspace;
it does not read a Google Sheet, contact Claude, approve scientific claims or apply
selected rows to the rendering pipeline.

## What is integrated

| Requirement | Implementation |
|---|---|
| Stable clip and passage identity | Original source IDs, full media/transcript hashes, inclusive word indices and exact catalog byte hash. Row IDs persist across search, reorder and notes. |
| Recorded speech and source time | Read-only words, original transcript In/Out timecodes and exact source seconds; full source details remain inspectable. |
| Reorder | Earlier/Later buttons, keyboard shortcuts and a global story-position field. Filtered views retain global positions; reorder requires clearing filters. Returning to an earlier source clip is supported in the review document. |
| Keep/exclude | Explicit Boolean decision; excluded rows and notes stay in the document and can be restored. All/Kept/Excluded filters plus text/clip/ID/comment search. |
| Comments | A separate editable comment field, with coalesced local saving through one project-captured controller. |
| Graphics | Requested graphics and handwriting reference are editable; imported assistant suggestions are distinctly labelled, read-only proposals. No artwork is generated or approved. |
| Save/reopen | Exact original JSON copy plus immutable revision checkpoints and an atomic current pointer. SHA checks refuse altered source/checkpoint bytes. |
| Undo and competing writers | Undo restores earlier choices into a new checkpoint. File locking and revision comparison refuse stale writes. A pending draft can be preserved separately before reloading another writer's choices. |
| Normal application quit | A narrow AppKit hook waits for pending review saves and operations. Failed unsaved writes require Keep Editing or an explicit Quit Without Saving choice. Core wait/refusal behavior is tested; native termination/dialog interaction remains unverified. |
| Selection export | Unique project-owned JSON containing ordered kept rows and every row's annotations, full source mapping, catalog/revision hashes, and source-boundary flags. Explicitly review-only and never approval. |
| Ordered source map | Exact saved revision and catalog byte hashes bind ordered source spans. A→B→A retains the original clip paths, inclusive word indices and original In/Out seconds. Half-open concatenation offsets are untrimmed review coordinates, never a rendered-cut runtime. Every selected word must fit its source span. |
| Source verification and preview | Streams the full local media SHA, rejects changes during reading, checks actual AVFoundation duration and non-empty audio-segment coverage, and verifies the declared original transcript snapshot/hash/words. Passage-relative forward playback and seeking are bound to the full revision/span receipt and exact completed seek. Local AVAsset references are restricted. |
| Explicit local acknowledgment | Both mapping and speech-order/notes checkboxes must be explicitly chosen for the exact clicked checkpoint. All kept originals are reverified before an immutable map and receipt are saved. This acknowledges only local source mapping/order/notes review; it does not attest listening, identity, scientific correctness, paired editorial agreement, or permission to render. |
| Render gates | A durable project association blocks whole-clip prepare, resume/settings and snapshot paths that cannot represent these choices. Missing/damaged review pointers or metadata ancestors do not silently restore legacy rendering. Exporting a package or recording the limited acknowledgment cannot unlock a cut. |
| Responsive native view | Wide list/inspector; compact list uses a passage-notes detail view with a Back action. Only synthetic offscreen composition has been checked. |

Source and choices are under `notes/transcript-review/<review-id>/`. The current
revision pointer and save lock are under `.clauto/`. Every checkpoint and export
has a unique identity; original media and imported catalog files are not edited.
Real app projects retain the configured NAS project location.

## Source acceptance

Only the complete catalog schema from `scripts/transcript_workbook.py` is accepted
in this increment. A catalog must include every word exactly once in its stable
rows. Unknown source IDs, altered source text/ranges, duplicated rows, missing
words, unsupported schemas and ambiguous JSON keys are refused. Original raw ASR
boundary errors are preserved and shown as required review flags; the editor does
not silently clip speech or certify a transcript as verbatim listening.

The imported catalog's full byte hash binds the saved draft, so retranscription
cannot silently reuse the same media-derived row IDs with different wording.
Catalog import and ordinary selection/map export do not read original media. Their
SHA values are catalog provenance. The separate Verify & Preview and Record Local
Source Review actions perform fresh, full local verification. If no original
transcript path is declared, a media-only preview is possible, but full source
acknowledgment is refused. A declared missing or altered snapshot is an error.

The whole-clip narration order in the current pipeline cannot express arbitrary
source-span ordering. The review export therefore stays independent of `narrationIDs`.
Saving or exporting choices never updates `script.md`, begins a cut, changes a
saved version, or asserts final human/independent-ledger approval.

## Source map and playback identity limits

A map uses `source-map-<UUID>.json` in the review exports directory. Local review
receipts and their hash-bound current pointer live under the same review UUID;
older receipts remain inspectable after an edit, but cannot acknowledge a later
checkpoint. Keep/order/comment/graphic changes clear current preview and receipt
state. Reordered rows are never translated into whole-clip `narrationIDs`.

Media verification checks a regular file descriptor and path identity before and
after a complete SHA-256 read, including inode, size, modification and change time.
The declared original transcript path, its resolved file signature, byte hash and
word timings remain bound to the pinned catalog. Missing media, different bytes,
repointed aliases and uncovered audio intervals are refused.

Playback is **verified at check time**, not an immutable-byte transport. AVPlayer
reopens a local path. Before Play and during periodic checks the editor rechecks
review and file identity and pauses on detected drift. This cannot prevent every
in-place change between checks. No interactive source playback, seek/replay,
drift-pause latency, VoiceOver or listening acceptance is claimed by this milestone.
A synthetic asset probe verifies metadata and coverage, not intelligibility.

The first valid catalog import writes `.clauto/transcript-review-required.json`.
A failed later import may leave that conservative association in place; retry the
catalog or inspect project recovery rather than automatically clearing the gate.
No source-span rendering integration, final editorial ledger or human fact-review
implementation is implied. The older Brief/graphic-plan approvals remain separate.

## Verification and limits

- Eighteen new routine tests cover exact-byte import, save/reopen, exclusion without
  deletion, returning to a clip, annotation separation, unique exports, bounds
  flags, undo preservation, changed catalogs/checkpoints, escaped duplicate keys,
  containment, competing writers, filtered identity, delayed project-bound edits,
  oversized-write refusal, backwards timing, edits during actual I/O, and pending
  saves/Undo during exit.
- The latest full core checkpoint passes 91 routine tests; five opt-ins are skipped
  (96 registered cases). Fourteen source-map regressions add actual synthetic PCM
  and delayed-audio probes, A→B→A and half-open boundaries, duplicate identities,
  interior-word overruns, empty choices, missing/replaced/changed-during-hash media,
  transcript hash/word/alias binding, stale in-flight checks, delayed acknowledgment
  clicks, reconnect recovery, damaged receipt/map refusal, and damaged/dangling
  metadata gates. A deterministic progress callback coordinates the real-I/O race;
  the test does not depend on a sleep completing before hashing.
- Opt-in local acceptance imported the actual saved yeast catalog: 27 sources,
  914 rows and 11,900 words. Ordering and separate annotations survived reopen,
  and selection export succeeded. The source-map increment also compiled 913 kept
  spans with original coordinates in a new labelled QA copy; the raw boundary
  overrun row was excluded only in that QA review. The catalog's input hash remained
  unchanged. Logical selection seconds were not used as rendered-runtime evidence.
  This used new explicitly labelled QA projects on the NAS, with no Sheet access,
  source-media reads/writes, provider calls or cut render/approval.
- The Debug native app build and strict bundle signature check passed without
  launching an app or changing foreground ownership.
- Synthetic offscreen captures check the integrated Transcript tab, selected
  inspector, scrollable source gates inside the full minimum-size app, long errors,
  and a physically missing synthetic source. They do not establish actual
  pointer, keyboard traversal, drag, VoiceOver or source-playback acceptance.

The opt-in acceptance requires `CLAUTO_TRANSCRIPT_CATALOG` and
`CLAUTO_TRANSCRIPT_ACCEPTANCE_ROOT`; routine tests use disposable synthetic inputs.
Private catalog contents and QA exports are not committed to the repository.

## Still proposed

- Apply source-span selections to the engine through a separately validated,
  immutable approved-script snapshot and actual independent-review ledger.
- Trusted human fact decisions and paired writer/reviewer agreement in the GUI.
- Within-passage word selection, split/trim, drag reorder, redo/history browsing,
  and returning a revised catalog while preserving existing decisions explicitly.
- Interactive acceptance of the implemented bounded source preview, and a future immutable-byte playback transport if stronger byte pinning is required.
- Foreground keyboard, pointer/drop and VoiceOver acceptance. Final source listening,
  rendered pacing and subjective editorial quality remain separate checks.
- Native termination/dialog interaction acceptance. The implemented quit hook
  protects ordinary application quit; forced process termination/power loss cannot
  preserve an uncompleted write. Source/import errors with no unsaved choices do
  not prevent exit.

The older free-text Brief approval button now captures its originating project and
exact clicked text before queuing its task. That existing approval still does not
become source-bound paired-review acceptance merely because this new tab exists.

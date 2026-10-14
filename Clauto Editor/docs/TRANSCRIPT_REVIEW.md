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
The import/export does not re-hash source media. Its media and transcript SHA values
are the saved catalog's provenance, not a claim of fresh media verification.

The whole-clip narration order in the current pipeline cannot express arbitrary
source-span ordering. The review export therefore stays independent of `narrationIDs`.
Saving or exporting choices never updates `script.md`, begins a cut, changes a
saved version, or asserts final human/independent-ledger approval.

## Verification and limits

- Eighteen new routine tests cover exact-byte import, save/reopen, exclusion without
  deletion, returning to a clip, annotation separation, unique exports, bounds
  flags, undo preservation, changed catalogs/checkpoints, escaped duplicate keys,
  containment, competing writers, filtered identity, delayed project-bound edits,
  oversized-write refusal, backwards timing, edits during actual I/O, and pending
  saves/Undo during exit.
- The final full core checkpoint passed 77 routine tests; five opt-ins were skipped
  (82 registered cases). All 18 routine transcript tests pass; their real-catalog
  opt-in is separately exercised locally on the NAS.
- Opt-in local acceptance imported the actual saved yeast catalog: 27 sources,
  914 rows and 11,900 words. Ordering and separate annotations survived reopen,
  and selection export succeeded. The catalog's input hash remained unchanged.
  This used a new explicitly labelled QA project on the NAS, with no Sheet access,
  source-media reads/writes, provider calls or cut render/approval.
- The Debug native app build and strict bundle signature check passed without
  launching an app or changing foreground ownership.
- Four new synthetic offscreen view captures check the integrated Transcript tab
  and selected inspector at wide/minimum widths. They do not establish actual
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
- Source playback with fresh media-identity verification and audio-boundary checks.
- Foreground keyboard, pointer/drop and VoiceOver acceptance. Final source listening,
  rendered pacing and subjective editorial quality remain separate checks.
- Native termination/dialog interaction acceptance. The implemented quit hook
  protects ordinary application quit; forced process termination/power loss cannot
  preserve an uncompleted write. Source/import errors with no unsaved choices do
  not prevent exit.

The older free-text Brief approval button now captures its originating project and
exact clicked text before queuing its task. That existing approval still does not
become source-bound paired-review acceptance merely because this new tab exists.

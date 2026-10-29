# Sole-writer combined source candidate — 2026-10-29

This isolated candidate lives at
`/Users/nathanfennel/Documents/Codex/2026-10-25/task-19/clauto-integrated-review`,
branch `codex/integrated-video-review`. It combines:

- The existing app lane `3fdc229`, including base `f57e6bf`, Storage/Sounds guard
  checkpoint `b6519b4`, and the seven independent review findings.
- The frozen Studio/handwriting lane `e08c41b`, including verified 3D source
  `4630b94` and the integrated handwriting source and storage draft-loss guard.

Both original branches/checkouts remain intact. Their merge base is `f57e6bf`.
No active app bundle, project, media, profile or current pointer was replaced.
The app remains one Clauto Video target and the same legacy bundle identity.

## Reconciliation actually performed

One textual conflict occurred: EditorStore's pending-work expression. The result
retains **both** unsaved sound edits and handwriting pending state, all earlier
controller checks, handwriting exit flushing, and its admission/adoption guard.
StorageSetupTests merged automatically; both lanes' test cases are retained.

The shared store also rechecks that Sounds windows and this project's review
players did not appear after storage admission, before evicting any controller
or switching a root. A new native fixture holds a late sound draft and verifies
that adoption refuses without changing root/catalog/draft. The safe adoption
path clears the new read-only history diagnostics along with the version cache.
No storage location or migration is assumed/confirmed by these guards.

Static source-union audit found:

- 23 app-lane exclusive files byte-identical to `3fdc229`; its request ledger
  retains the full original text with an appended integration-status link.
- 64 Studio/handwriting-lane exclusive files byte-identical to `e08c41b`.
- Exactly two shared files: EditorStore.swift and StorageSetupTests.swift, manually
  inspected for the combined guards and acceptance cases.
- 104 unique existing core-package source files; no missing or duplicate source,
  including connected writing, reusable 3D and handwriting controllers.
- Conflict markers absent. Source whitespace checks pass; the already pinned
  KayKit LICENSE first-line whitespace is retained verbatim rather than altered.

Machine receipt: `.artifacts/source-union-20261029/source-union.json`.
These are source/integrity checks, **not compilation or functional acceptance**.

## Acceptance remains pending

No new Swift build, unit/native/Python functional test, provider call, UI action,
phone installation, media playback or foreground takeover ran in this source pass.
The old running bundle remains on its existing saved version. All newly added
regression cases, including both lanes' native storage interleavings, are still
unexecuted. Prior 3D/handwriting pixel/export results are historical feature
receipts; they do not certify this new combined application.

One fresh bounded **macOS app compile** may be queued only after the coordinator
admits the final combined source commit/digest. Do not run the obsolete e08c41b
build request. Use a new task-local derived-data directory, jobs=2, low priority,
a 350-second owned-process watchdog, and the October 30 05:53:05 UTC hard cutoff.
The existing app is not terminated or launched for a compile. A full native
fixture run is a later separate resource admission, and keyboard/UI verification
requires a separately scoped foreground handoff and saved-state inspection.

Prepared targeted regression areas:

- EditorCommandTests and mixed-validity Workflow history recovery.
- LiveConversation/local-edit controller/history/render target pinning with fake
  clients only; no connected writer/provider acceptance.
- Storage controller/planning plus native late handwriting/Sounds adoption guards.
- Native ProjectExperience preview recovery, session/draft and replacement refusal.
- Existing GraphicDemo, handwriting, rendering/composition and source identity
  regressions, using their approved local fixtures and declared dependencies.

The current repository is a macOS app; the general phone-build instruction does
not create or authorize an unrelated iOS port. No signing/security/account,
external release, migration, source removal or user style/editorial approval is
implied. The French handwriting sample remains unapproved. Pan v014 and its
existing v013 current pointer are preserved; there is no v9 reimport or rollback.

The managed-worktree attachment tool was unavailable, so the candidate was
created as a normal local Git worktree inside task-19 after listing existing
worktrees. This changes no security permission or other owner's branch. No build
lease is held while this source checkpoint awaits admission.

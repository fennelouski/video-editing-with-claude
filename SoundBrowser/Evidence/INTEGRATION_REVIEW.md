# Current integrated sound-selection review

Date: 2026-10-25. Stable base `a0260bd`; isolated integration branch
`codex/sound-browser-integration-sol`. The prior standalone implementation is
commit `987865b`. This record supersedes the initial v2 standalone verdict.

## Actual editor integration

Clauto Editor's Cut review header now contains **Sounds…**. It opens an embedded
timeline sound inspector/browser inside the editor, pauses the current owned
review session, and loads the selected saved cut through the existing verified
WorkflowRepository source path. A selected connected audio cue can be replaced
explicitly, undone/redone, or saved as a separate immutable edited timeline.

The selected clip's offset, source start, duration, gain/fade descendants, lane
and role remain fixed. Both metadata and actual decoded samples must cover the
existing source interval. Short sounds are refused; long ones use the existing
trim. Browsing/search/recommendation changes do not invoke replacement.
Similarity uses category, tags and required duration only.

Publication uses ProjectMutationLease and descriptor-relative immutable writes,
binding physical project identity, parent timeline/version bytes and current
pointer. Selected verified audio snapshots are written with content-hash names
beside the edited XML; no whole audio library is bundled. Repeated save is
idempotent. The saved parent/current pointer are preserved.

This is an integrated **editable-timeline** change. It does not rerender the
saved movie, promote a version, or fabricate a completed DerivedCut/movie proof.
The in-app UI and receipt explicitly retain that boundary. The branch remains
unmerged and uninstalled; stable/live projects and paused worktrees are untouched.

## Catalog update

Supported current Library materialization obtained canonical manifest version 2,
private routing version 3, and metadata setup version 1. Setup ZIP: 1,124,608
bytes, SHA-256 `48357e13d0119a696ec14001ab47a02a2f8008f28fa293c36dbc10da68a30bf7`.
All internal SHA256SUMS entries passed; setup manifest bytes equal the canonical
manifest. Routing's latest setup pin agrees. No audio was downloaded for v3.

Catalog 3.0.0 contains 1,162 records in 20 categories. All 1,119 old IDs/hashes
remain unchanged; 43 new metadata references were added. Compact catalog SHA:
`169d8a73d8464f3435806436e8707126120f08590b0182692ce82c80f8c18e00`.
Public package compatibility SHA:
`48c5baeacfe4dd0ba14c04cd5c4369b5028a4f00c32d99d200307e6eb3ab1fed`.
It pins 12 compatible subset manifests without private delivery IDs. The actual
eight-sound v2 package links successfully under v3 after its manifest/membership
and original audio hashes are verified. The other 1,154 sounds were not downloaded.

There are 565 WAV and 597 Ogg references. PCM/float WAV is supported; Ogg is
explicitly searchable/unavailable for audition and selection. All sounds remain
NOT_AUDITIONED; technical validation never grants human approval.

## Verification

- Full Clauto Editor Xcode Debug build: **BUILD SUCCEEDED**, signing disabled,
  isolated derived-data folder. Existing pinned Sparkle dependency only.
- Local package: **10 tests pass**. Includes real representative hashes/decode,
  path confinement, stable references, metadata search/persistence, cancellation,
  replacement timing/trim/gain/fades, shorter-candidate refusal and undo/redo.
- Stable-engine insertion adapter: **6 tests pass**. Real silent synthetic video
  plus real selected WAV bytes; exact frame placement/trim/gain round-trip,
  parent/current preservation, idempotence/tamper refusal, stale pins, cancellation,
  root replacement, source confinement and shared-lock contention.
- Native editor controller: **2 tests pass** through the actual repository/lease
  implementation. They verify replacement/undo/redo, separate publication,
  idempotent repeated save, unchanged parent/current and stale-current refusal.

Actual native UI verification used a uniquely identified QA copy of the built
Clauto Editor and an isolated synthetic saved cut. Separate preferences and an
output-blocking audition player prevented live-project/production effects.
Observed through targeted computer-use actions:

1. Open Cut → Sounds inside the real editor; existing cue is Idea #2, frame 10,
   duration 24 frames, source trim 20 frames.
2. Open setup, open the native folder panel, cancel it, and observe no links.
3. Reopen the panel, navigate directly to the explicitly scoped package root,
   link it, and observe 8 available offline under catalog 3.0.0.
4. Type `boing` in the actual search field; select a row and press Down Arrow;
   candidate inspector changes while the timeline cue remains Idea #2.
5. Explicitly try Boing #8: insufficient decoded samples are refused, cue intact.
6. Explicitly replace with Boing #2: name changes, frame 10/duration 24/trim 20
   remain. Undo returns Idea #2; redo restores Boing #2.
7. Save the edited timeline. Readback confirms exact output hash, original parent
   hash, unchanged gain −15dB, and one separate immutable output. Similar-candidate
   filtering leaves the edited cue unchanged.

No audition/play control was activated. The former native-table reentrancy
warning was eliminated by replacing the SwiftUI List with an owned AppKit table
whose snapshot updates run outside delegate callbacks. The current actual editor
UI log contains no reentrancy warning. The picker bug was a nested-sheet queue;
using asynchronous application-modal presentation opens it correctly from setup.

An initial fixture mismatch came from `/var` versus `/private/var` spelling;
physical path canonicalization corrected it. The actual stable writer retains
the continuous cue across the shot boundary in the tested insertion fixture.

## Current holds and remaining acceptance

Nathan requested foreground control while signing in. The QA process was closed
immediately and visible automation is paused pending handback. A fresh integrated
screenshot was not captured before that hold. Existing v2 standalone screenshots
are retained and clearly labeled historical; they are not current integration
captures. Corner-control styling awaits clarification between the Close/Minimize/
Zoom cluster and the separate video/full-screen controls; neither has been changed.

Library upload of the named earlier screenshot and concise review was rejected
before process execution by automatic approval review, which could not verify
trusted authorization for the payload/destination. Explicit approval is pending;
no Library file IDs or upload success are claimed.

Other unobserved acceptance: human audition/output-device quality, spoken
VoiceOver traversal, expanded text sizing, measured contrast across settings,
external-drive remounts, Ogg decoding, movie rerender, saved-version promotion
and Final Cut import. Verdict: verified local editor integration for bounded
editable sound replacement, with the above holds and limits; not release approval.

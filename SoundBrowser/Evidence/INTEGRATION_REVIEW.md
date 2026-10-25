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

**Create local export** now uses the normal EditorStore/DerivativeService worker
and existing derivative export history. A typed selection pins the parent, saved
edit receipt and edited XML; native and Python checks bind selected WAV hashes
and compare canonical XML to refuse unrelated video/timing/gain/fade changes.
The renderer snapshots its sound proof, rechecks it after rendering, and normal
repository verification admits the actual DerivedCut. **Review edited movie**
opens paused. The original saved movie/current pointer stay unchanged and no
main cut version is promoted. The branch remains unmerged and uninstalled;
stable/live projects and paused worktrees are untouched.

Existing renderer limit: animated adjust-volume envelopes are retained by the
editor but explicitly refused during local export. A real fixture verifies that
refusal and that no derivative is admitted. Static gain is rendered and checked.
Optional sound integration is loaded only for sound-edit exports; ordinary
exports retain their existing dependencies.

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
- Native editor controller: **3 tests pass** through the actual repository/lease
  implementation. Includes normal-service FFmpeg export and derivative-history
  admission, silent PCM comparison, tampered-edit refusal, animated-envelope
  export refusal, replacement/undo/redo, separate publication, idempotence and
  stale-current refusal. PCM correlation with the replacement is 0.99997275;
  amplitude ratio is 0.99917625 after the preserved −15dB gain. Correlation with
  the old sound is −0.000107. No audio playback is used for this measurement.

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
8. Fresh final build: direct mouse row selection works and the result pane fills
   the available height. Save → Create local export succeeds; Review edited
   movie opens at 00:00 with Play available, without autoplay. The latest admitted
   export, complete decode/picture cadence checks and output hashes are recorded
   in integrated-export-verification.json. DTD schema checking was unavailable
   in the installed stdlib-only Python runtime: schemaChecked remains false.

No audition/play control was activated. The former native-table reentrancy
warning was eliminated by replacing the SwiftUI List with an owned AppKit table
whose snapshot updates run outside delegate callbacks. The current actual editor
UI log contains no reentrancy warning. The picker bug was a nested-sheet queue;
using asynchronous application-modal presentation opens it correctly from setup.

An initial fixture mismatch came from `/var` versus `/private/var` spelling;
physical path canonicalization corrected it. The actual stable writer retains
the continuous cue across the shot boundary in the tested insertion fixture.

## Corner controls and final local evidence

Observed main-window Close/Minimize/Zoom controls received the requested bounded
polish: 22px softly rounded faces in 28px hit regions, 12px visible gaps, 96px
cluster (formerly 88px), and 18px top padding (formerly 14px). Glyphs are slightly
smaller and native actions remain unchanged. Zoom/restore and minimize/restore
were observed. Native Close returned with visible=0; the computer-use observation
was reopening the last window during earlier inspections, so the final check
recorded the native result before any subsequent UI observation. No native
delegate veto was bypassed. The QA app was terminated after verification at
10:43 UTC, ahead of the 10:45 Studio restoration; no lock/awake settings changed.

Final actual captures:
- captures/clauto-integrated-sound-editor.png — catalog 3.0.0 inside the editor,
  explicit replacement, preserved cue frames, real waveform and verified export.
- captures/clauto-editor-window-controls.png — bounded main corner styling.
- integrated-ui-report.json — 1,162 indexed, 8 available, zero playback attempts,
  NOT_AUDITIONED, frame 10/source frame 20/duration 24.
- integrated-export-verification.json — normal admitted export, decoded PCM
  comparison, immutable source hashes and parent/current preservation.

## Remaining approval and acceptance

Library upload of the earlier named screenshot and review was rejected before
process execution by automatic approval review: it could not establish trusted
approval for the project-derived payload and external Library destination.
Explicit approval is pending in the parent conversation. Nothing was uploaded;
no Library IDs exist. No alternate route or retry was attempted. Fresh captures
and the revised review are saved locally and have not been uploaded either.

Unobserved acceptance: human audition/output-device quality, spoken VoiceOver,
expanded text sizing, external-drive remounts, Ogg decoding, animated-envelope
rendering, main-version promotion and Final Cut import. The external provider
contract is proposed metadata, not a live download service. Verdict: verified
local editor integration including normal static-gain sound replacement export;
not release, installed-app or human approval.

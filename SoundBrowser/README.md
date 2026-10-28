# Clauto sound selection and timeline replacement

Implementation owner: this new Sol task. Stable source base `a0260bd`.
Initial browser commit: `987865b`, branch `codex/sound-browser-sol`.
Integrated work: `codex/sound-browser-integration-sol`, isolated local checkout.
No paused worktree or installed/stable app is changed.

## In Clauto Editor

Open a saved cut, choose **Sounds…**, and select a connected audio cue. The
embedded browser provides category/tag/text search, actual WAV peak envelopes,
duration/format/license/source details, persistent favorites/collections and
explicit Audition/Stop/Volume controls. Browsing never changes the timeline.
**Replace selected sound** is the explicit edit.

Replacement preserves timeline position, source trim, duration, gain/fade XML
and connected-audio role. Longer candidates use the same range. Candidates
without enough actual decoded samples are refused; no stretch, loop, padding
or retiming is introduced. Undo/redo restores XML and its portable references.
Similarity ranks category, tags and required duration; no acoustic-model claim.

**Save edited timeline** publishes an immutable child under
`build/derivatives/<UUID>/` through Clauto's common project mutation lease. It
rechecks physical root identity, exact saved timeline/version bytes and current
pointer, freezes only selected audio snapshots, and writes FCPXML plus a
hash-linked reference receipt. Repeated save is idempotent. Parent/current stay
unchanged.

**Create local export** passes the saved, pinned replacement through the normal
`EditorStore → DerivativeService → timeline_derivatives.py` render path. It
validates the original parent, edited XML, reference receipt and selected WAV
snapshots before/after rendering; canonical XML comparison refuses unrelated
picture/timing/gain/fade edits. The verified movie appears in existing derivative
export history and **Review edited movie** opens it paused. The saved parent
movie/current pointer remain unchanged; no main cut version is promoted.
Animated volume envelopes remain preserved in XML but the existing renderer
explicitly refuses them for local export. This unmerged integration needs its
matching editor/engine metadata code; it is not an installed release. Human
audition/approval remains `NOT_AUDITIONED`.

## Separate linked library

Shipped metadata: **1,162 references**, release **3.0.0**, 20 categories. All
1,119 previous IDs/hashes are preserved. Only the eight-sound crowd/cartoon
package was materialized; no audio was downloaded for the 43 new references.

Setup starts disconnected. Link a package root containing `audio/` and
`asset-library.json`. Public compatibility metadata pins all 12 subset manifests
by actual byte hash, allowing compatible older packages under master v3. Folder
bookmarks preserve selection; missing/stale roots need relinking. Only known
package-relative paths are read. No home scan, automatic download, codec install
or original-library write occurs.

Availability requires a pinned package manifest, exact ID/hash/path membership,
original-byte SHA-256, supported WAV decoding and matching duration/rate/channels.
CC0 rights have hash-checked bundled license evidence. Playback/replacement
recheck immutable bytes. Originals are never moved or normalized. Explicitly
selected project snapshots are separate from app bundling.

PCM/float WAV is supported. The catalog has 565 WAV and 597 Ogg references. Ogg
stays searchable and explicitly unavailable for audition/selection. Envelopes
use every real WAV frame, peak across channels, 128 linear-amplitude bins.
Missing/unsupported media has a placeholder, never an invented waveform.

`Resources/providers.json` is a separate proposed public acquisition contract,
not a downloader. Private Nathan Library IDs delivered inputs only and are
absent from shipped catalog/provider/compatibility/reference data.

## Package and integration

Local products: `SoundBrowserCore`, `SoundBrowserUI`, plus a standalone dev host.
The editor Xcode project links those products. `ReviewWorkspace` opens
`SoundTimelineEditorView`; `SoundTimelineController` owns the verified draft.

Portable references contain library ID/version, case-sensitive asset ID,
`sfx://asset/ID`, original hash, duration, license and audition state, without
machine paths/private delivery IDs. Insertion requests use integer frames at
1001/24000 seconds, explicit gain and strict bounds/release validation.

`Integration/sound_timeline_adapter.py` exercises the stable engine FCPXML
reader/writer for explicit insertion. It verifies placement/trim/gain and parent
preservation using the common lock and descriptor-relative writes. It does not
fabricate movie/full-decode or editor-history admission receipts. The actual
editor replacement implementation is native Swift.

`Tools/update-catalog.py` derives future metadata from an explicitly pinned
local release and refuses silent changes to existing IDs/hashes. Updates are
reviewed releases, not automatic load/reconnect actions.

## Verification

`Tools/build-local.sh` builds the standalone dev host. Build the editor from
`Clauto Editor/Clauto Editor.xcodeproj`, scheme `Clauto Editor`, Debug, signing
disabled, using workspace-local derived data. Neither build installs/deploys.

`Tools/verify-local.sh /absolute/package/root`: 11 package tests.
`Integration/test_sound_timeline_adapter.py`: 6 engine-fixture tests with
`CLAUTO_SFX_TEST_ROOT` and installed FFmpeg, without audio output.
Root SwiftPM `SoundTimelineControllerTests`: 3 native controller fixture tests,
including an actual normal-service render, derivative-history admission, silent
PCM comparison to the chosen trim/gain, and animated-envelope export refusal.
Actual UI checks cover search, keyboard, picker cancel/link, short-candidate
refusal, explicit replacement, undo/redo, separate save and normal local export.
Direct mouse selection and corner zoom/minimize/restore are verified. Audition
is blocked; no automated playback is started.

See `Evidence/INTEGRATION_REVIEW.md` for current evidence. `Evidence/REVIEW.md`
and initial captures are historical standalone v2 evidence. Remaining acceptance:
human audio/output quality, spoken VoiceOver, expanded text sizing, external
volume remounts, Ogg decode, animated-envelope rendering, Final Cut import and
saved-version promotion.

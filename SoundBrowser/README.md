# Clauto sound browser — isolated Sol implementation

New owner: this task, `codex/sound-browser-sol`. Source pin: `a0260bd`.
All feature files live under `SoundBrowser/`. Existing editor, pipeline, design
review, 3D Studio and handwriting files have no changes. This is an independent
local clone/checkout; it does not share mutable Git metadata with paused worktrees.

## Current product

Native macOS SwiftUI browser with 1,119 version-pinned metadata records, 14
categories, all-word title/tag/creator/ID search, tag filtering, keyboard-native
row selection, measured peak envelopes, duration/format/license/source details,
explicit audition/restart/stop/volume controls, persistent favorites and named
collections, and hash-checked JSON selection/drag handoff.

The first frame is disconnected. Setup links an explicitly chosen **package
root containing `audio/`**. Multiple packages can be linked independently. Folder
bookmarks preserve the selection; an unavailable/stale bookmark needs relinking.
Only known catalog-relative paths are checked, and linked folders are read-only.
No audio is copied into the editor bundle. No network code runs at launch,
selection, missing-file recovery, recheck, or any other runtime path.

Available means original bytes match the pinned hash, supported WAV samples
decode, duration/rate/channels match the catalog, and the catalog's CC0 rights
record is supported by hash-checked bundled license evidence. It does not mean
a person listened or approved the sound. `NOT_AUDITIONED` is preserved even after
an audition request; the browser does not infer human listening or approval.

PCM/float WAV envelopes come from every original sample frame (peak across
channels), with 128 linear-amplitude bins. Missing files show a placeholder,
never invented waveforms. Ogg and other codecs are explicitly unsupported in
this initial local decoder; no codecs or proxies are installed automatically.
The representative eight-sound crowd/cartoon package is all supported WAV.

## Build and open

Run `Tools/build-local.sh` from this directory. It builds without external
dependencies and creates `.build/Clauto Sound Browser.app`. This is a local
unsigned prototype, not an installed editor integration or distribution build.
The app's normal browser preferences live in a separate `Clauto Sound Browser`
Application Support directory. No existing Clauto preferences/projects are used.

For sound previews, use Library setup → Link library folder and choose an
extracted sound package root. Cancel leaves current links intact. Check again
refreshes availability. Disconnect preserves references/favorites/collections
and never deletes originals. Actual playback requires pressing Audition.
The volume slider affects audition only; it never changes timeline gain.

## Editor integration boundary

Add this local package's `SoundBrowserCore` and `SoundBrowserUI` products when
the editor owner is ready. A project-owned `SoundBrowserStore` can be passed to
`SoundBrowserView(store:onSelection:)`. Without that callback the host says
**Prepare selection**, exposes its JSON and supports copy/save/drag. It never
claims a timeline insertion occurred. Drag representations are
`com.clauto.sound-reference` and `public.json`.

`SoundSelectionReference` carries library ID/version, case-sensitive asset ID,
`sfx://asset/ID`, expected original SHA-256, duration, license and audition state.
It contains no machine path or private Library ID. `validate(catalog:)` rejects
identity/version/hash/URI/rights drift. The editor adapter must re-resolve the
same pinned release, recheck local bytes, bind the saved-cut/timeline identity,
and publish through Clauto's existing project mutation/derived-cut path.
The browser does not hold that lease or mutate a saved cut.

`SoundInsertionRequest` provides validated integer timeline/source/duration
frames at **1001/24000 seconds per frame**, with explicit independent gain.
Decoded requests validate timebase, finite gain and source bounds; the receiving
adapter must also call `validate(catalog:)`. Keep the cue as a connected editable
audio layer using existing engine FCPXML machinery. Source-time placement must
pass through the engine's timeline map before constructing the request.

## Versioned catalog and provider contract

Bundled metadata is derived from the canonical Library manifest version 1,
content release 2.0.0. The compact catalog digest is pinned in code; license
evidence files are individually hashed. An updated catalog is a new reviewed
metadata release, not an opportunistic replacement on launch. Preferences retain
IDs missing from a future release so user collections are not silently erased.
Portable cues continue to require their exact library version and media hash.

`Resources/providers.json` preserves the separate **proposed public provider
reference contract**: original source pages, explicit optional acquisition modes,
immutable archive/file hashes and budgets where supplied. It is reference data,
not a downloader. Private Nathan Library IDs only delivered inputs into this
workspace and are absent from shipped metadata/provider/cue data.

A future acquisition adapter must show selected collections and destinations,
bind consent to release/URLs/hashes/byte limits, validate safe extraction and
license evidence, then atomically publish availability. Nothing in this module
uses private Library delivery as a public distribution backend or silently
downloads all assets. Original-provider manual acquisition is the current setup
route for optional collections.

## Verification and limits

`Tools/verify-local.sh /absolute/path/to/eight-sound-package` runs deterministic
tests with a fake audio player; it never sends audio to an output device.
`Tools/capture-local.sh /absolute/path/to/eight-sound-package` captures actual
running native window content at large/compact sizes and light/dark appearance,
using a QA-only player that blocks output. It drives state through the same
controller methods as the UI, without synthesizing clicks or stealing focus.
Captures are implementation evidence, not design or human approval.

Remaining acceptance: human audition/output-device behavior, VoiceOver spoken
traversal, physical keyboard/drag target interaction, native picker cancellation,
disconnected/remounted external volumes, expanded text sizing, public acquisition
adapter and editor timeline integration. These must not be reported as verified
from a screenshot or compile result. No deployment, notarization, store upload,
account creation, paid service or live project change is part of this task.

> Historical initial standalone v2 review. Current integration evidence: INTEGRATION_REVIEW.md.

# Sound browser implementation review

Date: 2026-10-25. Owner: new Sol sound-browser task. Base: `a0260bd`.
Branch: `codex/sound-browser-sol` in an independent isolated local checkout.
Only `SoundBrowser/` is owned/changed by this implementation. Stable source and
paused 3D/handwriting worktrees retain their original status.

## Product and evidence

The user's job is to find a suitable real sound visually, inspect its shape and
rights, explicitly audition it, then hand a verified reference to editing.
The stable editor has no sound browser at this pin. This module provides a new
native browser and portable integration boundary without changing saved cuts.

Canonical metadata was materialized through the current Library skill and its
supported transfer helper. Original setup ZIP: 894,373 bytes, SHA-256
`4b032ce51b4d488d51d653cb6a53322cf970379cb090bafde963e2c91028f924`.
Eight-sound package ZIP: 20,660,972 bytes, SHA-256
`e525ed809917d64703e82094154a68cd6c95efa9e5043b96dbdc6093a33f9f28`.
All archive SHA256SUMS entries passed; representative media hashes, full WAV
sample parsing, rate/channel/duration and nonzero envelope bins passed locally.
See `input-receipt.json`. The other 1,111 sounds were not downloaded by this task.

Shipped catalog: 1,119 references, content version 2.0.0, 14 categories. Compact
metadata is 899,192 bytes, SHA-256
`bac71f92609b2cd23a7ef9aafe7a895d5907eb96fb56ee938d7d4797038bdc67`.
The bundle contains zero WAV/Ogg files and no private Library delivery IDs.
All 1,119 records remain `NOT_AUDITIONED`. Public provider references remain a
separate proposed acquisition contract; there is no runtime downloader.

## Build and functional verification

Apple Swift 6.4, arm64 host macOS 26, Xcode SDK macOS 27.0, Debug, Swift 5 language
mode. Module deployment target macOS 15. No external package dependencies.
Build caches and output stayed in this checkout. `Tools/build-local.sh` builds
the package products and the local metadata-only review `.app`.

`Tools/verify-local.sh` passes **7 tests, 0 failures**, with the real eight-sound
package supplied explicitly by environment. Cases cover:

- Search by stable ID, category, tags and all words; metadata/audition truth.
- Real original-byte hashes, measured duration/rate/channels and peak envelopes.
- Traversal, symlink, oversize, nonfile and malformed/unsupported-media rejection.
- Portable identity/version/hash/URI validation and integer frame timebase,
  bounds/overflow/gain checks, including decoded requests.
- Repeated selection/favorite/membership actions, persistence, cancellation,
  missing-file and modified-file rejection, relinking and disconnect.
- Audition dispatch and stop/selection behavior through a fake player only.

Final native-window QA: `runtime-report.json` records 1,119 catalog records,
8 available offline and **playerStarts = 0**. `Tools/capture-local.sh` uses an
output-blocking player. It drives the actual store/controller used by views and
captures the running NSWindow's own view via AppKit `cacheDisplay`. These are
implemented native layouts, not mockups, screen recordings, or synthesized clicks.
The packaged `.app` is separately run with this same silent mode to verify its
resource bundle. No automatic human audition/approval is recorded.

## Visual review

Captures exclude titlebar and use native default text sizing at 1× backing scale:

| Capture | Size | Observed state |
| --- | --- | --- |
| `01-disconnected.png` | 1220 × 790 | First useful frame, metadata only, setup visible |
| `02-real-envelope.png` | 1220 × 790 | Eight available WAVs, measured selected envelope, controls |
| `03-selection-contract.png` | 1220 × 790 | Favorite, collection and prepared selection reference |
| `04-search.png` | 1220 × 790 | Text-filtered boing results and selection |
| `05-empty.png` | 1220 × 790 | Empty search and clear-filter recovery |
| `06-missing-compact.png` | 860 × 640 | Missing paper asset, disabled audition/insertion, setup visible |
| `07-dark.png` | 860 × 640 | Dark appearance, preserved query/category/selection |

Source hashes are recorded in `source-hashes.json`. Runtime screenshots live in
`captures/`. Primary/secondary text and separators use native semantic colors.
Accent: light sage RGB(0.24,0.35,0.19), dark sage RGB(0.68,0.81,0.55).
Sidebar: light oat RGB(0.93,0.93,0.90), dark RGB(0.14,0.16,0.13).
Type: native title/title2/body/caption; metadata IDs and numeric durations use
monospaced variants. Insets 12/18/20/26 pt, row padding 8 pt, corner radius 5/6 pt.
Selected rows keep native selection behavior. No perpetual animation is used.

Review fixes: setup was initially below the category scroll, so it is now pinned
in a visible footer; inspector/sidebar widths were bounded for compact layouts;
repeated collection creation now preserves membership rather than toggling it.
No new cosmetic pass is needed for the inspected scope.

## Limits and verdict

**Pass with stated limits for a standalone local prototype.** It is not installed
into Clauto, integrated into the timeline, approved by a human, or release-ready.
The native capture log emits an NSTableView delegate reentrancy warning on this
SDK. Captures and selection flows completed without a crash; the warning remains
an open runtime issue and needs physical interaction/release-SDK investigation.

The initial envelope/availability decoder supports PCM/float WAV. The full catalog
has 522 WAV and 597 Ogg references. Unsupported formats remain searchable but
cannot be auditioned/selected by this module until a supported decoder is added.
No automatic codec installation, proxy generation or format substitution occurs.

Unobserved: actual audio-output behavior and human audition; physical keyboard
and drag target interaction; native folder/save picker cancellation; spoken
VoiceOver traversal; measured text contrast at all system settings; expanded
accessibility text; unplug/remount behavior on an external drive. Controller
cancellation and missing/relinked local folders are tested, and compact/light/dark
window state is captured. These narrower checks do not establish those unobserved
acceptance claims.

Remaining integration: editor owner wires the injected callback to existing
project mutation/derived-cut/FCPXML flows and validates exact saved-cut identity,
reference release and source hash. Public optional acquisition remains a future
adapter with explicit collection/destination consent and bounded verification.
No paid service, deployment, upload, account, credential, TCC/security-permission
request, main-project change, or model switch was performed.

# Expanded feature acceptance checklist

Nathan requested all eight features on 13 October 2026. These are implementation
requirements. A compiled control, mock, schema, or unreviewed prototype does not
satisfy the complete feature. Each batch requires independent code review and
actual local synthetic output/GUI acceptance. The recovered camera import and
pizza correction remain the immediate priority; this checkout remains isolated.

| Feature | Concrete acceptance criteria | Current status |
|---|---|---|
| 1. Generated scientific/3D graphics | Editable scene/model inputs; supported macOS GPU renderer; real animated frame/video export with alpha, timing and editable Final Cut layer; particles/physics, molecular/atomic/reaction visuals and imported/parametric object scenes; economic model inputs; visible assumptions and scientific approximation/validation labels; deterministic model checks and actual rendered-frame review. | Pending implementation. Platform APIs available; renderer choice and output acceptance still required. |
| 2. Version-specific feedback | Review saved current/older cuts, use playhead or a bounded time range, persist comment with project/version/timeline identity, seek to comments, resolve/reopen, survive app reopen and version restore without reassignment, preserve every cut/original; independent tests and GUI acceptance. | Core/UI implemented and independently reviewed. Persistent version/hash/range tests pass. Interactive save/reopen/seek/resolve and VoiceOver acceptance remain pending after an interrupted UI transport call. |
| 3. Background cutouts | Local foreground extraction with subject selection and usable manual correction; preserve source pixels/orientation and originals; transparent PNG/alpha output with source/model/parameter provenance; failed/empty masks visible; actual synthetic subject/edge/alpha acceptance and GUI intake into a cut. | Cutout Studio implements local source intake, subject selection, manual restore/erase and supplied masks, undo/redo, edge feather, source-linked immutable PNG revisions and draft recovery. Bounded source/core acceptance is recorded by its exact milestone receipt. Actual Vision, native interaction/VoiceOver, visual acceptance and composition into a saved cut remain pending. |
| 4. Editable fonts from images | Folder/sheet intake and editable character mapping; actual TTF/WOFF2; generated missing glyphs visibly distinguished from supplied glyphs; editable outlines/mapping; source hash/revision for every glyph; explicit replacement/new font revision when new originals arrive; old cut fonts remain immutable; shaping/counter and replacement acceptance. | Pending. Existing mapped-sheet tracing/font builder is a foundation. |
| 5. Vertical extraction | Derive a selected saved version into 9:16 with selected range/framing controls; preserve parent version and originals; maintain/remap captions, graphics, audio and frame timing; actual encoded portrait dimensions and visual safe-area acceptance; editable handoff and provenance. | Native saved-version controls and local derivative engine implemented. Actual portrait output, caption/alpha visibility, connected framing and parent preservation pass synthetic tests; a real native-service NAS export passes. Unsupported animated framing/volume and other Final Cut effects fail with a review message. Their local-export support and GUI/visual acceptance remain pending. |
| 6. Audio effects | Typed local effect settings and preview; actual processed audio/SFX in rendered output and editable handoff; preserve original audio, selected range/timing and effect provenance; decode, duration, peak and preview/export parity checks. | Gain, high/low-pass, compressor, short echo, local sound placement and exported playback implemented through immutable derivatives. Processed dialogue stays in separate PCM files in the editable handoff. Actual PCM/timing/SFX/decode/true-peak tests pass. Interactive preview/export acceptance and richer effects remain pending. |
| 7. Minimum/maximum duration | Optional numeric per-video minimum/maximum, valid finite bounds persisted and frozen per run/version; assembled output checked before acceptance; impossible bounds request review without padding, retiming or clipped sentences; GUI and actual gate tests. | Persisted native controls and frozen run/version limits implemented. Exact EDL and emitted FCPXML gates, CLI/JSON failures, source/saved snapshot checks, tamper rejection and preservation of the previous cut pass tests and independent review. Interactive GUI acceptance remains pending. |
| 8. Per-video/default resolutions | Persistent global default plus project override, backward-compatible loading and frozen output settings; actual preview/export/FCP dimensions agree; graphics, captions and safe areas scale consistently; visible upscale warning; real 720p/1080p/2160p landscape/portrait output tests. | Global new-project default, project override and frozen resolution/aspect/model implemented. Canvas, graphic layout/shadow/motion, captions and safe areas scale together; source formats remain distinct from output format. Six actual encoded aspect/resolution tests and raster/schema checks pass. Rough-cut pacing previews retain source dimensions; final derivative exports use chosen dimensions. GUI/default-reopen and visual acceptance remain pending. |

## Shared rules

Generated derivatives need a versioned manifest recording source hashes, selected
inputs, renderer/effect/font revision, parameters, scientific assumptions and output
hashes. They must not masquerade as scanned cutout variants to bypass the strict asset
gate. Nathan's explicit generated-graphics/particle request supersedes earlier blanket
bans for those requested modes; preserve the standard paper style's own rules and add
separate validation for generated scenes. A plausible picture is not a validated
chemical, physical or economic simulation.

No new paid services, credentials, private uploads or publication are enabled by this
app expansion. All real media/derived outputs remain on the NAS. The separately
approved pizza-planning Claude turn is outside live app integration acceptance.


## 14 October local verification checkpoint

The full deterministic engine checkpoint passed 712 tests. Later focused derivative
tests passed 15, including actual encoded dimensions/full decode, visible alpha and
captions, connected framing parity, PCM effects, local SFX timing and true peak,
immutable parent identity, malformed XML and filename handling. Native core tests
passed 56 routine cases; three opt-in acceptance tests are skipped by default.
The separate real native-service export passed using the previously verified
synthetic multisource NAS project. It created derivative
`2E1435D7-305F-4938-BCBC-1E6FB0FABE16`; the later half-frame-boundary test created
`3ED64D19-4C1F-40AE-A52B-12B940918C50`. Both preserved the parent/current pointer.
Three focused native derivative regressions also passed, including rejection of
SFX source/timing/hash mismatches and legacy request loading.

The macOS app builds locally. The earlier isolated GUI inspection was interrupted
after its transport call failed to return; this is not successful GUI acceptance.
No Final Cut/import controls or private media were used for these tests. No commit
has been pushed. Features 1, 3 and 4 still require substantive new implementation;
this checkpoint is not completion of all eight features.

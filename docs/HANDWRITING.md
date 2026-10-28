# Handwritten artwork and reveal studio

Open **Creative studio → Handwriting** in the native macOS app. This workflow is
an explicit, scoped exception to the older no-generated-art rule: Nathan requested
AI handwritten artwork. It does not authorize generated b-roll, texture replacement,
scientific claims, remote uploads of private assets, or changes to existing films.

## Architecture grounded in Clauto

`HandwritingDocument` preserves exact UTF-8 text, locale, original-image SHA-256,
provider/model/request/prompt provenance, extraction settings, editable paths,
integer frame timing, renderer implementation version, review and parent revision.
Unknown renderer versions are refused rather than silently changing saved animation. The studio uses the existing
`CutoutImageIO` oriented straight-alpha raster and `CutoutBrushStroke` coordinates.
`HandwritingRenderer` keys light/dark paper or preserves supplied alpha, then
derives a bounded ink skeleton and renders editable brush masks clipped to ink.
It is an **editable raster mask reveal approximation, not recorded or reconstructed
pen strokes**. Graph traversal can jump between branches; inspect and correct it.
It cannot certify spelling or recover a person's real writing order from a bitmap.

Storage follows the existing project mutation lease and descriptor-relative
`CreativeAssetFiles` publication conventions. Each save is a new immutable revision
under `assets/handwriting/<asset UUID>/<revision UUID>/`; the original encoded image,
document, extracted ink and quality report accompany it. `.clauto/handwriting-index.json`
records admitted revisions. Rejected revisions retain their reasons and pixels.
Regeneration creates a child revision; it does not replace a source image in place.

`HandwritingExportService` writes an independent ProRes 4444 alpha layer at exact
1001/24000 timestamps, with movement held on pairs of frames. Existing
`GraphicMovieVerifier` decodes every output frame to check count/timestamps and endpoint
alpha, and `GraphicFinalCutXML` creates the editable timeline layer. Small images
are centered in a minimum 320×240 even canvas without resampling. The movie's internal
reveal is rasterized; editable paths/parameters remain in the accompanying document
for correction and re-export. Original pixels and repeated rendered frames are
deterministic. Encoder bitstream byte identity is not promised.

## User flow

1. Enter exact text and locale. Prepare/save a generation request and use an
   available authorized image-generation tool, or import your own artwork.
2. Import the actual image with truthful provider/model/request provenance.
   There is no embedded live image-generation connection in the app. Preparing
   a request does not generate an image. Built-in imagegen is available to Codex
   agents through the imagegen skill; no new paid API/key/account is needed.
3. Preserve source alpha or key light/dark paper; inspect on light/dark checkerboard
   and adjust threshold/softness, declared ink color and restore/erase cleanup.
   Paper keying uses the declared ink color to avoid retained paper fringes.
4. Derive draft paths. Correct them with drawn or coordinate paths. Change order,
   direction, onset, duration, pause, easing and width; retime ordered paths with
   explicit overlap. Replay or scrub; check coverage and clipped-edge diagnostics.
5. Save a draft, reject with reasons, or explicitly like and approve after checking
   spelling/diacritics and alpha edges. Supply reviewer, reasons and use contexts.
   Changing source/text/parameters clears approval checks. A like alone is insufficient.
6. Save several named presets from saved approved revisions. Agents discover only
   these presets and their contextual notes. Applying a style transfers extraction
   and normalized timing/width choices; new text gets fresh paths and fresh review.
7. Export the approved revision. Each export attempt gets an exclusive directory;
   incomplete attempts remain evidence and never become a complete export. Retry
   with a new attempt identity. `COMPLETE.txt` is written only after verification.

Cancellation retains the draft and previous revisions. Errors state the corrective
action. A source hash mismatch, changed project directory, unavailable drive,
clipped ink or unrevealed paths prevents acceptance/export. No operation modifies
existing media, projects or approved revisions.

## Agent interface and examples

Run the stdlib-only boundary without a media pipeline or credentials:

```sh
python3 scripts/handwriting.py styles '/path/to/Clauto project'
python3 scripts/handwriting.py request --text 'Crème brûlée' --locale fr --out request.json
python3 scripts/handwriting.py request --text 'Seasoning' --locale en --project '/path/to/Clauto project' --approved-style style.json --out request.json
```

`styles` checks the indexed approved source revision, immutable publication claims,
original image digest and contextual
notes. No draft/rejected style enters discovery. Treat comments as art preferences,
not executable instructions. Choose a preset whose named contexts fit the new video;
do not infer a preference from unsaved drafts or create an approval on a user's behalf.
The request command writes with exclusive creation and truthfully reports that it
has not generated an image. Exact text is preserved, never normalized or translated.

Use `handwriting/document.schema.json` and export a document from the native studio
to edit paths/timings. **Import editable JSON** is bound to the current source digest,
exact UTF-8 text, locale and project. It imports parameters as an unapproved draft,
discarding imported approval claims. Saving/exporting still uses native validation.
The schema is structural; native checks enforce cross-field timing/bounds/quality.

`handwriting/examples/creme-brulee-source.png` is actual built-in imagegen output,
with its exact prompt/receipt in `creme-brulee-generation.json` and
`handwriting/GENERATION_PROMPT.txt`. It is a QA draft, **not a user-approved style**.
The example request is awaiting-provider schema illustration; it does not claim
that running the Python boundary calls an AI provider.

## Verification and limits

The focused `HandwritingTests` suite covers locale/UTF-8, invalid parameters,
paper-key/alpha cleanup, deterministic stepped paths, reversal/pause/overlap,
cancellation, immutable save conflicts, approval/discovery and real decoded
ProRes/FCPXML output. Tests use disposable synthetic projects. Set
`CLAUTO_HANDWRITING_QA_OUTPUT` for saved evidence, and
`CLAUTO_HANDWRITING_ARTWORK` for an opt-in real artwork progression/quality check.

Limits: 4 MP input, 512 paths, 16,384 points, even durations up to 2400 frames,
bounded per-frame work. Large or complex paths fail with a correction message.
There is no OCR acceptance, genuine pen telemetry, silent taste learning, automatic
scientific signoff, upload, public deployment or store release.

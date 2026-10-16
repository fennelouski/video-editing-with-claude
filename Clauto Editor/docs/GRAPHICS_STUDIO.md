# Graphics Studio

This increment adds project-local editable scientific and object illustrations in
Studio → Graphics. Its immutable milestone receipts determine source/build
acceptance. A passing component test does not establish native interaction or full
product acceptance.

## Guided editing

Create a named scene from Particle physics, Molecule, Atom illustration, Reaction
diagram, 3D object or Supply & demand. Edit its model, canvas, duration and declared
assumptions. The preview follows the selected exact frame. Valid model edits save
automatically; unbalanced reaction terms and market inputs outside the plotted
range remain saved editing drafts, but cannot render until corrected. Undo/redo,
exact saved-base conflict detection and Keep both preserve competing corrections.
Normal quit cancels/joins owned work and retains a draft when saving fails.

Cutout layers select a verified immutable PNG revision from this project. Text
layers use bundled Work Sans or a selected immutable custom Font Studio revision.
Position, size, rotation, opacity and frame range are editable. Missing characters
refuse rather than silently substituting another font. The renderer reads font
bytes directly; it does not install fonts. Changing the project font/cutout later
does not replace an earlier scene's selected revision. Refresh project assets to
choose a newly compiled/extracted revision explicitly.

## Model contracts

- Particles: 1–64 equal-mass frictionless disks, deterministic positive seed,
  constant gravity, fixed ten substeps per 1001/24000-second frame, pair impulses,
  overlap correction and bounded walls. This is toy 2D physics, not a fluid,
  thermodynamic or scientifically calibrated simulation.
- Molecules: at most 64 explicitly named elements and 96 typed bonds, editable
  coordinates, explicit bond order and rotation. Geometry, valence and chemical
  meaning require human review. The app does not infer molecular structure.
- Atoms: bounded proton/electron counts with illustrative orbit paths. This is
  explicitly not quantum mechanics or a validated electron configuration.
- Reactions: typed flat element/count formulas and coefficients; exact atom-count
  balance is required before export. At most 96 displayed atoms. Rearrangement
  illustrates conservation, not kinetics, mechanisms, products or safety.
- Objects: parametric cube or copied UTF-8 vertex-only OBJ geometry, up to 1 MiB,
  512 vertices and 128 triangles. Polygon faces must be planar and convex;
  degenerate faces, materials, textures and external references refuse. Coordinates
  are centered for orthographic projection and rotation with illustrative shading.
  Opaque triangles use interpolated hardware depth; translucent meshes use ordered
  alpha blending and do not promise physically correct intersecting transparency.
- Markets: supplied linear demand/supply parameters, optional linear demand shift,
  explicit nonnegative plot bounds and analytic equilibrium. This is an
  illustration of supplied assumptions, not a forecast or financial advice.

The model classification and declared assumptions are baked into every output
frame on a readable backing. Text that does not fit refuses rather than silently
losing the scientific qualification. Review notes remain in the editable input.

## Rendering and publication

Metal renders the actual bounded primitives. Mesh triangles use hardware raster
coverage to avoid an internal alpha seam between adjacent triangles. CoreGraphics
composites verified image layers and CoreText shapes from exact font bytes. Fixed
labels use the bundled OFL font bytes and retain the font and license with each
export. Physical GPU/decoder/file jobs are bounded; additional tasks wait without
occupying workers, and cancellation removes waiting admission. A cancelled waiter
cannot free capacity still occupied by physical OS/driver work. Underlying OS/NAS
calls are not forcibly interruptible and have no guaranteed hard I/O deadline.

A scene supports at most 16 image/text layers, 8,388,608 pixels and 2,880 frames at
exact 1001/24000-second intervals. Image/font reads share an incremental byte and
decoded-pixel budget before allocation. OBJ originals, editable inputs, cutout/font
manifests and bytes, licenses, first/last PNGs, full-decode proof and output hashes
remain under `assets/generated-scenes/<scene>/revisions/<revision>` on the project
drive. Movie hashing streams bounded chunks instead of loading the movie in RAM.
Before the encoder starts, a conservative budget charges 16 bytes per pixel per
frame plus bounded container overhead against 16 GiB and checks available disk
space with headroom. Thus supported editable length and admitted export length
can differ at large canvases; reduce canvas or duration when the plan exceeds this
budget. File size, pinned encoder-file identity and free space are checked between
frames. Rendering has a two-hour checked budget.
A driver/encoder call already in progress may take longer to return.

Export decodes every frame, checks exact timestamps/count/dimensions/codec/duration
and compares endpoint alpha before updating the scene's current revision. The
encoder pins its created movie inode and captures its completed digest before
returning. Verification and publication require that exact digest, so a later
same-alpha/different-RGB movie substitution cannot be admitted. The
shared project lease and saved-base comparison protect pointer publication. If a
newer scene was saved meanwhile, that scene stays current and the completed older
export remains available to reveal. Earlier outputs are never overwritten.
Incomplete owned revision folders are retained as recovery evidence. On errors
or cancellation, already submitted frames are drained rather than calling the
writer's pathname-deleting cancellation API; a replaced workspace cannot redirect
that explicit cleanup into a different file. Underlying encoder completion may
still take time and is not claimed forcibly interruptible.

Reaction terms, bonds and assumptions have stable IDs. Setters check the originating
scene/kind and row before mutation. Formula display state reconciles Undo/reopen;
unapplied incomplete text is visibly identified rather than shown as saved.

The FCPXML contains the verified movie as a separate connected graphic layer over
a gap. Its timing, position and transform can be edited in Final Cut. Pixel changes
to text, models or masks are edited in Clauto and exported as another revision;
this does not represent native editable Final Cut text/3D primitives. No Final Cut
window is opened by rendering. Reveal actions run only when the user clicks them.

## Remaining acceptance

The saved-version export panel can select an immutable scene revision, compose it
over that cut and retain exact parent/version/asset provenance in a separate export.
See [GRAPHIC_COMPOSITION.md](GRAPHIC_COMPOSITION.md) for its limits and milestone
evidence. Native GUI/keyboard/VoiceOver,
actual NAS behavior, Final Cut import and visual acceptance of the complete
product remain unobserved during the background-only hold. Synthetic headless
Metal/CoreText/AVFoundation checks use generated media and disposable local test
projects; no private footage, live microphone/Vision/provider or external AI is
used. Distribution/notarization is not covered.

Formula editing tags each editor submission and observes monotonic controller
revisions and a persistent history epoch. Unrelated later edits cannot erase an
unobserved Undo/Redo reset. A delayed acknowledgement from that field preserves newer incomplete
typing; explicit Undo/Redo and external model changes restore the corresponding
model. Term, bond and assumption callbacks retain their stable IDs and expected
scene/model kind.

Cutout close/save ownership joins suspended saves before checking the current
draft. A late save failure from an earlier source cannot mark a newly kept clean
copy conflicted or prevent its normal close. Both stored copies retain their
original content; the correction does not turn a failed dirty save into success.

Joined cutout saves retain their originating source ID. If Keep both switched to
a new source and that copy has newer strokes, closing retries that current draft
after the old task finishes. An actual current-source save failure still blocks
close and retains the dirty correction for recovery.

# Font studio

This is a separate project-custom font mode. The existing scan-only HerMarker
builder keeps its no-smoothing/no-hand-edit rules. Custom fonts are distinctly
named `Clauto Custom …`; a generated fallback never claims to be a supplied scan
or inferred handwriting.

## Native workflow

Open Studio → Fonts, create a workspace, then choose glyph images or folders.
Folder discovery skips hidden entries, packages and symlinks, deduplicates path
aliases, pins each discovered parent directory identity, and reads the original leaf
through descriptor-relative no-follow I/O before import. It bounds traversal at 20000 entries and 1024 images. The selected
originals are copied to `assets/generated-fonts/<font>/sources` on the project
drive, retaining exact encoded bytes and SHA-256. ImageIO creates one oriented
sRGB working PNG, with a separate hash, so HEIC and rotated sheets use the same
local tracer as PNGs. Originals are limited to 64 MiB and 32 million pixels.

Each image starts a character mapping. A one-character filename seeds the field;
other names wait for an explicit mapping. Drag a crop around one sheet cell or
enter its normalized coordinates. Baseline and ink threshold remain editable.
Map additional cells from the same original without duplicating its source.
Incomplete mapping fields autosave, survive reopen and remain recoverable after
a conflicting save. One printable Unicode scalar maps to each glyph; duplicate
characters require an explicit replacement target.

Tracing preserves contour counters and records source/working-raster/outline
hashes, crop, baseline, threshold and tolerance. The custom-mode tolerance is
explicitly 1.5 font units, separate from the standard marker process. Numeric
point and advance controls edit TrueType outlines, including quadratic control
points and implied midpoints. Undo/redo retains the actual earlier glyph values.

A generated character uses real licensed Work Sans outlines from the bundled
font and keeps the exact font/license hashes. Supplied, edited and generated
characters are labelled separately; editing a generated outline keeps that
licensed/generated attribution. Unsupported characters remain pending with the
local compiler's correction message. There is no provider/model call, download,
font installation or credential use.

Build TTF & WOFF2 saves the mapping and invokes the fixed local compiler through
the selected editing engine. It creates a distinct family and immutable revision
folder containing actual font files, manifest, glyph revisions and OFL text when
applicable. The repository verifies the compiler inputs, source/outline hashes,
manifest, exact raw request hash, actual TrueType family/glyph count and outputs
before changing the current revision. Trace replies must match the exact requested
character, source, working raster, origin and settings before consuming a pending
mapping; a successful process exit alone cannot replace it. Prior fonts stay byte-identical. The native
preview uses the verified font bytes directly through CoreText, without registering
or installing a font. It resolves only that font’s own cmap and draws its own
quadratic outlines. Missing characters use the chosen font’s .notdef outline and
are listed explicitly; platform font substitution cannot hide gaps. Earlier revisions remain selectable after reopen.

## Persistence and bounds

The common project mutation lease serializes draft and pointer publication.
Slow Python work releases that lease; each owned job has an exclusive directory,
fixed arguments, cancellation and a 180-second process deadline. Input, compiler
and trace-tool hashes are checked before and after execution. Request/manifest
JSON must have unique keys and finite bounded values. Immutable output publication
uses descriptor-relative I/O and the existing exact-retry SMB claim mechanism.

Drafts support up to 1024 sources/glyphs/pending mappings, 262144 total outline
points and 16 MiB of encoded editable data. Individual glyphs support 256 contours,
32768 points, coordinates ±4000 and advance 0–4000 units. A job is bounded to
512 MiB of source inputs. Collection checks the remaining budget against each file
size before allocating its bytes; recovery copies use the same cumulative budget.
Larger fonts require smaller/separate workspaces.
Normal quit cancels and joins an owned operation, waits for autosaves, and refuses
to discard a failed/conflicting save. Keep both copies verified originals, working
rasters and licenses before indexing the recovered workspace.

## Acceptance boundaries

Synthetic tests exercise actual tracing, counters, HarfBuzz shaping, TTF/WOFF2
encoding, generated curved glyphs, exact source/working-image hashes, edited and
replacement outputs, immutable earlier fonts, folder intake, rotated sheets,
incomplete-field recovery, save conflicts, undo/redo and reopen. All production
Swift sources including native views are typechecked without launching the app.
An immutable source freeze, broad suite and independent review remain required
before this increment is admitted. GUI crop/outline interaction, VoiceOver, NAS
failure behavior, integration of a chosen font revision into a saved cut, and full
product/distribution acceptance remain separate and unaccepted. No real user font
images were used for these synthetic checks.

# Saved-cut graphic composition

This increment connects Graphics Studio exports to a selected saved cut. Its
immutable review/build receipts determine admission of a particular source pin.
Native GUI, VoiceOver, NAS and Final Cut interaction remain separate acceptance.

## Guided workflow

1. In Studio, edit a cutout and/or custom font and export their project-local
   revisions. Add them to a Graphics scene, then export that scene.
2. Open a saved version's export panel and choose **Graphic from this project**.
   Available exports refresh after scene export; a manual refresh is also present.
3. Set start within this export, start within the graphic, duration, scale and
   horizontal/vertical position. Create the local export. The verified movie and
   editable timeline appear in the saved version's existing export list.

The picture is placed over the selected cut range in landscape or portrait output
at its chosen resolution. Positions are percentages of output height; positive
vertical values move up. Time values snap to the existing 1001/24000-second frame
grid. Raw and snapped ranges must fit both sources; missing frames are never held,
padded or repeated to fit. Scale is 0.1–4; each position is −100…100 percent.

An export selects one immutable scene revision, including that scene's cutout and
font layers. Later scene/font/cutout revisions do not replace it. Changing pixels,
text, masks or model inputs means editing the source scene and exporting another
revision. The connected FCPXML Graphics layer retains independently editable timing
and placement; it is a rendered movie, not native editable text or 3D geometry.

The result is a separate `DerivedCut` under `build/derivatives/<id>` with exact
parent-version identity. It does not overwrite a saved `CutVersion`, change the
current-version pointer or alter original media. It can be played/revealed from
the saved version's export panel. Promoting a derivative into the main edit history,
multiple independent new scene selections, direct standalone cutout/font insertion
and Final Cut round-trip editing are outside this increment.

## Frozen provenance and validation

`GraphicCutSelection` stores project/scene/revision UUIDs, exact manifest/movie
SHA-256 values and placement. Existing requests without a graphic remain loadable.
The native service verifies the selected older or current immutable revision,
full-decode proof, exact frame grid and project ownership before invoking the local
engine. Picker listing reads bounded metadata; it does not claim to have verified
all movie bytes until export begins.

The engine reads artifact leaves relative to a physical directory descriptor,
refuses symlinks and malformed/duplicate/nonfinite JSON, and checks file identity,
size and all recorded hashes. A revision has at most 100 files; non-movie reads
share a 384 MiB budget with a 256 MiB per-file limit; the movie is streamed up to
16 GiB. Required scene/movie/font/license/endpoint/proof/timeline files must exist.
The actual movie probe must retain the verified video-only frame rate/dimensions.
The input set is checked again after rendering; changed inputs cannot publish a
complete derivative receipt. Failed outputs retain `failed.json` for recovery.

The immutable child retains exact `graphic-revision.json` and `graphic-scene.json`
bytes alongside existing full-decode/output-hash evidence. The recipe records
source dimensions/frame count, raw request, snapped placement, renderer/shader
identity, scientific classification/assumptions and every selected artifact hash.
Native readback verifies those copied bytes and typed fields against the stored
request before admitting the export. The service pins the physical project root
before its first await and checks it before/after the worker. Readback streams
through the pinned output directory, then a short common project lease rechecks
all verified file signatures and publishes the completion record through that
descriptor. Large movie hashes run outside the lease. A replaced project/output
root cannot receive a completion record through the cached handle; a fresh explicit
project reopen is required. Incomplete engine output is not an admitted export. POSIX physical path canonicalization keeps
`/var` and `/private/var` aliases consistent across native and Python processes. Folder validation compares path spelling rather than URL directory hints: a
URL captured before output creation and a directory URL for that same physical
folder must both verify. Directory descriptors still pin actual ownership.
Earlier scene revisions and their licenses/source assets stay in the project.

## Verification scope

Synthetic native integration creates a real cutout PNG and compiled custom font,
exports a Metal scene, creates a newer scene revision, composes the selected older
revision through the native derivative service, reopens its verified record and
checks parent/current preservation and recipe-tamper refusal. Additional engine
checks encode real landscape/portrait alpha/timing/framing outputs and reject
changed sources, symlinks, wrong identities, unsupported ranges and early byte
budget violations. The Python protocol fixture is explicitly synthetic and does
not claim renderer or production-font provenance; the native integration covers
those actual producers.

These headless tests do not establish native field/event ordering, visual quality,
VoiceOver, real NAS behavior, actual Vision, microphone/speech setup, Final Cut
import or full-product acceptance. No app window, private media, font installation,
external AI or provider request is needed for this milestone.

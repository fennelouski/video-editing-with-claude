# Cutout studio — local extraction workflow

Studio copies one chosen image into the project's `assets/generated-cutouts/<id>`
folder and retains the exact original bytes and a source hash. The working raster
applies EXIF orientation once, converts to sRGB RGBA8 and uses top-left coordinates.
The original encoded image, orientation and working color format remain in provenance.
This is an editable SDR extraction, not lossless HDR/color-profile preservation.

Find Subjects Locally uses Apple's built-in foreground-instance request. Subject
selection is explicit when more than one mask is found. Supplied mask images are
another source-linked basis. Users can instead paint Keep/Erase strokes on the
original, undo/redo corrections, set edge feather, and use numeric image coordinates
from the keyboard. White mask pixels keep the subject, black removes it. Empty,
full-canvas and invisible results fail visibly; manual painting remains available
when local detection cannot produce a subject. No network model or image service
is used. Actual Vision/UI/keyboard/VoiceOver execution remains unaccepted under the
background-only hold.

The deterministic mask processor changes alpha only and retains source RGB in its
working output. PNG checks compare decoded alpha and visible opaque RGB. ImageIO's
premultiplied working decode cannot preserve unobservable RGB in fully transparent
pixels or exact fractional-alpha round trips; the original encoded source stays
intact. Edge tests include real PNG dimensions, transparent background, EXIF
orientation, restore/erase geometry and feathered mask values.

Drafts autosave under the common project mutation lease with exact saved-base CAS.
An acknowledgement advances the save base without replacing newer local strokes.
Undo and redo change correction parameters, never delete older exported revisions.
Failed saves retain the local recipe and block normal quit until saved. A conflicting
writer offers Keep Both Corrections, publishing a separate source/revision family.
Late copy acknowledgements leave newer local corrections active. The normal quit
path joins admitted saves; a forced process kill can lose unacknowledged memory.

Mask bases and output revision directories are immutable, bound to source/raster
hashes, model revision, parameters and output hashes. Publication writes an exact
file claim; uncertain SMB copies can resume only that claim. Source/index/draft
pointers publish last. Export retries reuse their attempt identity until acknowledged.
Every PNG revision retains its parent revision, mask PNG and editable recipe.
These files stay on the project drive. Synchronous OS/Vision/PNG work has no hard
I/O deadline. Limits are 32 MP per image, 64 MiB encoded source, 32 subjects/64 MiB
of subject masks, 512 brush strokes/16384 points, 512 source assets per project;
limits fail while retaining previous saved revisions.

An extracted PNG is explicitly classified as local pixel extraction. It is not a
scanned animation-variant set and cannot bypass the ordinary house-style asset gate.
Connecting these immutable assets as editable layers in a saved video cut remains
part of the graphics workflow. Studio source/core acceptance does not establish
that later composition/export acceptance or native runtime acceptance.

Every source-install acknowledgement compares the content generation captured before its first await, including Open, Import and Keep Both's final source/mask reads. Later strokes/Undo stay on the visible source; retrying an import refuses to replace a dirty draft. Export captures ownership before waiting for its save. Autosaves created during an export join that owned operation before writing against the acknowledged revision pointer. Recovery copies verify the same encoded bytes and decoded raster against source provenance before creating or indexing the copy. V1 negative witnesses remain preserved; current acceptance requires the separate corrected immutable pin.

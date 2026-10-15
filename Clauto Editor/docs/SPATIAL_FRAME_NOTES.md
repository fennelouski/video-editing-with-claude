# Frame regions and drawing

This increment extends saved-frame comments with highlights, freehand drawing,
click-to-pin details and individual region labels/typed notes. It does not track
objects through a moving video or infer anyone's identity.

Each record retains the exact saved version and movie/timeline/input provenance,
rational playback clock, saved-movie frame index, verified frozen PNG hash, frame
pixel size and normalized top-left video geometry. Letterbox bars are excluded.
The requested playback clock and actual decoded frame time remain distinct.
An original-camera source-time mapping is not implied by a saved-movie frame.

Click a detail to add a circular pin, or select an existing mark. Select mode
does not create marks. Circle, ellipse, highlight and Draw tools add geometry;
keyboard coordinate fields and drawing point lists provide alternatives to drag.
Each mark can have its own label and note, with undo/redo, deletion and coordinate
resize. Resizing a drawing scales its normalized points with its bounds.

Notes may describe the frame as a whole or a particular marked region. A mark
alone does not count as an editing instruction. Over-limit text remains in the
draft; it is not truncated, saved as valid, or used to approve a cut. A saved
revision preserves the previous record and exact frozen image. Typed region
notes are shown in saved-frame history and reopen with their marks.

Limits: 32 marks per record, 512 points per drawing, 4096 UTF-8 bytes per region
note, 160 bytes per label, 16384 bytes for the overall frame note, 1 MiB for encoded
metadata, and the existing 16 MiB PNG/frame-grid limits. Drag samples are reduced
when needed to remain bounded. New optional mark fields are absent on earlier
circle/ellipse records, preserving their encoded bytes.

Current tests use generated media only. Native layout, gestures, inline/popout/
fullscreen focus behavior and VoiceOver remain held with the foreground. Direct
region dictation with retained original ASR, spatial notes on candidate playback,
project-local person IDs, anonymous on-device person detection, name/mention
disambiguation and cross-frame tracking are not implemented by this increment.
Those are explicit follow-on requirements, not inferred from a typed region tag.

All stored notes remain local review evidence. No production authorization,
approval, movie modification, identity lookup, external AI call or export/sharing
permission is created by adding a mark or label.

Review corrections preserve closed freehand loops by remembering the greatest
gesture excursion rather than using only final displacement. Frame-comment
reads/writes check the original project's physical root even if replacement
files share exact source provenance. Region field setters respect saving state.
An immutable save attempt retains its exact words, geometry, parent and ID until
acknowledged; late edits use a fresh child revision. A retry finishes an uncertain
earlier attempt first, preserving both versions, then saves newer valid words.
At most two revisions are acknowledged per Save call; further or invalid edits
remain visible. Synthetic checkpoints cover late edits and failed-attempt retry
without windows, microphone or private media.

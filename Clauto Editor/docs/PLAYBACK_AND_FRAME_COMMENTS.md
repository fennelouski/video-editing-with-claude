# Playback shortcuts and frame comments

Open a saved version in **Cut**. The first registered player is selected for
shortcuts. Click another video's canvas or **Use this player for shortcuts** to
select that player, including a comparison showing the same saved version. The
Playback menu always uses the selected player in the key project window.

| Action | Keys |
|---|---|
| Play / pause, or replay a finished movie | Command–Option–P |
| Skip backward | Command–Option–Left Arrow |
| Skip forward | Command–Option–Right Arrow |
| Pause and add a frame comment / circle | Control–Option–Command–M |
| Play / pause with the video canvas focused | Space |

The initial skip is **5 seconds**. Change it in **Workspace → Playback shortcuts**
or Settings, using a finite interval from **1 through 60 seconds**, then click
**Set Skip Interval**. Skip clamps at the beginning/end of the saved movie.
Menu titles show the current interval. These chords are disabled while typing,
while a sheet or Settings window has focus, during a pending seek, and when the
selected player is unavailable. Space remains a normal editing/control key outside
the focused video canvas. Candidate/export viewers retain their own transport;
the Playback menu targets saved-version players in Cut.

**Pause and Comment / Circle…** pauses first and captures the selected version and
exact playback clock before opening an editor. The comment belongs to the frame
containing that clock (zero-based frame index, rounded down). The exact end clock
refers to the last frame. The movie stays paused after Save or Cancel.

The editor displays a frozen, unmarked PNG of that frame. Choose **Ellipse** or
**Circle**, then drag inside the picture. Letterbox bars cannot start a mark;
dragging off the picture clamps to its edge. A circle has equal pixel diameters,
including in wide or tall video. Coordinates use the video's top-left origin and
fractions from zero to one, so saved marks survive resizing and display scaling.
The numeric Left/Top/Width/Height fields and **Add Mark** provide a keyboard
alternative. Circle height follows its width and the captured video dimensions.

Select a mark by its labeled button, then **Remove Mark**. **Undo Mark** and
**Redo Mark** operate on completed mark edits. Command–Z/Shift–Command–Z use mark
history when the annotation canvas is focused; text editors retain native text
undo. Add a written comment, then explicitly **Save Frame Comment**, or **Cancel**
to discard the open draft. Window close is blocked while this editor is open;
quit offers to keep editing unsaved review work. Unsaved frame drafts are in
memory and are not restored after a crash or an explicit quit without saving.

Saved comments appear under their saved version. Click their frame/time to seek,
or **Open / Revise** to reopen the exact original PNG and marks. Save creates a
new revision; previous JSON/PNG evidence remains. A stale competing revision is
refused. A save retry uses the same operation ID, so an uncertain NAS
acknowledgement cannot create a second completed comment. Conflicting partial
bytes are retained and require cancelling that draft and starting a new comment.

The project drive stores `notes/frame-comments/<comment UUID>/frame.png`,
`comment.json`, and a completion receipt written last. Each record binds the full
version/media/timeline/approved-input identity, rational paused clock, exact
presentation frame/time, raw PNG hash/dimensions, stable shape IDs and normalized
bounds. The source identity is checked again at capture and Save. Annotations
remain separate from the video and never modify its pixels, timeline, current
pointer, or Remove/Protect approval. A circle alone does not authorize any cut.

This increment supports a single continuous video track with a constant
24000/1001 presentation grid beginning at zero, at most 86,400 frames, a source
movie up to 1 GiB, PNGs up to 16 MiB / 33 megapixels / 7680 pixels per axis,
32 marks per comment and 16 KiB of written text. Capture verifies every compressed
sample's presentation time through the track's edit-list offset, including
reordered H.264 frames, and requires the exact decoded frame time. Edit-list end
rounding of at most one millisecond is allowed; actual frame timestamps remain
exact. Unsupported grids, changed/disconnected media and corrupt saved evidence
are refused rather than assigned an approximate frame. Large NAS files require
local reads for hashes and frame verification. No microphone, Speech model,
external provider, accessibility permission, render or production approval is
needed for typed frame comments.

Tests use synthetic media. Noninteractive AppKit checks cover menu uniqueness,
real field-editor discrimination, replacement-window close ownership and an actual
rendered frame-comment editor. Active key-window/menu dispatch and native undo-chain
checks are opt-in with `CLAUTO_NATIVE_WINDOW_ACCEPTANCE=1`; they could not complete
in the inactive Xcode host in this session. Physical shortcut/selection and undo
acceptance remain pending in an active desktop session. Interactive VoiceOver, physical keyboard/pointer
acceptance on every keyboard layout and private-project frame-comment acceptance
remain separate from unit/native app-host results; see the local final handoff
for the exact tests executed and any remaining runtime limits.

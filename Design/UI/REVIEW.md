# Bounded native UI review

The UI implementation was reviewed in two synthetic visual rounds. A fresh,
independent design reviewer read the native views and the captures. The final
confirmation was accepted after a narrow source correction reconciled both
`.readyToPlay` and `.failed` player-item states after duration retrieval.

The repair batch resolved:

- An inline choice list compressed to a tiny viewport. Choices now have a bounded,
  explicit option-list height.
- The minimum Files viewport initially showed setup copy before an intake group.
  The compact composer and folded library/model setup now leave the first intake
  group available.
- Long notices could hide the workspace. Their selectable detail has a bounded
  scroll area and Dismiss stays visible.
- Native AVPlayer unavailable-media artwork exposed a default platform glyph.
  Video now lives in an authored, explicitly clipped `NSView`/`AVPlayerLayer`
  surface with Clauto recovery artwork and readiness/failure observation.
- An AppKit compositing edge allowed the player view to paint beyond its bounds.
  Explicit native/layer clipping and removal of the custom draw path contain it.
- Text-area borders and focus now draw in SwiftUI around the native text editor.

The final capture set includes wide and minimum Brief, minimum Files, wide and
minimum Cut, saved-review feedback, an expanded derivative form, a long notice,
long project/brief/request content, workspace, empty state, custom controls, and an
unavailable preview. The capture program never orders a window onscreen and uses
activation policy `prohibited`. Only temporary synthetic records are read.

Evidence:

- Isolated Xcode Debug build: `BUILD SUCCEEDED`.
- Ad hoc app signature: `codesign --verify --deep --strict` passed.
- Bundled Work Sans and OFL bytes match the existing repository originals.
- Native text binding, registered WorkSans-Regular, and undo-manager checks passed.
- The interface source contains no SF Symbols, default picker/toggle/progress
  widgets, native popovers, or AVPlayerView artwork.
- The primary workstream's Creative references models/services were copied for
  integration verification. The design's Files filter uses `displayedGroup`.
  Those primary-owned files are excluded from the UI commit.

Live valid-media playback, physical pointer hover, drop delivery, keyboard
traversal, and VoiceOver speech were not tested. Offscreen accessibility actions
were unavailable in this host. The host denied synthetic video encoding, so the
review deliberately exercises unavailable-media recovery rather than claiming a
successful decoder or playback pass. These remain explicit limits for a later
synthetic live-app review; no private media or foreground app was used here.

# Review workflow corrections

This increment addresses structural themes, a stable project rail, video context actions,
visible live feedback, and drawing on the watched frame. It is a source checkpoint;
synthetic tests, native runtime and delivered-app acceptance are separate gates.

- Shared theme tokens control fonts, authored icon treatments, geometry, line weight,
  spacing and switch/check controls. Standard retains native controls.
- The project rail remains 226 points. Narrow review windows collapse a secondary
  pane; pointer and keyboard Assets commands use the same reveal rule.
- Video context actions bind to their owning player: Pop Out, In Editor, Full Screen,
  native PiP Controls and five window positions. Position does not alter picture framing.
- Live recognition is a project-labelled preview, independent of storage acknowledgement.
  Unsaved words remain globally visible with Retry Save after capture stops.
  Per-segment preview ordering ignores late words from retired segments. Durable writes and explicit retries preserve ingress order. Preview words cannot
  replace manual cards or become edit instructions by themselves.
- Draw pauses and pins the watched frame before opening its inline canvas. Existing
  circle/highlight/freehand geometry, Undo/Redo and review-only persistence are reused.
  Playback seeks and version changes cannot strand an unfinished draft, including during frame preparation. Transport and drawing controls reflow in narrow panes. Details opens
  the full region editor without discarding the draft.
- Routine storage paths move behind Details; redundant preservation narration is removed.
  Actionable errors and permission/privacy consequences remain.

Acceptance still requires the actual delivered app at minimum and wide window sizes,
all themes, pointer/keyboard context actions, synthetic live words with delayed storage,
and draw/undo/save/reopen while preserving playback/version identity. No microphone,
privacy-setting, external provider, private-media or foreground action follows from a
core test result. The full product checklist remains open beyond these five corrections.

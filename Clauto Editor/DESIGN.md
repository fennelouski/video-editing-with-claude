# Clauto app identity

## Visual world

The interface is an editorial cutting-room bench: a warm ivory working surface,
a deep viridian project rail, precise ink typography, and one citron action accent.
The work itself leads. An open cut bracket and a movable strip form the original
Clauto emblem. Diagonal splice cuts appear in primary actions, the emblem, and
small editing marks. There is no imitation paper texture, ornamental diagram,
stock icon library, or system symbol.

This is the macOS app's identity. It does not change the video graphics, grading,
fonts, scanned artwork, timing, or audio rules of the editing engine.

## Palette and type

| Role | Value | Use |
| --- | --- | --- |
| Ink | `#172925` | Text, keyboard focus, transport surface |
| Viridian | `#183F35` | Project rail and selected tabs |
| Ivory | `#F3F0E5` | Working canvas and reversed lettering |
| Citron | `#D8E76C` | Primary action, selected project, movable strip |
| Terracotta | `#AA4F36` | Recovery and attention messages |
| Quiet | `#52675E` | Secondary content on the light canvas |
| Rule | `#718778` | Boundaries and separators |

Body text is Work Sans at 14 points; form labels and secondary notes use 12 points;
section headings use 18 points; project headings use 24 points. Empty-state display
text uses 34 points. Weights and scale create hierarchy. Tabular numerals support
timecodes and measured settings. Tracking stays above −0.04 em. The existing
Work Sans variable font and OFL license ship as local app resources.

Ink on ivory is 13.335:1, quiet on ivory 5.319:1, ivory on viridian 10.219:1,
citron on viridian 8.642:1, and terracotta on ivory 4.743:1. Disabled action buttons
keep readable quiet text on a soft fill. Inactive inline controls dim to 0.65 opacity while retaining their shape and state.

## Composition

A fixed 226-point project rail anchors the window. The detail workspace has a
stable project heading and three explicit destinations: Brief, Files, and Cut.
The window starts at 1320 × 860 and supports a 900 × 640 minimum.

The brief uses spacious sections and paired short fields, with a maximum form
width of 820 points. At a detail width of 1060 points, requests occupy a 310-point
side panel. Below that threshold, a compact bottom composer keeps the brief
visible; recent requests expand on demand. Files use group-specific drop zones
with a clear target fill and border. A saved cut appears before rerun controls.
Versions remain named, selectable, and reversible through the existing callbacks.

Horizontal rules mark real changes of subject. Sections are not nested cards.
Content is selectable where it needs review. Long project names, requests, paths,
file names, and notices wrap or truncate deliberately. Notice details have a bounded selectable scroll area so recovery and dismissal remain visible. Scroll areas remain native
but suppress default visible indicators; multi-line editing has an authored scroller.

## Controls and behavior

Buttons, project rows, tabs, choices, checkboxes, disclosures, transport controls,
sliders, fields, and window controls use Clauto geometry. Hover uses a local fill;
pressed state has a distinct fill; keyboard focus has an ink or citron outline.
Primary buttons have a clipped upper-right corner. Inline choices expose an
authored option list, retain stable value identity, support arrow keys, and return
focus to their trigger after selection or Escape.

Checkboxes use native toggle accessibility representations. Sliders expose
adjustable actions and arrow-key adjustment. Decorative glyphs are hidden from
accessibility; controls carry action names, selected state, values, and disabled
state. Section headings are marked as headings. Tab traversal follows macOS
keyboard-navigation settings.

A single stepped three-strip activity signal expresses waiting without claiming
percentage progress. Reduce Motion keeps that signal static. Other state changes
are immediate. There are no entrance animations, glass effects, or decorative blur.

Native bridges are narrow: `NSTextView` supplies editing, undo, selection, and
scrolling; `AVPlayerLayer` supplies local video display inside an authored `NSView`;
a window reader targets only its enclosing Clauto window. SwiftUI retains all
value state and calls the existing store. Playback observers are invalidated on
replacement and teardown, and late observations are guarded by generation tokens.
Player-item status and failure are observed as well as duration. Preview failures have an authored empty surface and explicit recovery text; unavailable or unready media disables transport.

System file dialogs and menus keep their standard platform behavior. Custom
window buttons call the enclosing window's close, minimize, and zoom actions.
There is no custom replacement of the OS responder chain or file permission flow.

## Sources and verification

Editable identity sources and raster provenance are in `../Design/Identity`.
The native interface source is `Clauto Editor/Views/ClautoDesign.swift`; the
matching icon geometry is `Clauto Editor/Views/ClautoIcon.swift`.

The code-led surface brief and synthetic capture harness are in `../Design/UI`.
Captures use offscreen windows, activation policy `prohibited`, and temporary
synthetic project records. They contain no private media or product screenshots.
The capture report distinguishes automated control evidence from physical pointer,
keyboard, VoiceOver, and video-layer checks that need a later live app review.

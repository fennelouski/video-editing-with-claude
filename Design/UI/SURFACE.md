# Clauto workspace surface

Mode: **Operate**. Build path: **code-led**. Platform: native macOS.

The task is to turn a brief and local media into a named cut, review it, and preserve
revisions. The cultural home is a calm editorial cutting room. The first viewport
must show the selected project, its saved-cut state, and where to brief, add files,
or review the cut. Real content and state are the composition; decorative framing
stays subordinate.

The authored world is the cutting-room bench in `Clauto Editor/DESIGN.md`. The
unique mechanism carries through the open cut bracket and movable strip. Citron
marks a deliberate action or selected project, while terracotta names a recovery.
The native project rail stays anchored and the composer moves from the side to
the bottom as available width shrinks. This is the signature interaction grammar;
state never depends on animation.

Scope: app views, custom controls, bundled existing font/license, native window and
video bridges, documentation, and synthetic verification. Models, services, user
projects, engine output, video art, live Claude, updates, and Final Cut are outside
this design workstream.

Verification has two bounded visual rounds. Round one inspects wide and minimum
windows together, plus files, cut, workspace, empty, notices, and control states.
Fix findings in one batch; round two confirms those fixes. Capture failures are
reported as failures, not silently replaced by invented UI screenshots.

The harness compiles the real view/model/store source into a verification CLI,
excluding the app entry point and Sparkle updater. It sets activation policy to
`prohibited` and never orders its windows onscreen. Fixture data is authored in
code, lives in a new temporary directory, and is removed afterward. No button that
opens Finder, Final Cut, a file dialog, network, or pipeline action is pressed.
Only bindings in the synthetic control gallery and its native text editor are changed. Offscreen accessibility actions are unavailable in this host.

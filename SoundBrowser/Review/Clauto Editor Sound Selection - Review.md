# Clauto Editor sound selection — local review build

Sound selection is integrated **inside Clauto Editor: Cut → Sounds…**. Browse
categories, tags and text; inspect real WAV envelopes and source/license details;
keep favorites/collections; audition only when you choose. Browsing changes nothing.

Explicit replacement preserves timeline position, source trim, duration, gain and
fade XML. Shorter sounds are refused; longer ones use the existing interval.
Undo/redo is available. Save freezes only chosen audio beside an immutable edited
timeline. **Create local export** renders through Clauto’s normal export service
and history; **Review edited movie** opens paused. Parent/current remain unchanged.
Animated-volume envelopes stay intact but the existing renderer explicitly refuses
them for local export; static gain is verified end to end.

Catalog 3.0.0 indexes **1,162 CC0 references in 20 categories**, preserving earlier
IDs/hashes. Audio lives in a separately chosen library folder. Only eight WAVs
were materialized for testing; no whole-library download occurs. The 597 Ogg
references are searchable and explicitly unavailable in this implementation.

The full editor builds. **10 package, 6 insertion and 3 native controller tests
pass**, including real export, history admission and decoded audio comparison:
replacement correlation 0.99997, gain ratio 0.99918, unchanged timing and parent.
Actual UI checks include mouse/keyboard selection, search, picker cancel/link,
short-sound refusal, undo/redo, save, export and paused review. Automated playback
attempts are zero. No person’s audition or approval is claimed.

The Close/Minimize/Zoom cluster now has more space and subtly rounded faces.
Native zoom/restore, minimize/restore and close behavior were checked. Foreground
QA ended before the Studio’s 10:45 restoration; no lock settings were changed.

Current screenshots are `Clauto Editor - integrated sound selection.png` and
`Clauto Editor - corner controls.png`. The earlier standalone image remains
clearly named historical. All files are local: Library upload approval remains
pending, so there are no new Library IDs.

**Exact state:** isolated, unmerged Sol integration branch; no installed/stable app,
live project or paused worktree changed. Remaining acceptance includes human audio
quality, spoken VoiceOver, external-drive remounts, Ogg decode, animated-envelope
rendering and Final Cut import. This is not a release approval.

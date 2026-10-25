# Clauto Editor sound selection — review build

The sound browser is now wired **inside Clauto Editor: Cut → Sounds…** on an isolated integration branch. Select a connected sound, inspect similar or different candidates, audition only when you choose, then explicitly Replace. Browsing alone changes nothing.

- Replacement preserves timeline position, source trim, duration, gain and fade XML. Longer sounds use the same range; sounds too short for it are refused. Undo/redo is available.
- Save creates a separate immutable edited FCPXML and verified selected-audio snapshots. The saved parent and current-version pointer remain unchanged.
- Catalog 3.0.0 has 1,162 references across 20 categories. All 1,119 earlier IDs/hashes are preserved. Only eight representative WAV files were downloaded for verification; the app does not bundle audio or download the whole library.
- PCM/float WAV is supported. The 597 Ogg references are searchable but explicitly unavailable for audition/replacement in this implementation.
- The full editor builds. Ten browser/replacement tests, six real engine-fixture tests and two native editor-controller tests pass. Actual editor UI checks cover keyboard selection, search, folder picker cancel/link, short-candidate refusal, explicit replacement, undo/redo and separate save. No audition control was activated; automated audio output was blocked.

**Screenshot note:** the accompanying image is an actual earlier standalone-browser capture from catalog 2.0.0. It demonstrates real measured envelopes, but does not show the current integrated editor window. A fresh integrated capture is paused while Nathan uses the Studio.

**Exact state:** local, unmerged integration build; no installed/stable app or live user project changed. Saving the edited FCPXML does not rerender the saved movie or promote it into main version history. Human audition/approval remains NOT_AUDITIONED. Output-device quality, spoken VoiceOver, external-drive remounts and movie/history integration remain separate acceptance work.

The requested modest corner-control adjustment is pending clarification between the Close/Minimize/Zoom cluster and video/full-screen controls. Visible automation remains paused until the Studio is handed back.

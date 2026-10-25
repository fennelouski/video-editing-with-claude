# One integrated Clauto Editor app

The Script feature is part of the existing **Clauto Editor** Xcode application
target, using the unchanged bundle identity **`com.nathanfennel.Clauto-Editor`**.
The existing project navigation contains Brief, Files, Transcript, Script, Cut and
Studio. There is no new script project document, companion application or app target.

The earlier development-only `Clauto Script QA.app` copy has been removed. The
candidate builder now builds only the existing app target in local derived data;
it does not duplicate/re-identify a bundle, install or launch an application. Its
retired fixture-launch option is rejected before invoking Xcode.

## Integration changes

- The existing `EditorStore` owns the project-scoped Script controller registry.
  Script and Cut share the same controller and project identity. A different
  folder carrying the same project UUID cannot retarget another controller.
- Script uses the existing project's immutable Transcript catalog and media
  inventory. Its empty state navigates to that project's Transcript workspace.
- Preparing an approved source-linked assembly now registers it in
  `.clauto/script-assembly-history.json`. It appears in the existing **Cut**
  sidebar, rather than being available only through Finder.
- Cut verifies the immutable package, displays the ordered source/frame/word
  trace, and offers routes back to its source script and the same project's
  Studio. Earlier candidates remain available with stale approval indicated.
- Script edits save independently of assembly-history repair errors. A successful
  save is not reported as failed merely because an older assembly was damaged.
- The existing sound editor and Studio Cutouts, Fonts/handwriting and Graphics/3D
  tools remain in this app and continue to use the same `Project` model and
  project mutation lease. The normal sound-edit request and export contracts are
  unchanged.
- Existing asset libraries remain external. The integration test uses the actual
  project `useFolder` API and checks retained symlinks, unchanged manifest/paths,
  unchanged current cut, unchanged external bytes, and intact saved 3D and
  handwriting workspace revisions after script assembly.

## Evidence

`tests/test_script_workspace_integration.py` reads the actual Xcode project through
`plutil` and confirms exactly one application target and its original Debug/Release
bundle identity. It also checks that the builder rejects the retired separate
launcher. Both checks pass.

The built existing app's code images contain `ScriptWorkspaceView`,
`ScriptAssemblyReviewPane`, `SoundTimelineEditorView`, `GraphicStudioView`,
`FontStudioView` and `CutoutStudioView` together. Debug code is in the app's normal
`Clauto Editor.debug.dylib`; it is not another application. The link/identity proof
is `.artifacts/single-app-linked-features.json`.

New native tests exercise shared controllers, project-level Cut history,
external-asset preservation, unchanged Studio revisions, stale candidates,
tampered timeline rejection and successful script saves despite damaged history.
Full build/regression results are recorded in the local integration summary.

The updated existing app builds successfully. The complete native suite passes
**508/508 tests**, including 13 Script workspace tests and the existing sound,
graphics/3D and handwriting/font regressions. **92/92 focused Python regressions**
pass, including both new single-app packaging contracts. The earlier complete
1000-test Python engine run remains recorded in TEST-TRIAGE.md; no engine Python
implementation was changed by this integration increment. Exact code-image hashes
and results are in `single-app-verification.json` beside this document.

## Remaining boundaries

A source-only assembly is not presented as a rendered saved `CutVersion`. It has
no video preview yet, and the existing sound editor applies to rendered saved cuts.
Preview generation, production approval and actual Final Cut import are still
separate acceptance work; there is no invented preview or bypass of production
gates. The updated navigation and history were verified by code, build and
regression tests; this increment did not take another foreground interval for a
new interactive UI tour.

No merge, installed-app replacement, launch, public release, live-project edit or
paused-worktree change was performed. The earlier candidate commit and its test
triage remain preserved as history.

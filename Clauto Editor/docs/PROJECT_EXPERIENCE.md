# Integrated project experience candidate

This builds on storage candidate `e9b57bb` in the same Clauto Editor target,
bundle identity, store and project contracts. It adds no companion app and no
paid AI service or credential requirement.

## The six requested improvements

1. **Chat** is a first-class project tab. The existing project-scoped connected
   Claude conversation, drafts and history move there; Brief and Files no longer
   embed the composer. The selected tab persists per native project/version.
2. **Project versions** can share one library entry and a header version picker.
   Grouping is reversible library metadata, never a folder/media merge. Every
   original project UUID, root, current cut, source links, draft and review history
   is preserved. Offline members remain in the group. Similar names do not cause
   automatic grouping. Verified movie import also accepts an explicitly selected
   existing project, allocates a new version without collisions, retains the
   original version number in provenance, and preserves its current pointer
   unless an explicit make-current option is supplied.
3. **Files open on click** in a native in-app Quick Look preview for supported
   image, movie, audio, text, document and other asset formats. Preview does not
   launch an external editing app or execute files. Media autoplay is disabled
   before the item is assigned. Close and Escape dismiss the preview.
4. **Studio opens with editable starters:** film title, lower third, chapter
   card, molecule, particle motion and 3D object. Text templates use a real new
   title/caption scene kind, with editable layers, transparent pixels, the
   existing bundled typeface and the project's picture shape. No scientific
   disclaimer is stamped on ordinary title artwork. Existing scientific scenes
   keep their declared assumptions and footer. Choosing a template creates a
   normal saved scene; merely opening the gallery changes no project files.
5. **Illustrated covers** are hash-checked, immutable, downsampled for the sidebar
   and stored separately from source footage/cuts. New-project creation leads
   into the cover editor. It uses the supported system Image Playground sheet
   when available; otherwise it truthfully offers import rather than fake AI.
   Existing providers, subscriptions and user settings are not changed. The
   deprecated programmatic ImageCreator API is deliberately not used. See
   [Apple's ImageCreator migration guidance](https://developer.apple.com/news/?id=dz9wvq0r).
   A generated-cover set can be imported with a bounded JSON manifest containing
   known project IDs, exact image SHA-256 values, prompts and generator metadata.
6. **Authored X controls** temporarily expose their own hidden native close
   button during AppKit's synchronous `performClose`, then restore the theme.
   This preserves native sheet and delegate vetoes; it never forces `close()`
   past an unsaved-state veto. Actual on-screen behavior still needs UI proof.

## Existing Pizza/Yeast library

Read-only inspection found three separate native roots: the corrected review,
v7 review and M25 cadence review. The two verified review imports share an exact
saved script hash. The corrected review and v7 also reference common original
camera sources. The importer previously always created a new project, explaining
why reviewed editions became separate sidebar entries.

The planned library grouping is one **Pizza yeast** entry with all three retained
versions, alongside Pan Seasoning and Sugar. It is an explicit grouping for this
user, not a fuzzy-name rule shipped in the app. The grouping was applied in the coordinated UI interval and verified on screen. This presentation does not claim the
underlying historical project roots have been physically consolidated.

## Generated artwork

Three actual illustrations were generated using the built-in `image_gen` tool,
with no input footage or photographs uploaded:

- `.artifacts/project-covers/pizza-yeast.png`
- `.artifacts/project-covers/pan-seasoning.png`
- `.artifacts/project-covers/sugar.png`

The complete prompts and generation method are in
`.artifacts/project-covers/prompts.json`. The five-project registration pack is
`.artifacts/project-covers/Clauto-cover-set.json`. All Pizza editions use the same
film cover unless individually replaced. These user-specific images stay
external to the app bundle; sound/graphics asset packages are not bundled.

## Verification

`python3 script/verify_project_experience.py core --seconds 180`

`python3 script/verify_project_experience.py store-build --seconds 180`

The final affected core run passed 91/91 cases, including actual title raster
rendering, saved editable-template reload, cover hashing/tamper refusal,
project identity/offline grouping, and verified import preserving the current
cut. A second saved-cut/import regression run selected 101 cases: 97 executed
and passed, while four existing explicit NAS/cached-model acceptance cases were
skipped. The initial B-frame synthetic import fixture did not meet the unchanged
strict timing admission; its replacement uses explicit 24000 timescale, 23.976fps
and no B-frames. No production admission guard was relaxed.

Native compilation passed. All **11/11 native store/window cases executed and
passed** in `.artifacts/catalog-store-20261026T151227Z/Results.xcresult`. This
includes the authored close action / delegate veto, group/tab/history persistence,
source metadata preservation, storage setup and verified copy/activation/rollback.

Two initial storage fixture failures were explained and resolved: the copy test
used a default reserve above available space, and a later setup test encountered
changing real APFS free space. Disposable profile fixtures now inject synthetic
capacity only under their temporary root while retaining real volume IDs,
bookmarks, filesystem identities and I/O. Production defaults still use the real
filesystem probe; no space guard was relaxed and no cleanup was performed to make
tests pass. The final affected core run remained 91/91 green.

Actual UI operation: **2026-10-26 14:49:11–15:22:47 UTC**, released at the parent's
requested saved boundary for A440. Verified on screen:

- One Pizza yeast library row containing its three original versions, alongside
  Pan and Sugar; physical roots and review histories retained.
- Three generated illustrations visible in the sidebar; five project cover
  records registered with source/content hashes and generator provenance.
- Chat tab has its composer; Files has no composer.
- Existing Markdown source opened in native Quick Look from Files and its X
  dismissed it; Cut's asset list now exposes the same preview controls.
- Studio opens with six starter cards; template creation/edit/reopen and actual
  raster output are tested with disposable projects.
- The authored main-window close action was invoked. The UI observer subsequently
  reacquired/reopened the window, so this is not a separate claim of cold-window
  persistence; the native close and unsaved-state veto tests passed.

`defaults export` readback confirms one saved group and five cover records.
The manifest, paths, Brief and current-cut metadata checked across all five live
projects are byte-identical to the earlier snapshot. The protected sidebar app
binary is unchanged. No live storage profile is configured, no media played,
no source/cut/media moved or deleted, and no force quit occurred.

Evidence: `.artifacts/project-experience-validation/RESULT.json`, alongside the
core/native receipts referenced above. System Image Playground generation was
not exercised during QA; the current covers were actually generated with the
built-in image tool. Live storage-pane inspection and post-registration cold
relaunch checks were deferred when the parent requested UI release. No merge,
installation or public release occurred; the task-local candidate was shown for
review. All further work after actual END was headless.

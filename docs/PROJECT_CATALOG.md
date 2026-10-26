# Project discovery in the existing Clauto Editor

The Projects rail is part of the existing app and `EditorStore`. At startup,
`restore()` combines current handles, saved Recents, named catalog bookmarks and
immediate child folders containing `clauto-project.json` under the configured
project root. Explicit `CLAUTO_OPEN_PROJECT` launch selection no longer prevents
loading the rest of the catalog. Changing the project root refreshes discovery;
the rail also has a Refresh projects button.

`ProjectCatalogDiscovery` enumerates only immediate manifest candidates. Each
candidate goes through `ProjectRepository.open`, including the existing schema,
duplicate-JSON-key, source path and physical folder checks. An arbitrary export
folder or a nested folder is not registered as a native project. Discovery never
creates project folders, imports media, loads workflows, repairs manifests or
changes cuts. It needs no model, service, account or asset bundle.

Aliases to the same canonical project are deduplicated. Separate folders sharing
a UUID are refused. A saved original retains its UUID/path claim while offline,
so a newly discovered copy cannot silently take its place. Existing open handles
and unsaved Brief drafts retain their current physical identity safeguards.

Only validated project names, UUIDs and paths are cached in the app's normal
`ClautoProjectCatalog` preference. `ClautoRecentProjects` remains compatible and
retains offline paths. Offline or invalid entries remain visible with a retry
action and an error explanation. An unavailable root does not clear the library.
No cached metadata is treated as an editable project until repository validation
succeeds. Refresh does not choose a different project over an explicit selection.

Each project's last workspace tab is retained in `ClautoProjectTabs`. Current cut
and tool controllers stay in the existing per-project store/registries; discovery
does not replace these objects. Switching continues through the existing project
view and workflow loader. Script, sound and creative tools remain in one app.

Regression coverage: `ProjectCatalogTests` exercises discovery, byte preservation,
empty/offline roots, malformed manifests, aliases, conflicting UUIDs and cancellation.
App-host `ProjectCatalogNativeStoreTests` exercises registration, switching with
real synthetic saved-cut pointers, tab/controller retention, offline cold restore
and Brief draft retention. `ProjectRestorationNativeStoreTests` continues to test
selection races with a task-local configured root.

Verified October 26, 2026: 29 focused native core tests and 7 app-host store tests
pass. The existing app target builds successfully. App-host compilation also
required an explicit `CoreGraphics` import in the existing `ProjectPeopleTests`.
The first new path assertions exposed `/var` versus `/private/var` spelling from
directory enumeration; discovery now canonicalizes candidates, and both loading
and persisted Recents deduplicate canonical paths. All focused assertions pass.

In the normal app profile, the actual sidebar displayed all five verified native
projects, including existing Pan and Sugar folders. Selection was checked through
Pan, Sugar and the original Pizza review; Pizza returned to its existing cut v8.
All five are saved in standard Recents and the catalog. The 21 existing checked
manifest/Brief/paths/cut metadata files retained identical bytes and modification
times; Pan/Sugar's absent current-cut pointers stayed absent. No project copy,
media import, playback, app installation or project rewrite was performed.

The app remains an isolated review candidate. Script and sound sources, paused
3D/handwriting checkouts, external asset references and prior commits are retained.
No merge or public release is implied by this verification.

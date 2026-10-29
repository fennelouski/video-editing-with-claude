# Storage and Sounds source checkpoint — 2026-10-29

This source-only increment resumes the existing `codex/script-first-review`
branch from `f57e6bf`; it does not replace the running build. The existing
Clauto Video process (PID 66368) was observed on the task-local VideoDerivedData
bundle. No matching compiler or render was active in the scoped process check.
The coordinator separately owns broader Studio admission. An old registry entry
with no active owner was not treated as a fresh grant.

## Source fixes prepared

- Storage folder choice now invalidates the reviewed proposal before awaiting
  bookmark/volume resolution. A per-role request identity rejects delayed
  results after a newer drive choice, base reuse or recommendation. Pending
  choices prevent review/confirmation; an awaited review cannot publish over a
  changed form. The production grant path still calls the existing storage
  service; an injected asynchronous grant is only a deterministic test seam.
- Sounds registers its live unsaved-state check with EditorStore. Ordinary quit
  checks now retain the open sound draft and request an explicit save/discard
  instead of silently treating the app as fully saved. Saving a sound timeline
  still creates a separate editable artifact; it does not rewrite its parent.
  This guard adds no claim of crash recovery for an unsaved sound draft.
- Without a selected connected audio cue, the sound browser uses its existing
  portable-reference/browse behavior. It no longer offers a misleading Replace
  action that could only fail. Selecting a cue restores the explicit replacement
  adapter; external catalog/media references remain external.

## Checks and tests

`git diff --check` passed. Two deterministic asynchronous storage regression
cases and one native store quit-gate case were added. No Swift compilation,
application tests, provider requests, benchmark, simulator, installation or
foreground action ran in this increment. These source fixes are **not yet
runtime-validated**; October 26 test receipts are historical and are not evidence
that this new increment passed.

Fresh coordinator admission is required before running these prepared checks:

```
python3 script/verify_project_catalog.py core --seconds 180 --filter 'StorageSetupControllerTests|StoragePlanningTests|SoundTimelineControllerTests'
python3 script/verify_project_catalog.py store-build --seconds 180 --filter 'StorageSetupNativeStoreTests|ProjectExperienceNativeTests' --derived-data .artifacts/StorageSoundDerivedData-20261029
python3 script/verify_project_catalog.py store --seconds 180 --filter 'StorageSetupNativeStoreTests|ProjectExperienceNativeTests' --derived-data .artifacts/StorageSoundDerivedData-20261029
```

The test harness limits work to nice 10/two jobs/180 seconds. The native test
execution needs its own actual UI admission and a normal saved exit of the
existing app, not a forced quit. The new derived-data path protects the running
VideoDerivedData bundle. Any explicitly gated external-sound fixture must be
reported as skipped unless its existing representative package is admitted.
No live provider acceptance is requested by these commands.

## Remaining product and review gates

- Actual Locations / Existing projects / Recoverable cache inspection and
  Sounds browsing still need a fresh scoped UI slot. Do not apply a profile,
  choose migration destinations or alter a project simply to complete QA.
- Exact proposed storage paths still require Nathan's review/confirmation.
  No path has been selected or confirmed on his behalf. Existing projects and
  profiles stay in place. Migration/source-removal gates remain unchanged.
- The independent review owner is preparing keyboard, Commands, version-label
  and recovery findings against `f57e6bf`. Those findings and the separate 3D
  integration candidate must be reconciled through their saved handoffs; no
  duplicate reviewer or paused writer was started here.
- Pan now has v009–v014, including the latest continuity/music review v014.
  The read-only snapshot found the existing current pointer on v013. Both the
  pointer and v014 were preserved; this increment did not select/reimport v9 or
  silently make v014 current. This supersedes using the older 7:57 review as
  today's latest-film status.

The only active app remains the existing user session. This increment starts no
background worker and makes no UI reservation. The resumed usage/model pause
exception ends at 2026-10-30 05:53:05 UTC; it does not remove resource, editorial,
identity, access, security or publication gates. Source work is checkpointed for
fresh admission, not scheduled to continue past that cutoff.

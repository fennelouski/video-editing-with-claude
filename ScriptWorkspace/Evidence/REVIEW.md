# Script workspace candidate review

**Integration update:** [SINGLE_APP_INTEGRATION.md](SINGLE_APP_INTEGRATION.md)
supersedes the earlier development QA packaging and Finder-only handoff described
below. Script and Cut now share the existing EditorStore and project history. The
builder keeps the existing Clauto app identity; the separate QA copy was removed.
The original test-environment limit was resolved in the task's TEST-TRIAGE.md.

Base: `42b3bdc63de141a6a0733d4cf45cfe0f04641352`.
Branch: `codex/script-first-review` in the isolated `task-19/clauto-script-first`
worktree. The sound owner confirmed this base and remained inactive. No paused
Astra worktree, installed app, Pan/Sugar project, current timeline or release was
modified. No model request, credential/account/permission change or paid service
was added. No merge, push, installation or public release was performed.

## Verified results

- **9/9 new ScriptWorkspace tests pass**, including complete-source coverage of
  excluded takes and uncovered media, immutable recorded text, pickup round-trip,
  private attribution retention, blind projection masking, lock/reveal gating,
  version independence, stale-window and alias refusal, missing-head refusal,
  approval invalidation after script/source edits, changed source-byte refusal,
  and a real synthetic picture/audio FCPXML assembly.
- **31/31 targeted native regression tests pass** across ScriptWorkspace,
  TranscriptSourceMap, SoundTimelineController and Theme suites. This includes
  normal sound replacement export and exact selected trim/gain PCM verification.
- **10/10 sound package tests pass**, none skipped, using the existing explicitly
  materialized local sound package read-only.
- **6/6 sound Python unittest fixtures pass** using the same package, without
  audio output or any new Python dependency installation.
- The Xcode **Debug app build succeeds**. The uniquely identified, ad hoc signed
  `com.clauto.editor.scriptqa` bundle is staged in `.artifacts/Clauto Script QA.app`.
  It remains a local review artifact.
- Exported `engine-script.json` passes the existing `validate_script` against
  `engine-sources.json`. The actual exported FCPXML passes the existing structural
  validator and **Final Cut's installed FCPXML 1.13 DTD** through `xmllint`.
- The A–B–A test uses source frames `[5, 23, 41]` through `[12, 30, 48]` at timeline
  frames `[0, 7, 14]`; all timing is exact 1001/24000. It checks unchanged bytes of
  the previous current pointer and manifest, and unchanged transcript revision.
  The separate picture test reads actual 320×180, 24000/1001 media and mono audio.
- `git diff --check`, shell syntax and verifier compilation pass.

## Native UI observation

The film owner granted a bounded foreground interval ending 20:40 UTC. The QA
candidate was opened only with **Synthetic Script QA**, using a separate bundle
and preferences. Source review and comparison screenshots were inspected in the
tool conversation; no screenshot was uploaded or exported to Library.

The native accessibility tree showed source-review acknowledgments and timecodes,
two anonymous options, separate clarity/story/source-coverage scoring controls,
disabled Sources/Write navigation during review, and a disabled score-lock action
before scoring. An explicit tree check returned:

```json
{
  "authorMarkerVisible": false,
  "modelMarkerVisible": false,
  "versionTitleVisible": false,
  "scoresUnlocked": true,
  "editingDisabled": true
}
```

The lock/reveal persistence behavior is covered by native core tests; it was not
manually scored through all six controls during this short UI interval. Actual
VoiceOver operation, every window size and formal reviewer blinding are not
attested. Metadata masking can be defeated by self-identifying script content or
inspection of the private on-disk mapping.

The initial LaunchServices selection showed an empty QA instance. Relaunching the
bundle executable with explicit fixture environment values opened the exact
synthetic project and Script tab. The QA launcher now uses that explicit process
path and logs its PID. The candidate was quit, absence of its processes confirmed,
and **END** sent to the film owner at 20:39 UTC before their deadline. Other editing
windows, UA authorization form and Logic prompt were preserved.

## Remaining limits

The wider inherited suite executed **504 tests with 25 issues in 21 tests** in
this isolated checkout. The remaining failures involve uninstalled Python
`lxml`, `numpy`, Pillow/fontTools and their dependent font/voice/source-render
paths. The sound owner confirmed that their checkpoint had no verified full
Python environment either. A local ignored `.venv/bin/python` symlink reuses
their exact existing Homebrew Python 3.12 interpreter; no packages were installed.
The new workspace tests and targeted regressions above pass. The full inherited
suite is therefore **not green**; its raw log remains
`.artifacts/core-tests-configured.log`.

No actual Final Cut import or subjective audition was performed. The assembly is
a source-linked review candidate, not a verified finished edit or production
release. Existing whole-clip production gates remain intact. No actual Opus draft
was generated or claimed by this implementation; a separately authorized real
writer response can be imported without exposing its author during comparison.

## Local deliverables and reproduction

- Product/architecture notes: `Clauto Editor/docs/SCRIPT_WORKSPACE.md`.
- Candidate builder: `script/build_script_candidate.sh --build-only`.
- Synthetic acceptance project location: `.artifacts/script-acceptance-1/project-path.txt`.
- Verified assembly package location: `.artifacts/script-acceptance-1/handoff-path.txt`.
- Contract checker: `python3 script/verify_script_handoff.py PACKAGE_FOLDER`.
- Logs: `.artifacts/final-script-tests.log`,
  `.artifacts/final-script-regression-tests.log`,
  `.artifacts/sound-package-tests.log`, `.artifacts/sound-python-tests.log`,
  `.artifacts/script-editor-build.log`, `.artifacts/script-handoff-verification.json`.

The original sound checkout and paused worktrees remain available; review this
branch before deciding whether to integrate it. The app was not left running.

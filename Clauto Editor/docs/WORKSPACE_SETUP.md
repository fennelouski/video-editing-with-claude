# Local workspace setup

This increment prepares a selected project folder and reports local capabilities.
It does not install software, authenticate an account, request microphone/speech
permissions, load a model, or contact a provider. A fresh profile opens Workspace;
existing configured project locations and recent-project settings are preserved.

## Preparation and recovery

Prepare workspace creates missing directories on the selected mounted drive with
owned directory descriptors. Existing files and projects are never replaced. An
exclusive random probe is unlinked while empty; only its open descriptor receives
a short write/fsync/readback check. A failed unlink may retain an empty uniquely
named file. Created empty directories can remain after failure/cancellation; there
is no recursive cleanup. Retry is idempotent. The selected NAS location is kept;
there is no fallback to local media storage when a drive is disconnected.

Folder readiness describes the physical directory just observed, not a persistent
permission grant. Missing, renamed or replaced roots do not inherit old readiness.
Read-only Check again never creates the selected folder. Preparation is explicit.

## Capability checks

Native review and drawing do not require Homebrew, Git, an external Python command,
or a provider account. Local export checks use the selected engine's exact venv,
Python 3.12+ and parsed export/bridge scripts, plus both ffmpeg and ffprobe version
responses. Custom font builds separately check actual local image/font imports, both compiler
and tracing scripts, and a nonempty bounded engine version. Their source files
follow the same regular-file/no-symlink and size limits as the font worker.
The fixed isolated Python probe does not execute engine stages, import WhisperX,
or load/download models. Missing or broken optional libraries cannot mark other
capabilities ready. These bounded checks do not replace each job's input, runtime,
codec or provenance validation.

The account and local speech rows remain explicitly unobserved. Existing in-app
voice guidance runs only when requested. Automatic clean-user engine/tool/model
installation and a supported distribution authentication design remain unfinished;
no external installer or credentials were exercised by this increment.

## Ownership

Probe input bytes, resolved files and permissions are rechecked before publishing
capability results; font-only input changes do not invalidate unrelated export
capabilities. Setup runs filesystem probes on its own actor, separate from UI isolation even
with approachable concurrency enabled. It owns its runner and one cancellable task. Cancel, folder changes and quit
invalidate its epoch and join physical work before releasing its slot. Old results
cannot populate a newer selection; a second Prepare cannot overlap a delayed task.
Quit separately pauses admission until Keep Editing resumes it, including while
other save owners are awaited. Checks are bound to the selected engine and project folder. Open font/conversation
tools retain their captured engine; Settings explains that changing the engine
applies to those existing tools after reopening Clauto. No existing draft/context
is silently discarded or relabelled as using the new engine.

Tests use temporary folders and isolated controller state, fake tool responses, held/cancelled probes,
physical replacement controls and an actual isolated stdlib Python probe. They do
not instantiate SetupView or prove Finder launch, interactive chooser, keyboard,
VoiceOver, actual NAS, model/client installation or clean-machine GUI acceptance.

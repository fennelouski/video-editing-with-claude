# Script-first workspace candidate

This candidate adds **Script** beside Transcript and Cut. Start with the complete
source catalog in Transcript, then read every passage in Script → Sources,
including takes excluded from the existing kept story. Imported footage/audio
absent from that catalog stays visible as a coverage gap. Add its speech transcript
before drafting, or explicitly record a reviewed B-roll/no-relevant-speech
disposition. A missing transcript is never inferred to mean silence.

Script is a workspace inside the existing **Clauto Editor** Xcode app target and
bundle identity `com.nathanfennel.Clauto-Editor`. The existing `EditorStore` owns
one project-scoped controller shared by Script and Cut. No companion app, separate
project document or script-only executable is delivered.

After full-source review, create independent empty versions or import a real writer
response. A recorded beat references a whole immutable catalog row; its source ID,
word indexes, source timecodes, source media hash and transcript snapshot hash stay
attached. Headings and editorial notes remain editable. New speech is a visibly
unrecorded pickup with no claimed source timecode. Versions can be duplicated and
reordered without changing their parent or any existing transcript Keep choices.

## Comparison and approval

Select two or more versions in Compare. Starting comparison randomizes their
order once and saves anonymous option labels. Its view receives a projection with
no author, model, version title, filename, import metadata or lineage. While scores
are open, source and script editing are blocked. Every option needs clarity, story
and source-coverage scores from 1–5 before locking; scores cannot change after the
lock. Only then can the interface reveal author/model details. Attribution remains
user-supplied and unverified. Wording, headings or source names can themselves
suggest authorship; this is metadata masking, not a guarantee of formal blinding.
The private mapping and original imported JSON remain in local checkpoints.

Approval records the precise script revision and coverage hashes, and the locked
comparison when multiple versions exist. A local factual-content acknowledgment is
required. Changing script wording requests, order, notes, title, provenance or source
coverage invalidates approval. Changed project media attachments reset coverage;
changed scripts or coverage make earlier comparison scores stale. Historical
checkpoints remain available on disk. This is a local acknowledgment, not an
authenticated identity or a production release permit.

## Separate assembly package

Only an approved current script with no pickups can prepare an assembly candidate.
The repository reopens the project, verifies all catalog media and transcript
snapshots through `SourceMediaVerifier`, rechecks the saved workspace after async
work, then publishes a new UUID package under `script/workspace-exports/` using
`ProjectMutationLease` and descriptor-relative exclusive publication:

- `script-handoff.json`: exact script/coverage identities, local approval, verified
  media receipts, requested source times and integer frame/sample coordinates.
- `source-map.json`: the existing `TranscriptSourceMap` contract in script order.
- `engine-script.json` and `engine-sources.json`: existing
  `editorial_workflow.validate_script` sections/segments and transcript contracts.
- `assembly.fcpxml`: editable, source-linked FCPXML 1.13; timeline timebase is
  exactly 1001/24000 seconds. Source ranges round outward through the existing
  `SourceSpanFrameGrid`; original picture dimensions/rate and audio channels are
  read from media. No rendered/flattened movie is made.

The engine's optional segment `transcript_sha256` represents a canonical normalized
source object; the native catalog's same-named field hashes the original transcript
snapshot bytes. The engine interchange omits that optional field to avoid confusing
the two definitions. Both original snapshot and catalog hashes remain in the native
source map and handoff.

No source media, existing timeline, transcript review, project manifest, current-cut
pointer or engine script selection is replaced. The package is marked review-only,
unapplied and production-unauthorized. It is not automatically opened in Final Cut.
The legacy whole-clip pipeline remains blocked for associated transcript/script
workspaces rather than ignoring their source selections.

Each new assembly is registered in this project's
`.clauto/script-assembly-history.json` and appears in the existing Cut sidebar.
Cut verifies package hashes and displays the ordered source timeline, original
media paths and word/frame trace. Return-to-script selects its source version;
the Studio action opens the existing project's graphics/3D and handwriting/font
workspaces. Earlier candidates survive edits and show their stale approval state.
Damaged assembly history is reported separately from successfully saved script
edits, so a saved version is not accidentally submitted twice.

These source-only candidates have no rendered preview and do not impersonate a
saved `CutVersion`. Existing sound editing continues on rendered saved cuts.
Preview generation, production approval and actual Final Cut import remain outside
this review-candidate increment. No source/asset library is copied into the app;
existing external references and project-owned Studio revisions remain intact.

## Writers and local storage

Export local writer packet after source review to obtain the full native catalog,
an engine source catalog and instructions for an independent source-bound JSON
script. The importer validates every whole-row word selection and rejects invented
recorded text, stale hashes and invalid pickups. It preserves unresolved writer
fact/coverage flags in visible notes and the original input bytes privately.

Draft with Claude now offers an optional real text-only request through the existing verified subscription client. Full-source review and a completed comparison remain prerequisites. Review the exact full-source/Brief text before sending. Other script versions and private author mappings are excluded. The complete packet must fit the existing 64 KiB transport limit; oversized packets fail without truncation and remain exportable locally. A requested model ID is passed only when the actual client supports model selection; it is never silently substituted. An alias such as `opus` does not attest Opus 5.5. Reported model identity, requested model, exact request/response and source revision are retained privately in `.clauto/script-writer/`. Invalid source selections are refused; a valid response becomes a separate unapproved version. Changed state during the request prevents publication. Cancellation and exit stop/join the owned request. No new paid service, credentials, account or security permission is added. Real account/model availability is separate runtime acceptance. Manual import of an independently produced response remains supported.

Current state is a checked pointer at `.clauto/script-workspace.json`; immutable
UUID checkpoints and their hashes live under `.clauto/script-workspace/`. Stale
windows must reload, aliases are refused, and a missing/damaged head fails closed.

## Review commands

The native Script command is available from the command palette/menu and **⌥⌘5**.
Controls use the existing authored Clauto components, labeled native buttons,
text selection, keyboard focus, visible focus treatment and accessible grouping.
Source review and comparison scroll vertically; scoring controls reflow at narrow
widths. Recorded speech has no editable text field.

Use `script/build_script_candidate.sh --build-only` to build the existing Clauto
Editor target in local derived data. It builds the visibly renamed Clauto Video bundle with the existing bundle ID,
does not stage/re-identify a second bundle, and does not install or launch anything.
The earlier separately identified development QA copy was retired and removed.
Any later app launch still requires coordination with the film foreground owner.

Run native tests with `swift test --disable-sandbox --scratch-path .build/script-core
--filter ScriptWorkspaceTests` and validate a saved package with
`python3 script/verify_script_handoff.py PACKAGE_FOLDER`. The shell's restricted
macOS environment may require normal AVFoundation/Metal access for inherited media
tests; no OS security settings need changing. The candidate's verification record
is in `ScriptWorkspace/Evidence/REVIEW.md`.

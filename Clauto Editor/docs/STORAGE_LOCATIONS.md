# Storage locations candidate

This extends the existing Clauto Editor app, bundle identity, EditorStore,
Workspace setup sheet, Files intake, project manifest and pipeline paths. It does
not create another app or replace the installed/running sidebar candidate.

## Recommendation and confirmation

Workspace → Storage & tools → Plan storage locations opens the native sheet.
The five roles are edit workspace, original recording copies, proxy/cache,
export delivery copies and project backups. The app observes mounted-volume
filesystem, device/capacity group, actual available blocks, local/network and
read-only status. Purgeable capacity is separate. SSD type is shown only when
IOKit reports it. Performance expectations and workload footprints are labeled
**estimated**. No speed benchmark runs and no numeric throughput is invented.

Local rules prefer observed local SSDs for edit state and proxies, suitable
capacity for originals and a separate capacity group for backup. Shared APFS
capacity is counted together. Every role must fit with the configured reserve.
A plan with no suitable drive remains incomplete. Network fallback for active
state is explicit and warned; backup server independence is unverified.

“Recommend locations” can use the existing verified Claude text-only client and
subscription account. It sends anonymous disk aliases and aggregate capacity /
filesystem / device facts with workload estimates. It sends no paths, disk names,
project files, transcripts or credentials and enables no tools, browser, MCP or
hooks. Missing client/account or invalid advice falls back to explicitly labeled
local rules. “Use local rules” sends no AI request. Synthetic tests of the client
contract are not evidence of a real AI response.

Folder selection grants scoped bookmarks within existing permissions. Review is
read-only. Only “Confirm for future projects” creates marked child folders and
persists a profile. Form changes invalidate review. New profiles retain history
so existing project role bindings do not silently change. Offline/stale/replaced
folders stop new writes; paths remain recorded and no fallback is substituted.
The app checks available space every 30 seconds and immediately before copy /
cache requests. Network filesystem calls can remain subject to OS I/O latency.

## Existing project contracts

The optional `storageLayout` manifest extension preserves old manifests. Native
project files, authoritative run records, immutable cuts and scripts stay in the
edit project. The existing footage/assets/build/cuts/script paths contracts and
external sound/graphic assets remain compatible. New confirmed projects get
UUID-scoped original/cache/export/backup role folders and a local model-cache
path where configured. New recording intake performs a new exclusive file copy,
SHA-256 destination readback and provenance receipt before adding the reference;
the camera source remains. Existing references are not silently copied.

Generated cut artifacts remain in their authoritative per-project cut folders.
“Copy current movie to Exports” creates a verified additional delivery copy.
Project backups copy project state and preserve external media references; they
are explicitly not complete original-media backups.

## Migration and rollback

Migration is explicitly confirmed against an expiring exact source/destination /
identity / inventory fingerprint. One mutation lease excludes project writers.
The destination is new: `Clauto-copy-<UUID>/Project`; its journal is outside the
project. Every regular file gets streaming SHA-256 copy and destination readback.
Source inventory is checked before and after. File symlinks retain external
sources or rebase internal links. Directory links, offline sources, native
Final Cut bundles and database files refuse this native-only migration.

Only the known `paths.json` contract and optional manifest edit location are
rebased. Sealed cut/run/review evidence is never rewritten. JSON decoded strings
and percent-escaped references that still name the original project root block
activation. A fresh repository/workflow reopen, current movie/source hash, actual
observed preview playback and explicit user content/sync check precede catalog
activation. Empty projects have a separately checked not-applicable path.
A nonce and hash checks prevent a stale UI confirmation from acting as proof.
The app does not claim a process restart from a fresh disk reopen.

Storage jobs require an idle store and closed review / sound timeline windows,
including another window on the same store, so a sound replacement draft cannot
be dropped by a project relocation.

Activation updates the existing project ID/catalog and clears only idle
controllers for that physical root. A retained-original rollback verifies the
original and, after activation, the copy. Changed work is held for review.
Cancellation/failed validation keeps the original, partial destination and
interrupted journal. The feature provides no source deletion action, no auto
Trash emptying and no permanent cache-delete fallback. Actual user projects have
not been migrated as part of candidate QA.

## Recoverable cache

Only successful, verified source preview proxies created by this app are
registered. A local trusted registry, managed root identity, exact folder shape,
source/payload SHA-256 and record identity restrict cleanup. Unknown folders,
ordinary render/build folders, original files, app/engine files, referenced
inputs, open proxy previews and active jobs are excluded. Cleanup uses
recoverable local Trash only; a failed Trash operation retains the item.
Before encoding, ffprobe supplies the actual source duration for a conservative
bitrate-based footprint estimate. The selected proxy bitrate is capped, and a
five-second reserve watcher cancels only the owned encoder if free space or the
volume becomes unavailable. Failed/partial output remains unlisted.

The app records before/after available capacity and never treats the proxy size
as guaranteed APFS reclaim. Restore verifies the payload and requires an empty
original location. It never overwrites a replacement or empties Trash.

These protections cover app-known jobs/references/previews; the candidate does
not certify arbitrary external editors' open handles or NAS ACL/server policy.

## Validation entry points

`python3 script/verify_storage_setup.py core --seconds 180`

`python3 script/verify_storage_setup.py store-build --seconds 180`

Native app-host execution (`store`) and actual UI review require a coordinated
Clauto foreground interval. All builds use task-local `StorageDerivedData` at
nice 10 / two jobs and a bounded watchdog. The protected running bundle in
`.artifacts/DerivedData` is never overwritten. Receipts and logs are retained
under `.artifacts/catalog-<mode>-<UTC>/`.

## Candidate validation checkpoint (2026-10-26)

The 538 selected core cases completed across bounded serial runs: **528 executed
and passed**, and **10 existing opt-in acceptance cases skipped** because their
explicit media packages, cached speech inputs or live NAS/native acceptance
configuration were not enabled. All 24 new storage cases are enabled; the final
focused run passed **53/53** including existing catalog/restoration/script guards.
A single earlier monolithic run reached its 180-second watchdog without test
failures; the complete bounded batches supersede that incomplete attempt.

The same native app and all test sources compile successfully. The latest 11-case native store/window run **executed and passed** at
`.artifacts/catalog-store-20261026T151227Z/`. Disposable setup fixtures inject
synthetic capacity facts under their temporary roots to avoid depending on
changing host free space; production uses the real filesystem probe. Actual
live storage-pane inspection remains deferred at the parent's A440 handoff;
no live storage profile was applied. The review
candidate is not installed, merged or released. No live storage profile has been
confirmed, no live project migrated, and no live media/cache deleted.

Task-local evidence:

- `.artifacts/storage-validation/core-regression-results.json`
- `.artifacts/storage-validation/core-test-inventory.txt`
- `.artifacts/storage-validation/before-live-ui.json`
- `.artifacts/catalog-core-20261026T135128Z/{receipt.json,output.log}`
- `.artifacts/catalog-core-20261026T135354Z/{receipt.json,output.log}`
- `.artifacts/catalog-core-20261026T135733Z/{receipt.json,output.log}`
- `.artifacts/catalog-core-20261026T140154Z/{receipt.json,output.log}`
- `.artifacts/catalog-store-build-20261026T140719Z/{receipt.json,output.log}`

The native execution plan covers the two new storage/store cases and seven
existing sidebar/restoration cases, then the Locations / Existing projects /
Recoverable cache panes and existing project switching. QA will not apply a live
profile, select migration folders, delete cache, run paid AI or play live media.

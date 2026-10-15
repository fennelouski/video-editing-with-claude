# Synthetic source-span rendering milestone

The native `SourceSpanRenderService` now drives a deterministic source-span engine
worker. This increment renders only media issued by
`SyntheticSourceSpanFixture.generate`. It has no production GUI action and does
not render Katie's selections or write `cuts/current.json`.

## Integrated requirements

| Requirement | Implementation |
|---|---|
| Genuine synthetic admission | Only the native generator can construct the in-memory permit. It creates a new QA project and pins project/fixture IDs, directory identity and exact manifest/catalog bytes. A JSON flag or folder name cannot mint the native permit. Persisted manifests are evidence, not restart authorization. |
| Original source mapping | The exact saved map, revision, acknowledgment ID and acknowledgment byte SHA are frozen. Stable IDs drive ordered source slices; A→B→A retains different original In/Out ranges from the same clip. |
| Explicit frame/sample grid | This generator uses constant 24000/1001 fps and 48 kHz mono PCM: exactly 2002 samples/frame. Original requested seconds stay in the receipt alongside integer start/end-exclusive frames and samples. Outward rounding must fit verified source/audio coverage; it never clamps or pads an uncovered range. A tolerance of 10⁻⁷ frame recognizes floating-point representations of exact grid values. |
| Real local render | `scripts/render_transcript_spans.py` trims each selected source to those frames/samples, encodes ProRes/PCM parts, and assembles `review.mov` plus an editable original-source `timeline.fcpxml`. The MOV movie timescale is 48000, avoiding millisecond header rounding. |
| Decode and timing proof | Strict FFmpeg decoding uses `-xerror -err_detect explode`. Exact frame/sample counts and packet timestamp continuity refuse gaps, overlaps and retiming. Native validation checks actual AVFoundation duration, fixed artifact hashes, ordered spans and the exact deterministic FCPXML shape/format/source whitelist. Installed Final Cut DTD validation is recorded separately. |
| Source preservation | All original media/transcript bytes are read-only, hash checked, and checked for path/signature drift before/after. The factory's source paths must match the exact generated manifest and catalog. No source is rewritten to satisfy a selection. |
| Destination ownership | Directory handles anchor exclusive, no-follow file creation. FFmpeg uses inherited seekable `fd` protocol descriptors, rather than reopening destination paths. Failed work remains in its owned staging directory; there is no recursive pathname cleanup. |
| Publication | A unique bundle uses a no-replace rename where supported. Only an explicit ENOTSUP uses exclusive UUID-directory creation plus descriptor-relative exclusive copies. The final directory identity and strategy are recorded; current remains the sole commit point. Under the transcript-review lock, native code rechecks head/map, exact acknowledgment ID/bytes, cancellation, directory identities and final artifact hashes before atomically replacing only `.clauto/source-span-synthetic-current.json`. |
| Failure preservation | Missing/changed originals, stale choices or a replaced acknowledgment, cancellation, output collisions, malformed/rehashed timeline proofs and simulated storage failures refuse publication. The previous synthetic-current bytes and production cut pointer remain unchanged. |

## API and evidence

The programmatic entry is `SourceSpanRenderService.renderSyntheticReview` with a
factory-issued fixture, exact saved revision and local source-review acknowledgment
ID. It uses the existing `CommandRunning` process supervision and cancellation.
The worker is a deterministic subordinate, not an approval authority. Direct CLI
flags do not grant native or production approval.

A job starts in `build/source-span-reviews/.pending-<UUID>/`. Its input, exact source
map, encoded parts, render proof and any failure evidence are retained. A completed
QA bundle is materialized at `build/source-span-reviews/<UUID>/` and includes:

- `input.json` and `source-map.json`, binding the exact native request;
- `review.mov` and `timeline.fcpxml`, with their full hashes;
- `render-proof.json`, recording exact stable-ID order, original/retained ranges,
  decoded counts, packet coverage and DTD result;
- `completion.json`, recording the final directory identity, artifact hashes and
  explicit `productionAuthorized=false` / `appliedToCut=false` scope.

The actual Videos SMB volume returns ENOTSUP (45) for exclusive directory rename;
directory fsync succeeds. Its bounded fallback copies only the fixed required files
into a newly reserved UUID directory, then verifies them and writes completion.
It never uses a replacing rename or adopts an existing directory. The pending
source evidence is retained. Every other rename/write/fsync error remains fatal.
Materialization by this fallback is not atomic; consumers must ignore a visible
UUID directory without a valid completion/current binding.

An incomplete or collision-blocked bundle is never the current preview. An orphan
bundle after a failed pointer publication remains inspectable. Ordinary app
production approvals and all existing cut versions retain their previous meaning.
The limited local mapping acknowledgment remains `renderingAuthorized=false`; QA
permission comes separately from the in-memory generator permit.

## Deterministic acceptance

The full native core suite passes 99 routine cases, with six opt-ins skipped
(105 registered). Fourteen Python worker cases and eight routine native integration cases use actual
local generated media. The source A changes from red/220 Hz to blue/660 Hz; source B
is green/440 Hz. A→B→A selects source frames 6–18, 24–36 and 42–54. The output is
36 frames and 72072 audio samples (1.5015 seconds). Acceptance compares every decoded
PCM sample with the selected original slices, checks visible color order, validates
source hashes and editable timeline ranges, and preserves a prior cut sentinel.

Failure cases include changed/missing media, altered fixture/frozen-input aliases,
changed review or same-revision replacement acknowledgment, cancellation at final
publication, exclusive-file/bundle collisions, rehashed wrong format/extra media
reference/nested timeline content, and project/staging directory replacement.
A real worker test swaps the destination after its output descriptor is opened,
then confirms FFmpeg wrote only the original owned directory and left the foreign
replacement sentinel untouched. Simulated ENOSPC retains partial parts without a
success proof. These are deterministic filesystem/process simulations, not a claim
that a physical SMB outage or full NAS was tested.

The separate native opt-in `durableSyntheticNASSourceSpanAcceptance` runs only when
`CLAUTO_SOURCE_RENDER_ACCEPTANCE_ROOT` is supplied. It generates a new labelled NAS
QA project, verifies decoded samples and writes `SOURCE_SPAN_ACCEPTANCE.json`.
It never consumes private footage, the live Sheet, v7 or the expansion proposal.

## Remaining limits

- Production source-span application, an actual independent editorial ledger and
  trusted human fact approval remain blocked. No source-bound review package or
  local acknowledgment becomes production consent.
- The supported synthetic fixture contract is deliberately narrow: fixed rate,
  dimensions and mono audio, no mixed/VFR sources, nested timelines, transitions,
  graphics, grade, music, natural breath assembly or final horizontal tail. The QA
  assembly is not a finished video or evidence of finished-duration requirements.
- Descriptor inheritance pins file identity during worker I/O, **not immutable
  bytes**. Before/after SHA and signature checks detect observed mutation; in-place
  writes can still occur between checks. AVPlayer also reopens URLs. A production
  immutable-byte transport and revalidation before later playback/import remain
  separate work.
- Destination handles prevent pathname swaps from redirecting file writes. Final
  path/identity/hash checks protect publication, but arbitrary changes after
  publication can make a saved artifact unavailable. Consumers must validate the
  recorded directory/artifact identity before use.
- Atomic pointer rename is the publication point. File fsync happens before it;
  directory fsync afterward is best effort. Power-loss durability and actual NAS
  disconnect/hang behavior remain unverified. There is no forced deletion of
  incomplete work or restart/resume permission minted from a manifest.
- No app launch, Final Cut import, interactive playback, listening, VoiceOver,
  subjective editing or scientific acceptance is asserted by these tests.

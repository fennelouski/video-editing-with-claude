# Bounded synthetic source-byte contract

The source-span worker now validates and renders the same captured media bytes.
Only the existing native factory permit admits the generated A/B color-tone QA
project. Production rendering remains gated; this does not admit private footage.

## Requirements and implementation

| Requirement | Behavior |
|---|---|
| Bounded storage | Exactly two generated 72-frame sources, each at most 1 MiB and together at most 2 MiB. The byte budget is reserved before snapshot creation. No full-footage copy, new cache root, provider or credentials. |
| Reuse existing ownership | Each job uses its existing descriptor-anchored staging directory. A random exclusive file is opened through independent writer/read-only descriptors; their device/inode must match. Its directory entry is unlinked before any media bytes are copied. |
| Stable captured bytes | Exact initial-size chunked copy rejects early EOF, growth, read/write errors and observed signature changes. The writer is fsynced and closed before the snapshot hash is checked against the trusted fixture SHA. The remaining descriptor must be O_RDONLY, zero-link and exact-size. |
| Same validation/render input | All source ffprobe packet/coverage/format checks and FFmpeg trim/decode inputs use those same snapshot descriptors. Native AVFoundation verification of originals is early refusal only; it cannot authorize output without the worker's snapshot validation. The worker rederives the explicit frame/sample plan and verifies actual output independently. |
| Observed original changes | Held original handles and current original paths retain full hash/signature/identity checks. Observed replacement, truncation, mutation and mutation followed by byte restoration refuse success. Snapshot isolation keeps retained partial output tied to trusted bytes even in these failed jobs. |
| Lifecycle | No writable snapshot descriptor is inherited by child tools. Every retained snapshot and original handle closes on success/error; process exit also releases unlinked files. A setup failure before unlink may retain only an empty random file as failure evidence. There is no recursive pathname cleanup. |
| Native receipt | Required strategy `private_unlinked_readonly_v1` and exact source-ID/SHA/size/read-only/unlinked receipts are checked against the factory manifest and native preflight signature sizes. Missing, altered or oversized receipts refuse publication. Completion/current records retain these bindings. |
| Concurrency and cancellation | Each job owns its budget, random snapshot descriptors and UUID staging bundle. Concurrent jobs do not share mutable snapshot state. Capture exceptions and actual worker cancellation preserve the prior current pointer and production cut. |

Snapshots are temporary copies on the selected staging filesystem, not a memory
cache or a new persistent source collection. The unlinked inode remains allocated
only while its handles exist. If unlink-open behavior or zero-link/read-only
verification is unsupported, the job fails closed; it never falls back to reading
mutable originals for media tools.

## Acceptance

Twenty-nine Python cases cover exact decoded A→B→A audio/frame order; concurrent
original replacement, truncation and restoration after capture; early EOF/growth;
simulated original/snapshot read failures and write errors; zero-progress writes;
unsupported unlink/open; cancellation during capture and just after readiness;
descriptor closure; byte limits; and two concurrent real renders. No proof is
written by a failed worker, and prior-current sentinels remain unchanged.

Eleven routine native render cases include two concurrent jobs, real subprocess
cancellation after snapshot readiness and tampered snapshot receipts, alongside
existing stale-review, destination ownership and source/output failure cases.
The full core suite has 108 registered cases: 102 routine cases and six opt-ins.
The NAS opt-in uses a newly generated small project and records actual snapshot
byte counts and unlink/read-only capability alongside exact PCM acceptance when
the contract can be admitted. The actual Videos SMB volume currently reports one
link after successful unlink, although the owned name is absent and an open
read-only descriptor still reads exact bytes. The strict zero-link attestation
therefore **blocks NAS rendering**; no weaker fallback is implemented. An explicit
test-only expected-block mode verifies unchanged prior synthetic/production
pointer sentinels and source hashes, with zero snapshot media bytes copied.

## Limits

This closes the bounded worker's mutable-original read gap through capability
lifecycle isolation. It is not an OS-level file seal or a security boundary
against arbitrary same-user code, FD/memory injection, privileged access or a
hostile filesystem server. Before/after snapshot hashes detect observed storage
corruption; no guarantee is made about adversarial mutation between checks.

Native preflight and interactive AVPlayer still open original URLs. The editable
FCPXML deliberately references original media, so later playback/import must
revalidate it. No immutable transport is asserted for production footage, later
consumers, physical NAS disconnects/hangs, power loss or restart/resume. Existing
publication ownership/atomic-pointer behavior and editorial/fact gates are
unchanged. No app foreground or Final Cut acceptance is claimed.

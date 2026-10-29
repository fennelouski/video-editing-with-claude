# Independent review implementation — source checkpoint

Based on `b6519b4`, reconciled against the independent packet at
`/Users/nathanfennel/Documents/Codex/2026-10-25/task-4/review-packet-2026-10-29/REVIEW-PACKET.md`.
These are source changes, not a runtime acceptance claim.

| Finding | Source behavior prepared | Acceptance still required |
|---|---|---|
| C02 | Explicit Retry preview reuses the owned session/player; clears the old item/transport, verifies a retained import/promotion checksum or previously pinned hash, rechecks opening signature, then installs one new item. It rejects replacements, preserves project controllers/drafts and refuses retry while capture, frame editing or an external video surface owns the context. Voice/transport stay disabled until verified. | New native missing/restore/replacement/draft fixture; decoder/observer and detached/PiP runtime checks. A legacy missing preview with no retained checksum stays unavailable rather than adopting arbitrary bytes. |
| C05 | Read-only version catalog returns independently validated healthy records and per-record issues; missing metadata, malformed JSON, unsafe paths and duplicate IDs stay unavailable. Root access failures still throw. An invalid/missing current pointer stays unresolved; review does not promote another version. Strict generation/publication callers retain failure semantics. Verified healthy feedback/preview targets can be read despite a malformed peer. | Mixed-validity, unsafe path, unresolved current and inaccessible root fixtures; native refresh/history review. The diagnostics do not repair or delete any saved record. |
| C15 | Pane focus gets its own boundary. Authored button styles no longer treat inherited pane focus as each button's focus; actual controls retain native focus effects and selected styling. | Native Tab/Shift-Tab/Return/Space checks in custom and Standard themes. Full Keyboard Access/VoiceOver and existing contrast findings remain separate; no setting is changed. |
| C14/C16 | Chat/Studio commands append stable enum IDs; Cut is named Cut with review search alias. Pure context availability/reasons are shared by menu and palette; non-Cut workspace actions explain their prerequisite and unsupported assembly surfaces stay disabled. Dismissal-time project/player/origin guards remain, with watched-version check for workspace actions. | Capability matrix fixtures plus native command/keyboard/dismissal tests. Availability is never authorization to dispatch against a changed target. |
| C01 | Project Build explicitly names current-cut context; a separate watched-version export sheet captures an immutable version. Exact local Chat commands require a visible pre-Send target review and fresh equality check on Send. A changed target retains the draft; already committed exact retries keep their original target. The default is still project current, never last watched. | Two-version fake-target tests; updated local-edit/rollover fixtures; native selected-version export and changed-target review. No provider call is necessary. |
| C17 | Display model compresses only the exact machine suffix when saved import provenance/checksum matches. Full labels remain accessible; Current and Watched are distinct; RESTRICTED REVIEW and held units omitted remain explicitly visible. | Long-label/group/width and accessibility checks. No saved label, folder, project group or pointer is rewritten. Compact project-rail/C07 and unrelated theme/C04 work are not claimed here. |

Five meaningful regression cases are added (command matrix, display/provenance,
mixed-validity history, Chat target change and native preview retry), and existing
local-command fixtures now perform the explicit target-review step. Their source
has been inspected; **none has compiled or executed in this pass**. The earlier
three Storage/Sounds cases at b6519b4 are also still unexecuted. The only executed
check is `git diff --check`.

No application activation, build, simulator, phone action, media playback,
provider call, installation or user project write occurred. Pan v014 and its
existing v013 current pointer remain protected. The current running bundle is
not changed by editing this branch.

Before requesting a combined build, reconcile these changes and b6519b4 with the
separate 3D/handwriting candidate e08c41b in a new isolated candidate. Preserve
its storage admission/adoption pending-work guard alongside the new sound quit
and asynchronous folder-choice guards. Never use its stale frozen build request
as authorization for newer source. Fresh coordinator admission, targeted tests,
native acceptance and exact storage-path confirmation remain gates. No release
or migration/source-removal authorization is implied.

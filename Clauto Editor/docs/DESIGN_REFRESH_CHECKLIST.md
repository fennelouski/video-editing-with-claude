# Approved design refresh — implementation checklist

Nathan approved building the ten-part design on 2026-10-15. This checklist
tracks local incremental work after `ea7ff6e`; it is not full acceptance,
release authorization, or permission to publish the public repository.
The implementation owner remains the sole source writer. Preserve the active
import checkout, native-tools WIP, NAS project media, and prior audit receipts.

| Requirement | Current increment | Remaining acceptance / implementation |
| --- | --- | --- |
| Eleven semantic themes, Homey default | Stable IDs, persisted choice, original palettes/material treatments, native Standard colors/buttons/fonts, native text-area color refresh, contrast tests | Render every theme and every interaction state; increased contrast, text scaling, selection/focus/disabled pairs; refine authored material references |
| One command architecture | Shared typed registry, native menu/palette, navigation, configured skips, J/K/L, rational frame steps/non-drop timecode, versions/pane commands | Active-window/IME/physical keyboard acceptance; contextual availability and palette restoration matrix |
| Selectable app text | Root text selection, native text areas, copyable timecodes/errors and single tooltip text | Audit all app-owned labels and controls; preserve honest native menu/button exceptions; physical selection precedence |
| Bare-video play/pause | Mouse-up action with movement threshold, focused Space/JKL/frame keys, explicit-control command guards | Physical click, drag, controls and annotation exclusion checks |
| Native macOS PiP | Public AVPlayerView controls, retained delegate, start/fail/stop/restore lifecycle and external ownership | Actual native PiP acceptance. Public SDK has no programmatic start operation; start uses the visible AVKit control |
| Custom detached video | Store/window-scoped stable session and one reparented AVPlayerView, close-to-dock, threshold drag, video-window fullscreen/Escape, display recovery and idle controls | Actual playback reparenting, transition failures, focused controls, screen unplug and physical window tests |
| Compact copy / one tooltip | New compact review workspace and microphone controls; global delayed/Option tooltip with selectable text | Measured before/after copy comparison, full-app removal pass, rapid hover/focus/Option acceptance |
| Original icon | Existing original editable geometry and complete macOS asset catalog retained | Recheck small-size readability against new default; no other platform app target exists |
| Explicit local voice and feedback cards | Existing on-device provider, explicit target/mic controls/meter, provisional/final notes, original onset/history/reanchor/candidate isolation; measured signed rate and rate-change epochs; spoken-order cards; explicit merge/split, retained parent/anchor lineage, stale/candidate invalidation and late-ASR protection; ambiguous-reference flags; final idea groups from reported audio runs, captured silence, explicit topic cues and inter-run transport boundaries | Durable new typed drafts; real permitted microphone and native desktop acceptance |
| Adaptive three panes | Versions/assets left, stable video/timeline center, independent feedback scroll right; pane toggles/focus and compact project rail; detached placeholder | Actual compact/large/long-card/large-text renders, repeated focus, persistence across themes and navigation |

## Validation boundaries

- Actual private Pizza Yeast v7 passed the prerequisite seek/pause/exact-frame,
  circle add/undo/redo/remove and five-second skip probe. Source/current pointer
  were unchanged; private PNGs stayed in memory; no Sheet write. Receipt:
  `.artifacts/pizza-v7-frame-controls-validation.json` (ignored/local only).
- Core tests use synthetic media/clocks. Native structure tests construct
  offscreen views/windows and synthetic media; they do not establish foreground,
  physical interaction, native PiP, VoiceOver or external-display acceptance.
- Existing running review bundle is not overwritten. New builds use isolated
  `.artifacts/DesignRefreshBuild`; no independent phone or Final Cut operations.
- Frame comments remain bound to their synchronously frozen version/frame.
  Voice target selection remains explicit. ASR completion time never substitutes
  for speech onset. No new permission, model download or external audio service.
- The versioned app design principles copies distributed by another task are
  preserved separately from this feature payload until their owner reconciles them.
- Main-sync owner reviews exact immutable payload/build receipts before testable
  handoff. No push, merge, deployment or upload has been performed here.

## Milestone 2 — manual feedback cards

- Merge adjacent finalized cards from the same saved version, or split after an
  exact opening phrase at a Unicode-safe word/punctuation boundary. Original
  cards, ASR history, onset anchors and revisions remain in the ledger.
- New cards require a newly confirmed range and Protect/Remove action. The app
  does not infer split word timestamps or expand the original protection range.
- Card order follows captured audio/session order, including older ledgers and
  nested splits. Delayed ASR cannot resurrect a retired parent. Stale operations,
  unsaved drafts and changed revisions refuse atomically; retried operation IDs
  cannot duplicate children. Old candidates are invalidated.
- A delayed draft on a retired card remains visible as selectable read-only text
  until discarded. Card transactions join the tracked save queue synchronously;
  quit waits for them before reporting a successful flush.
- Synthetic regression tests cover these invariants and the exact checksum of a
  ledger generated by the committed pre-M2 encoder. GUI/physical acceptance is
  still pending. Natural speech segmentation and restart-durable new typed
  composers are separate increments, not claimed here.

## Milestone 3 — reported speech timing and conservative idea groups

- VoiceKit retains the public SpeechAnalyzer attributed text/audio ranges.
  Partial recognition stays one provisional card. Final speech can divide at
  real run boundaries after a continuously captured pause of at least 1.2 seconds,
  an explicit sentence/topic cue, or a seek/pause/version/rate boundary between
  runs. A multiword run is never divided using invented word times.
- This is a local deterministic grouping rule, not semantic AI topic detection.
  The entire original utterance and reported timing runs are retained; each card
  uses its reported speech onset. Shifted first-word timing, incomplete/overlapping
  coverage, Unicode-invalid ranges or a boundary inside a run need manual timing
  resolution. Missing microphone packets are not classified as silence.
- Final ASR waits for late captured-clock packets before grouping. A manual edit,
  cancellation, merge/split, stopped session or wrong capture attempt cannot be
  replaced by late automatic groups. Original candidate and watched-version
  isolation continue to apply. No microphone, permission request, model download,
  external speech service or private footage is used by these synthetic checks.

## Player identity and rate guard correction

- Player creation pins the movie's path and fast file signature before creating
  its decoder. The asynchronously prepared full target must match that opening
  snapshot and a fresh signature check before an endpoint can publish.
- Explicit voice selection uses the immutable target held by the watched player;
  it does not recompute a new disk identity for an already-open decoder. Changed
  saved media refuses binding and leaves the microphone off.
- Rates outside the supported signed −4…4 ledger range, including nonfinite
  values, record an unavailable interval with no target. Original feedback stays
  durable and unresolved, and returning to a supported clock creates a boundary.
  Such a rate cannot poison the durable save queue or supply a guessed anchor.

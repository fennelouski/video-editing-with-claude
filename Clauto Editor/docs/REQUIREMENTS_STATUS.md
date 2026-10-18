# Clauto Editor implementation coverage

The editor is incomplete. A project launch, compiled control or passing fixture
does not establish full-product acceptance. This checklist reconciles the
product/architecture/UX documents, the eight expanded features and the later
continuous-feedback requests. It distinguishes missing implementation from
implementation that still needs native acceptance.

The app drives an instruction-based editing engine. The product explicitly
excludes a competing timeline editor; editable finishing remains in Final Cut.
Graphics explicitly requested by the user are allowed under their documented
source, licensing and scientific-review rules.

| Agreed workflow | Implemented scope | Missing implementation or acceptance |
|---|---|---|
| Create/open projects and ordinary recovery | Folder-owned projects, autosaved Brief, immutable inputs and physical-root validation. M26 adds selected-project/tab restoration and preserves disconnected Recents. | M26 exact test/review/native acceptance pending. Duplicate/archive and a general file replacement workflow remain missing. |
| Footage, audio, music, images and scripts | Classification, reference/copy intake, script replacement and frozen approved copies. | Complete mixed-file GUI acceptance, general Replace, and unsupported-camera guidance/hand-off acceptance. |
| Brief to first cut | Local staged engine, preflight, missing-piece and plan gates, script selection, frozen settings and saved artifacts. | Fresh-user installation and full raw-footage-to-cut GUI acceptance. The app must not silently bypass script, facts or asset gates. |
| Continuous feedback | Durable text transport, streaming, steering, retained drafts, exact retry and 120-second quiet packets. | General semantic editing and full native/provider acceptance. Provider replies alone never prove an edit was applied. |
| Local editing jobs | Exact range/aspect/resolution commands produce separately verified local exports; cancellation joins the owned worker and preserves parent cuts. | Promotion into named main-version history, automatic crash retry and job-ledger archival. |
| Saved versions | Named pipeline versions, version-bound feedback, compare/restore and parent preservation. | Main-version promotion for derivative/candidate results, branching and native end-to-end acceptance. |
| Preview and transport | Version-specific player, seek, frame stepping, rate, detached/fullscreen/PiP surfaces and scoped commands. | Actual interactive playback/keyboard/IME/VoiceOver acceptance across surfaces. A file-open or window observation is narrower evidence. |
| Voice review and region dictation | Embedded local speech path, guided asset preparation, anchored raw recognition, manual-edit precedence and final-word drain without mandatory finalization. | Actual microphone/model/native acceptance, long-session ASR rollover and spoken-name disambiguation. |
| Frame notes and people | Exact-frame shapes/freehand/highlight notes, immutable frame provenance, local people IDs and typed region mentions. | Original-camera time mapping, tracking, candidate-frame notes, broader/spoken mentions and full split/unmerge. |
| Generated graphics | Six bounded editable models, Metal/CoreText output, transparent animation and immutable assumptions/source revisions. | Native visual/scientific/keyboard/VoiceOver acceptance. Toy models are not validated scientific predictions. |
| Background cutouts | Project-local originals, selected/supplied masks, manual restore/erase/feather, Undo and immutable PNG revisions. | Actual Vision accuracy and native correction/intake acceptance; standalone insertion outside a scene. |
| Custom fonts | Image/folder intake, mappings, editable outlines, labelled licensed fallback and actual TTF/WOFF2 outputs from exact bytes. | Native typography/keyboard/VoiceOver acceptance and standalone native text insertion. Fonts are not installed silently. |
| Graphic/cutout/font composition | One chosen immutable scene can be composed into a separate verified export with an editable connected graphic layer. | Multiple new insertions, main-version integration and full native/Final Cut visual acceptance. |
| Portrait extraction | Selected source range, fit/fill/position, caption/graphic/audio timing and actual portrait output. | Complete visual safe-area/GUI acceptance and richer unsupported Final Cut effects. |
| Audio effects and local sounds | Gain, filters, compression, bounded echo and sound placement; processed PCM files and output verification. | Interactive preview/export parity and broader effects. Original audio remains unchanged. |
| Duration and resolution | Finite min/max gates, global default/project override and frozen landscape/portrait output settings. | Native defaults/reopen and visual scaling acceptance. Impossible durations need review rather than invented padding or retiming. |
| Export and editable handoff | Verified movies, FCPXML, captions and PDF handoff with source/input/output hashes. | Main-version integration and complete GUI/Final Cut acceptance. Export verification does not authorize new editorial/scientific choices. |
| Cadence | M25 corrects connected/primary source clocks, validates all output timestamps and counts, and checks video bounds independently of audio. | Main reconciliation and native interactive acceptance remain separate. Existing automatic microsplices are preserved rather than silently changed. |
| Clean-user setup | Folder preparation, capability probes, retry/cancel ownership and explicit guided account connection. | Supported tool/client/engine installation, model prefetch/repair and a clean-user no-Terminal acceptance run. |
| Long sessions and recovery | Completed local-history rollover, draft recovery, exact late-ack receipts and deterministic folded edit bases. | Provider-context rollover, unresolved/pending queue and job-history archival, and automated crash retry. |
| App identity and accessibility | Authored icon/font/theme system and desktop command structures. | Remaining default-symbol/control cleanup and full keyboard, large-text, Reduce Motion and VoiceOver acceptance. |
| Distribution | Local signed builds and static validation. | Notarization/update/distribution acceptance. No deployment or App Store publication is authorized by this implementation task. |

## Ordered completion work

1. Make ordinary project restart usable and test unavailable/racing folders.
2. Preserve a verified derivative as an immutable named main version with exact
   parent lineage, copied assets and compare-and-swap current publication.
3. Add source-bound semantic proposals through the existing candidate/review gates.
4. Complete remaining project/file lifecycle and approved setup/recovery paths.
5. Run native synthetic end-to-end workflows and resolve actual interaction,
   accessibility and visual defects. Test privately only when locally authorized;
   do not upload media or transcripts to external AI.

Each milestone requires an exact reviewed source pin, appropriate tests and
coordinated main integration. A final installed-app upgrade must preserve current
user work, be recoverable and receive a separate runtime check. Earlier negative
controls and source/build receipts remain immutable; later progress does not
retroactively change their acceptance.

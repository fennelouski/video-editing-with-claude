# Project people and frame associations

Clauto finds anonymous human rectangles in a captured review frame on the Mac, then lets the user explicitly name a selected region. The frame is the verified PNG from the exact saved movie and paused presentation time. The normal app composition injects the local detector; core tests inject synthetic detectors and never invoke Vision.

## Guided interaction

After capture, local Vision analysis starts automatically in the background. Dashed boxes and numbered keyboard-accessible buttons offer candidate regions. Choosing a suggestion adds an ordinary editable highlight. A suggestion has no name or person ID. Draw a region manually when a suggestion is missing or inaccurate.

Open **People in this Project**, add a name, then use **Assign a Person** on the selected region. Every duplicate name remains a separate choice with a stable creation-order number. Name matching returns all candidates; it never assigns a spoken or typed name automatically. A selected region can change or remove its link, resize, undo or redo. Frame comments remain review notes and do not authorize production edits.

The project roster supports renaming, archiving/restoring an unmerged profile and explicitly merging an active profile into another. Merging preserves old IDs and name snapshots; future choices use the destination. The core can create a separate profile with a split provenance event, but partitioning existing links and a full split/unmerge interface are unfinished.

## Storage and provenance

`.clauto/people.json` contains a bounded checksummed local payload: project UUID, stable profile UUIDs, current/previous labels, profile revisions, archive/merge state and explicit ordered history. Its roster must exactly replay that history. Limits are 512 profiles, 4096 events, 64 previous labels per profile, 160 UTF-8 bytes per label and a 3 MiB inner/4 MiB outer envelope. Names normalize to NFC; controls and empty labels refuse. There is no face embedding, identity lookup, cloud request or automatic identity association.

Mutations share the descriptor-bound project mutation lease and atomically replace the catalog. They never rewrite the project manifest. Symlink, tampered, duplicate-key, foreign-project and stale-root payloads refuse. Failure leaves saved bytes intact and retains the entered name. No-op name/archive operations preserve catalog bytes.

Optional region references record project/person IDs, the explicitly selected name snapshot and user confirmation. New UI assignments require an active current profile. Save checks that referenced IDs and historical labels exist in the valid local roster while holding its mutation lease. A profile rename or archive while a draft is open preserves the earlier choice. Completed comment history and exact completed-save recovery remain readable if the roster is unavailable. Old ellipse encodings omit the new optional field and retain identical bytes. Removing or changing a link is recorded by annotation undo/redo and the next immutable frame-comment revision.

## Detection limits and verification

The detector uses `VNDetectHumanRectanglesRequest` revision 2 with full-body rectangles. It only decodes a verified one-image PNG within the existing 16 MiB/33-megapixel bounds; it converts Vision's bottom-left coordinates to the stored top-left coordinate system. Suggestions require finite confidence 0.5–1, valid in-image bounds and at least one source pixel on each axis, capped at 32. Every result is bound to the request and frame hash. Cancellation/generation checks prevent late results from modifying another or closed draft. Analysis is optional to saving an ordinary note; failure offers an in-app retry.

Synthetic tests cover duplicate choices, history replay and valid-hash tampering, rename/merge/archive history, shared-lock concurrent writes, stale roots, symlinks, explicit region association, undo/resize, saved revisions, forged references, unavailable-roster historical recovery, geometry and late-result cancellation. Live Vision accuracy, gesture/layout/VoiceOver behavior and the exact app runtime have not been observed under the foreground hold.

Typed @mention editing, spoken-name disambiguation UI, direct region dictation/raw-ASR evidence, cross-frame tracking, original-camera time mapping, full split/unmerge and explicit people export remain unfinished. No tracking or real-world identity is inferred from the current boxes.


The corrected rename editor retains draft wording by project/person ID, gives each native field a pinned identity and acknowledges only the submitted text. Select-mode click routing selects or clears an existing mark; suggested-person acceptance and new pins require a drawing-mode click or explicit Mark Person button.

Vision request construction, synchronous perform and deferred request cancellation now stay on an owned serial blocking queue with four admitted active/queued jobs. Cancellation releases the Swift waiter and rejects late results while retaining physical capacity until the request returns. An individual synchronous Vision operation is not forcibly interrupted. Live Vision execution and accuracy remain unobserved; core tests still use injected synthetic detectors.

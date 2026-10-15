# Continuous conversation — bounded transport increment

The project composer saves submitted messages before connecting, streams replies,
and accepts steering while a reply runs. New feedback interrupts the owned reply
and continues with the same session. Partial words and every terminal attempt
remain in history. There is no required Stop and Finalize action. Disconnect is a
privacy control; Retry Reply preserves the earlier failed/interrupted attempt.

This increment supplies the conversation mechanism. It does not apply a cut or
claim to have watched, edited, approved or rendered video. Connecting idle packets
to longer local editing jobs remains unfinished.

## Guided connection and exact data boundary

Send saves the message first, then checks the installed client and account.
Sign In to Continue guides the user through the client's browser flow. Cancel
Connection stops only the owned attempt; late completion cannot reconnect an old
attempt or cancel a newer runner. No terminal command is required in this flow.
Automatic installation of a missing/incompatible client is still unfinished.

The existing client owns sign-in and credential storage. Clauto reads no tokens
or passwords. Subscription login is selected explicitly; API-key, helper and
third-party methods do not silently qualify as ready. Account JSON/login output
is not written into project history. The implementation uses the
[official CLI account contract](https://code.claude.com/docs/en/cli-reference)
and a hash-pinned local help contract. This is not evidence of a real account turn.

Only text explicitly sent in this composer is eligible for a request. The
transport requires an ephemeral authorization matching project UUID and exact
UTF-8 prompt hash. Earlier local requests, media, recognition text, frame notes
and project metadata are not automatically attached. The otherwise empty client
workspace grants no engine/project file access. CLI tools, skills, customizations,
hooks, Chrome and external MCP servers are disabled. Emitted tools are refused.

Each turn gets a fresh runner. The executable hash and account are checked again.
Arguments use no shell interpolation. Stream identity must match this session;
a terminal result and successful process exit are both required. Changed identity,
malformed/truncated/oversized output, tools or process failure preserve received
words and refuse success. Provider failures show an app action rather than raw
command-line instructions.

Cancellation admission is checked again after local ledger/workspace awaits.
Every reply has a separately owned, joined task: steering cancels that task while
the uncancelled worker saves final received text. Transport cancellation is also
retained before/after account checks. A submission delayed by storage cannot
reconnect after Disconnect. Retry Saving can save an unsent draft during a reply;
it recovers uncertain claims/completions only after their worker has ended.

## Persistence and continuous steering

The physical project root and common mutation lease protect the SHA-linked
`.clauto/live-conversation.json` envelope. Mutations reload current state, advance
its revision and publish atomically. Queued messages survive older partial-reply
acknowledgements. Autosaved drafts carry ownership/revision identities and
deterministic submission IDs. Delayed saves cannot resurrect submitted words;
newer unsent words survive an older acknowledgement.

Draft publication compares the exact saved base, not just a larger local revision.
Owned draft writes are serialized; submitting a draft atomically enqueues its
message and retires that draft revision. A conflicting external writer cannot
silently replace unsent words. Send remains available during account setup, and
the idle clock starts at first message publication, including restored drafts.

An explicit Retry Saving cancels its pending debounce before entering the same
serialized writer. An already admitted write is still joined and acknowledged;
newer edits keep their own autosave. This avoids a delayed duplicate waiting behind
an unrelated project mutation after the user's save already completed.

A conflict offers Keep Both Drafts: the exact local unsent snapshot is archived
atomically with reading the current saved draft. The returned draft replaces the
composer only if its local content generation still matches the clicked snapshot.
Later edits stay active/dirty. Recovered Unsent Drafts remain selectable and local;
Continue This Draft preserves the currently saved/local words and activates a fresh
draft identity. Neither action sends a message. This supplies a normal-quit recovery
path without manual copying or dropping either writer's wording.

Received progress is acknowledged to disk before appearing as durable history.
If storage fails, the owned turn stops and its latest received text is retained in
memory for Retry Saving. Normal quit refuses unacknowledged words. A forced kill
before disk acknowledgement can still lose pending in-memory text. A dead owner or
running record older than four minutes recovers as interrupted; late success is
then refused. Retry appends a linked attempt while retaining original messages
and all earlier replies. Resume is used only after the session identified itself
in an earlier received event.

After 120 seconds without new user feedback, with no running/queued reply or
nonempty draft, feedback becomes an immutable cumulative review packet. Later
steering yields another packet after its idle period. Loading saved history also
resumes packet creation. Packets do not approve facts, change a cut, authorize a
render, or complete a longer editing job.

## Bounds and remaining acceptance

An active document permits 512 messages, turns, packets and retired draft IDs;
it also permits 512 recovered unsent snapshots, each with the same draft bounds.
16 KiB per message/draft; four messages and 64 KiB per prompt; 1 MiB reply text and
8192 events; 12 MiB decoded / 16 MiB encoded history. Streams allow 4 MiB across
8192 lines, with 256 KiB per line. A bound refuses publication and preserves prior
history. Automatic archival/rollover is unfinished. OS/NAS I/O has no hard deadline.

Verification uses synthetic text, fake clients/transports, local process fixtures
and native source typechecking. No actual account check, sign-in, browser, model
request, private media, app launch, microphone, Vision, VoiceOver or foreground
acceptance is claimed. Real event shapes, sign-in, subscription/rate-limit recovery
and responsive native interaction still need separately permitted runtime checks.
Full conversational editing also requires local job/version and clean-user setup
integration. Immutable receipts determine acceptance of each exact source pin.

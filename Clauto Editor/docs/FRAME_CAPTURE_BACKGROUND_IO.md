# Frame capture background IO

The saved-frame verifier checks every compressed presentation timestamp before decoding the exact requested frame. This synchronous AVAssetReader scan now runs on an owned serial Dispatch queue, while Swift tasks await continuations. Reader creation, sample reads and reader cancellation all stay on that queue. The original continuous single-track, 24000/1001 grid, marker-skip, unique/all-frame, exact decoder-time, dimensions and before/after media provenance checks retain their meanings.

Apple documents [copyNextSampleBuffer](https://developer.apple.com/documentation/avfoundation/avassetreaderoutput/copynextsamplebuffer()) as synchronous. The macOS SDK's AVAssetReader header forbids cancelReading concurrently with copyNextSampleBuffer; the implementation therefore never sends cross-thread reader cancellation during a sample call.

A thread-safe job token releases a cancelled Swift waiter exactly once and prevents late work publishing a result. An active or queued job retains its capacity until the queue physically finishes that job, even when its waiter has returned. One job runs at a time; at most64 active/queued jobs are admitted. A saturated queue refuses another capture with an in-app retry message. The owning capture actor can cancel its token while suspended; queued jobs check cancellation before creating a reader, and active jobs check it between reads. The worker then cancels its own reader in defer.

Each job is atomically claimed once before its caller installs cancellation handling. Rejected duplicate calls cannot acquire cancellation ownership or cancel the original waiter. The permanent regression holds the original worker while repeatedly cancelling rejected duplicates. The worker also checks its cancellation token immediately before every synchronous sample read.

A single synchronous OS/NAS read cannot be forcibly interrupted by this design. There is no hard OS I/O deadline, and a cancelled blocked worker continues occupying its slot. The bounded executor prevents cancellation/replacement cycles from spawning unlimited blocked threads. The current verifier still scans the full saved frame grid for each capture; reuse of a verified grid cache is future performance work.

Synthetic validation includes mixed simultaneous exact-frame captures and large stdout/stderr drainage, prompt waiter cancellation while physical work is deliberately held, cancelled queued work, retained saturation, exactly-once results and consumed job refusal. The interrupted parallel people-suite sample and unchanged-baseline negative control remain separate evidence; an earlier serial pass alone did not resolve starvation.

This common increment contains no people implementation, Vision invocation, microphone, model setup, UI launch or private-project changes. Real NAS/GUI/native-product acceptance remains held. Existing first-save, drawing and voice source/artifact receipts remain immutable.

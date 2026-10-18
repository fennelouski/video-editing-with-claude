# Project and workspace recovery

An ordinary Finder launch reopens recent project folders and selects the last
explicitly selected project. The selection binds both its stored project ID and
canonical folder path. Older preferences without a selection use the first
available recent project. Opening or selecting a project while restoration waits
for disk I/O takes precedence over that older restoration. Overlapping window
restorations cannot publish an older result after a newer one.

An automatic fallback does not replace the last explicit project preference.
If that preferred project becomes available again, the next launch selects it.
A newer failed Open retains its own actionable error when older restoration
finishes; restoration does not overwrite that error with a generic notice.

Unavailable folders are not created, removed or silently forgotten. Other
available projects remain usable, and Recents retains disconnected paths for a
later reconnect. A local alias to the same physical project is deduplicated;
different copies sharing a project ID are refused within one app session. No
project contents are rewritten just by restoring the workspace.

The last Brief, Files, Transcript, Cut or Studio tab is retained. Explicit local
launch overrides still work, but are not required for normal restoration. These
preferences contain project identities and navigation only; credentials and
unrelated settings are not changed. Restoration never starts a run, playback,
speech capture or provider request.

Filesystem/core tests exercise unavailable paths, aliases, same-ID copies and
cancellation. Store tests cover the ordinary relaunch path and a user opening
another project during awaited restoration. Exact executed tests and native
acceptance are recorded separately; the source alone does not establish full
product acceptance.

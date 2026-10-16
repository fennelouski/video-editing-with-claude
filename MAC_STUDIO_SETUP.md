# macOS setup

This guide keeps source media, project files, model caches and renders on a mounted
NAS or other external storage volume. Fill in paths and device identifiers for your
own system; this guide contains no machine-specific storage configuration.

## Install the local tools

Install Python 3.12 and FFmpeg from Homebrew, then create the virtual environment and
install the project dependencies:

```sh
brew install ffmpeg python@3.12
python3.12 -m venv .venv
.venv/bin/pip install --upgrade pip
.venv/bin/pip install -r requirements.txt
```

For a pinned Mac environment, install from `requirements-mac-studio.lock.txt` instead.
The less restrictive direct dependency list is `requirements-mac-studio.txt`.
Run `./run` for pipeline commands. The `launch-claude.command` helper checks configured
storage before starting the already-installed Claude Code CLI; it does not install,
authenticate or purchase anything. Install Claude Code from
[Anthropic's official setup guide](https://code.claude.com/docs/en/setup).

## Configure storage

Create an ignored `storage.json` with the verified SMB mount and a dedicated workspace
folder beneath it. `storage.example.json` shows the required fields; replace every sample
value with the paths for your own NAS:

```json
{
  "mount_path": "/Volumes/YourShare",
  "mount_source": "//server/share",
  "destination": "/Volumes/YourShare/VideoEditing"
}
```

The `paths.json` file should place `footage`, `assets`, `build`, and `cuts` under that
workspace. `./run` checks that the share identity and project paths still match before a
pipeline stage creates output. Speech-model caches are placed under the configured
workspace's `Models/` folder. A missing or changed share stops processing; the tools do
not mount it, use credentials, or fall back to local media folders.

Use a separate `CLAUTO_PATHS` manifest for each project when needed. Its paths must stay
within the configured storage workspace. Keep the per-machine manifests private and out
of Git.

## Optional camera-card ingestion

The card importer starts disabled. It copies camera video and associated metadata to the
configured storage destination, hashes source and destination data, verifies copies, and
records a completion receipt. It preserves the card, refuses conflicts, and can resume
only copies that it can identify as its own. It does not erase or eject cards.

Before enabling it, verify the destination and NAS identity, then explicitly enroll the
card's volume UUID in the ignored `canon-ingest.json`. `canon-ingest.example.json` keeps
ingestion disabled and the enrolled-card list empty. Do not enroll arbitrary removable
drives. Keep the local state and LaunchAgent configuration private. The repository's
`canon-ingest.launchagent.example.plist` is a template; replace its path placeholders
before installing it in `~/Library/LaunchAgents`. Do not add NAS credentials to the
configuration or the repository.

An interrupted import is incomplete until its receipt is present. A receipt verifies
the copies against the source inventory at import time; it does not establish that the
NAS is an independent backup.

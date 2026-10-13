# Setup

```sh
git clone https://github.com/fennelouski/video-editing-with-claude
cd video-editing-with-claude
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
./run setup.py
```

`./run setup.py` asks four questions (Enter accepts the suggestion):

| Key | What goes there |
|---|---|
| `footage` | camera files (`a-cam/`, `b-cam/`, `broll/`, `audio/`, `macro/`) |
| `assets` | music, cutouts, textures, foley, LUTs, fonts |
| `build` | generated transcripts, renders, exports (big, safe to delete) |
| `cuts` | per-video scripts, shot lists, FCPXML |

Answers are saved to `paths.json` (per-machine, gitignored), so each computer can keep its files somewhere different. `./run` also starts this on the very first run.

**If you skip it:** the pipeline looks for folders named `footage`, `assets`, `build` and `cuts` in up to three parent directories of the repo, then falls back to folders inside the repo. So cloning the repo *inside* your video folder just works.

**For Claude:** read `paths.json` (or `scripts/config.py`, which resolves it) before looking for any video, audio or asset file. Never copy footage into the repo.

Check it: `./run run_pipeline.py --dry-run` prints the folders it found.

"""Read-only card source -> verified, resumable NAS copies. Live use is opt-in.

No mount, credential, deletion, eject, or network-upload commands are used. The
destination is opened through the verified mount and all writes use directory
descriptors, so an absent/replaced /Volumes mount cannot become a local fallback.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import ctypes
import errno
from dataclasses import dataclass
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys

VIDEO = {".mov", ".mp4", ".mts", ".m2ts", ".mxf", ".avi", ".m4v"}
STILL_PHOTO = {".cr3", ".cr2", ".dng", ".nef", ".arw", ".heic", ".jpg", ".jpeg", ".tif", ".tiff", ".png"}
CAMERA_TREES = {"dcim", "private", "avchd", "misc"}
BLOCK = 1024 * 1024
NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)


class IngestError(RuntimeError):
    pass


@dataclass(frozen=True)
class Mounted:
    source: str
    path: Path
    kind: str


def mounts() -> list[Mounted]:
    result = subprocess.run(["/sbin/mount"], capture_output=True, text=True,
                            check=True, timeout=15)
    rows = []
    for line in result.stdout.splitlines():
        match = re.fullmatch(r"(.+?) on (.+?) \((.+)\)", line)
        if match:
            rows.append(Mounted(match[1], Path(match[2]), match[3].split(",")[0]))
    return rows


def verify_mount(cfg: dict, rows: list[Mounted] | None = None) -> Mounted:
    expected = Path(cfg["mount_path"])
    dest = Path(cfg["destination"])
    if not expected.is_absolute() or not dest.is_relative_to(expected) or dest == expected:
        raise IngestError("Destination must be a dedicated folder below the configured mount")
    if dest.resolve(strict=False) != dest or expected.resolve(strict=False) != expected:
        raise IngestError("Destination/mount may not contain symlinks or '..'")
    hits = [m for m in (mounts() if rows is None else rows)
            if m.path == expected and m.kind == "smbfs" and m.source == cfg["mount_source"]]
    if len(hits) != 1:
        raise IngestError("Expected NAS share is unavailable or has changed; no files copied")
    return hits[0]


def disk_info(path: Path) -> dict:
    proc = subprocess.run(["/usr/sbin/diskutil", "info", "-plist", str(path)],
                          capture_output=True, check=True, timeout=15)
    return plistlib.loads(proc.stdout)


def canon_card(path: Path, info: dict, cfg: dict) -> bool:
    # Enrolment is explicit: labels or DCIM names alone cannot prove the card is Katie's.
    # Built-in SD slots report Internal=True for their reader, while the card is removable.
    sd_slot = info.get("BusProtocol") == "Secure Digital" and info.get("RemovableMedia") is True
    return ((info.get("Internal") is False or sd_slot)
            and (info.get("RemovableMedia") is True or info.get("Ejectable") is True)
            and info.get("VolumeUUID") in cfg.get("approved_card_uuids", [])
            and any(p.is_dir() and not p.is_symlink() and p.name.lower() == "dcim"
                    for p in path.iterdir()))


def digest(stream) -> str:
    h = hashlib.sha256()
    while data := stream.read(BLOCK):
        h.update(data)
    return h.hexdigest()


def fingerprint(path: Path) -> tuple[int, int, str]:
    fd = os.open(path, os.O_RDONLY | NOFOLLOW)
    with os.fdopen(fd, "rb") as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode):
            raise IngestError(f"Not a regular camera file: {path}")
        sha = digest(stream)
        after = os.fstat(stream.fileno())
    if (before.st_size, before.st_mtime_ns, before.st_ino) != (
            after.st_size, after.st_mtime_ns, after.st_ino):
        raise IngestError(f"Source changed while reading: {path}")
    return before.st_size, before.st_mtime_ns, sha


def camera_files(card: Path) -> list[Path]:
    files_to_copy = []
    # AVCHD/PRIVATE/MISC trees keep their complete metadata layout. In DCIM, retain
    # videos, matching still-image sidecars, and metadata; unrelated RAW photos stay on card.
    for tree in sorted(card.iterdir()):
        if tree.name.lower() not in CAMERA_TREES:
            continue
        if tree.is_symlink():
            raise IngestError(f"Camera tree contains a symlink: {tree}")
        if not tree.is_dir():
            continue
        for folder, dirs, files in os.walk(tree, followlinks=False):
            for name in sorted(dirs + files):
                path = Path(folder) / name
                if path.is_symlink():
                    raise IngestError(f"Camera tree contains a symlink: {path}")
            for name in sorted(files):
                path = Path(folder) / name
                if (tree.name.lower() == "dcim" and path.suffix.lower() in STILL_PHOTO
                        and not any((Path(folder) / video).stem == path.stem
                                    and Path(video).suffix.lower() in VIDEO for video in files)):
                    continue
                files_to_copy.append(path)
    return sorted(files_to_copy)


def inventory(card: Path, progress=None) -> list[dict]:
    paths = camera_files(card)
    if not any(p.suffix.lower() in VIDEO for p in paths):
        raise IngestError("No video in camera trees; card preserved without an import")
    items = []
    for index, path in enumerate(paths, 1):
        if progress:
            progress({"phase": "hashing_source", "file": index, "total_files": len(paths)})
        size, mtime, sha = fingerprint(path)
        items.append({"relative": str(path.relative_to(card)), "size": size,
                      "mtime_ns": mtime, "sha256": sha})
    return sorted(items, key=lambda i: i["relative"])


def parts(path: str | Path) -> tuple[str, ...]:
    path = Path(path)
    if path.is_absolute() or not path.parts or any(p in ("..", ".") for p in path.parts):
        raise IngestError(f"Unsafe relative destination: {path}")
    return path.parts


class Target:
    """All destination traversal is anchored to an already verified filesystem."""
    def __init__(self, cfg: dict):
        mounted = verify_mount(cfg)
        self.fd = os.open(mounted.path, os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW)
        # Recheck after opening, then compare device to the pathname. Later writes stay on fd.
        try:
            verify_mount(cfg)
            if os.fstat(self.fd).st_dev != os.stat(mounted.path).st_dev:
                raise IngestError("NAS mount changed while opening it")
            self.prefix = parts(Path(cfg["destination"]).relative_to(mounted.path))
        except BaseException:
            os.close(self.fd)
            raise

    def close(self):
        os.close(self.fd)

    @contextmanager
    def directory(self, relative: Path):
        fd = os.dup(self.fd)
        try:
            for name in self.prefix + (() if relative == Path(".") else parts(relative)):
                try:
                    os.mkdir(name, mode=0o755, dir_fd=fd)
                except FileExistsError:
                    pass
                child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW, dir_fd=fd)
                os.close(fd)
                fd = child
            yield fd
        finally:
            os.close(fd)


def existing_hash(directory: int, name: str) -> tuple[int, str] | None:
    try:
        fd = os.open(name, os.O_RDONLY | NOFOLLOW, dir_fd=directory)
    except FileNotFoundError:
        return None
    with os.fdopen(fd, "rb") as stream:
        s = os.fstat(stream.fileno())
        if not stat.S_ISREG(s.st_mode):
            raise IngestError(f"Destination is not a regular file: {name}")
        return s.st_size, digest(stream)


def exclusive_rename(directory: int, temporary: str, name: str):
    # macOS atomic exclusive rename; os.rename would silently overwrite an existing file.
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renameatx_np
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(directory, os.fsencode(temporary), directory, os.fsencode(name), 4) != 0:
        err = ctypes.get_errno()
        raise OSError(err, os.strerror(err), name)


def ownership_marker(fd: int, value: bytes | None = None) -> bytes:
    """Darwin descriptor xattrs: bind resumable writes to files we exclusively created."""
    libc = ctypes.CDLL(None, use_errno=True)
    name = b"com.fennelouski.canon-ingest.sha256"
    if value is not None:
        fn = libc.fsetxattr
        fn.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t,
                       ctypes.c_uint32, ctypes.c_int]
        fn.restype = ctypes.c_int
        if fn(fd, name, value, len(value), 0, 2) != 0:  # XATTR_CREATE
            err = ctypes.get_errno()
            raise OSError(err, os.strerror(err))
        return value
    fn = libc.fgetxattr
    fn.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t,
                   ctypes.c_uint32, ctypes.c_int]
    fn.restype = ctypes.c_ssize_t
    buf = ctypes.create_string_buffer(64)
    length = fn(fd, name, buf, len(buf), 0, 0)
    if length < 0:
        return b""
    return buf.raw[:length]


def clear_ownership(fd: int):
    libc = ctypes.CDLL(None, use_errno=True)
    fn = libc.fremovexattr
    fn.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
    fn.restype = ctypes.c_int
    if fn(fd, b"com.fennelouski.canon-ingest.sha256", 0) != 0:
        err = ctypes.get_errno()
        raise OSError(err, os.strerror(err))


def publish(directory: int, temporary: str, name: str):
    try:
        exclusive_rename(directory, temporary, name)
        return
    except OSError as exc:
        if exc.errno not in (errno.ENOTSUP, errno.EOPNOTSUPP):
            raise
    # SMB here rejects exclusive rename/hardlinks. O_EXCL still reserves the filename
    # without overwriting anything. Only marked, matching partials may subsequently grow.
    expected = existing_hash(directory, temporary)
    if expected is None:
        raise IngestError("Verified temporary file disappeared before publication")
    with os.fdopen(os.open(temporary, os.O_RDONLY | NOFOLLOW, dir_fd=directory), "rb") as src:
        try:
            fd = os.open(name, os.O_RDWR | os.O_CREAT | os.O_EXCL | NOFOLLOW, 0o600, dir_fd=directory)
            fresh = True
        except FileExistsError:
            fd = os.open(name, os.O_RDWR | NOFOLLOW, dir_fd=directory)
            fresh = False
        with os.fdopen(fd, "r+b") as dst:
            marker = expected[1].encode()
            if fresh:
                ownership_marker(dst.fileno(), marker)
                os.fsync(dst.fileno())
            elif ownership_marker(dst.fileno()) != marker:
                raise FileExistsError(errno.EEXIST, "Existing destination is not our partial", name)
            while data := dst.read(BLOCK):
                if src.read(len(data)) != data:
                    raise IngestError("Owned publication partial is corrupt; preserved for review")
            while data := src.read(BLOCK):
                dst.write(data)
            dst.flush()
            os.fsync(dst.fileno())
    if existing_hash(directory, name) != expected:
        raise IngestError("Published file failed read-back verification")
    fd = os.open(name, os.O_RDONLY | NOFOLLOW, dir_fd=directory)
    try:
        clear_ownership(fd)  # Completed originals may never be treated as resumable partials.
    finally:
        os.close(fd)
    os.unlink(temporary, dir_fd=directory)  # Only our fully verified temporary is removed.


def copy_verified(source: Path, target: Target, relative: Path, item: dict,
                  after_chunk=None) -> str:
    with target.directory(relative.parent) as directory:
        expected = (item["size"], item["sha256"])
        current = existing_hash(directory, relative.name)
        if current == expected:
            return "already_verified"
        if current is not None:
            fd = os.open(relative.name, os.O_RDONLY | NOFOLLOW, dir_fd=directory)
            try:
                ours = ownership_marker(fd) == item["sha256"].encode()
            finally:
                os.close(fd)
            if not ours or current[0] > expected[0]:
                raise IngestError(f"Filename collision/corrupt destination: {relative}; preserved both sources")
        temporary = ".partial-" + item["sha256"] + "-" + relative.name
        fd = os.open(temporary, os.O_RDWR | os.O_CREAT | NOFOLLOW, 0o600, dir_fd=directory)
        with os.fdopen(fd, "r+b") as dest, os.fdopen(os.open(source, os.O_RDONLY | NOFOLLOW), "rb") as src:
            before = os.fstat(src.fileno())
            if (before.st_size, before.st_mtime_ns) != (item["size"], item["mtime_ns"]):
                raise IngestError(f"Source changed before copying: {source}")
            # Verify the entire partial prefix before resuming; never trust size alone.
            while data := dest.read(BLOCK):
                if src.read(len(data)) != data:
                    raise IngestError(f"Partial copy differs from source: {temporary}; preserved for review")
            while data := src.read(BLOCK):
                dest.write(data)
                if after_chunk:
                    dest.flush()
                    after_chunk()
            dest.flush()
            os.fsync(dest.fileno())
            after = os.fstat(src.fileno())
            if (after.st_size, after.st_mtime_ns) != (before.st_size, before.st_mtime_ns):
                raise IngestError(f"Source changed during copying: {source}")
        # Reopen the destination and hash what was stored, rather than the outgoing buffer.
        if existing_hash(directory, temporary) != expected:
            raise IngestError(f"Copy failed SHA-256 verification: {temporary}")
        publish(directory, temporary, relative.name)
        if existing_hash(directory, relative.name) != expected:
            raise IngestError(f"Published copy failed verification: {relative}")
        fd = os.open(relative.name, os.O_RDONLY | NOFOLLOW, dir_fd=directory)
        try:
            os.utime(fd, ns=(before.st_atime_ns, item["mtime_ns"]))
        finally:
            os.close(fd)
        return "copied"


def import_card(card: Path, uuid: str, cfg: dict, after_chunk=None, progress=None) -> dict:
    if not cfg.get("enabled"):
        raise IngestError("Live ingestion is disabled; approve destination and enrol the card first")
    if not re.fullmatch(r"[A-Za-z0-9-]{4,80}", uuid):
        raise IngestError("Card VolumeUUID is missing or unsafe")
    verify_mount(cfg)  # Fail before scanning or creating anything if NAS is unavailable.
    items = inventory(card, progress)
    oldest = min(i["mtime_ns"] for i in items if Path(i["relative"]).suffix.lower() in VIDEO)
    day = datetime.fromtimestamp(oldest / 1e9, timezone.utc).strftime("%Y-%m-%d")
    # This date is a filesystem timestamp estimate, not a claim about camera metadata.
    base = Path("Originals") / day / ("card-" + uuid)
    signature = hashlib.sha256(json.dumps(items, sort_keys=True).encode()).hexdigest()
    target = Target(cfg)
    result = {"card_uuid": uuid, "date": day, "date_basis": "oldest video filesystem mtime (UTC)",
              "copied": 0, "already_verified": 0, "files": []}
    try:
        available = os.fstatvfs(target.fd)
        if sum(i["size"] for i in items) * 2 + cfg.get("reserve_bytes", 0) > available.f_bavail * available.f_frsize:
            raise IngestError("Insufficient NAS free space for verified staging; retry after freeing space")
        # Keep one stable original tree per enrolled card, including when mtimes change.
        # A filename with different bytes stops for review instead of replacing a take.
        with target.directory(Path(".ingest/cards") / uuid) as d:
            if existing_hash(d, "location.json") is None:
                data = (json.dumps({"base": str(base), "date": day}) + "\n").encode()
                tmp = ".partial-location.json"
                try:
                    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW, 0o600, dir_fd=d)
                except FileExistsError:
                    if existing_hash(d, tmp) != (len(data), hashlib.sha256(data).hexdigest()):
                        raise IngestError("Interrupted card location record needs review")
                else:
                    with os.fdopen(fd, "wb") as stream:
                        stream.write(data)
                        stream.flush()
                        os.fsync(stream.fileno())
                publish(d, tmp, "location.json")
            fd = os.open("location.json", os.O_RDONLY | NOFOLLOW, dir_fd=d)
            with os.fdopen(fd) as stream:
                location = json.load(stream)
            base = Path(location["base"])
            if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", location["date"]) or base != Path("Originals") / location["date"] / ("card-" + uuid):
                raise IngestError("Card location record is invalid; original files preserved")
            result["date"] = location["date"]
        for index, item in enumerate(items, 1):
            rel = base / item["relative"]
            if progress:
                progress({"phase": "copying_or_verifying", "file": index,
                          "total_files": len(items), "bytes": item["size"]})
            state = copy_verified(card / item["relative"], target, rel, item, after_chunk)
            result[state] += 1
            result["files"].append({**item, "destination": str(rel)})
        # Inventory must still describe the inserted card before declaring completion.
        if inventory(card, progress) != items:
            raise IngestError("Card contents changed during import; no completion receipt written")
        receipt = {k: v for k, v in result.items() if k not in ("copied", "already_verified")}
        encoded = (json.dumps(receipt, indent=2, sort_keys=True) + "\n").encode()
        with target.directory(Path(".ingest/receipts")) as d:
            name = uuid + "-" + signature + ".json"
            expected = (len(encoded), hashlib.sha256(encoded).hexdigest())
            if existing_hash(d, name) not in (None, expected):
                raise IngestError("Completion receipt collision; existing receipt preserved")
            if existing_hash(d, name) is None:
                tmp = ".partial-" + name
                try:
                    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW, 0o600, dir_fd=d)
                except FileExistsError:
                    if existing_hash(d, tmp) != expected:
                        raise IngestError("Interrupted receipt needs review; footage copies remain verified")
                else:
                    with os.fdopen(fd, "wb") as stream:
                        stream.write(encoded)
                        stream.flush()
                        os.fsync(stream.fileno())
                publish(d, tmp, name)
        return result
    finally:
        target.close()


def scan(cfg: dict) -> int:
    if not cfg.get("enabled"):
        print("Live ingestion disabled; no cards or NAS files touched")
        return 0
    verify_mount(cfg)
    errors = 0
    for mounted in mounts():
        if not str(mounted.path).startswith("/Volumes/") or mounted.kind not in ("exfat", "msdos"):
            continue
        try:
            info = disk_info(mounted.path)
            if canon_card(mounted.path, info, cfg):
                print(json.dumps({"phase": "import_started", "card_uuid": info["VolumeUUID"]}), flush=True)
                print(json.dumps(import_card(mounted.path, info["VolumeUUID"], cfg,
                      progress=lambda event: print(json.dumps(event), flush=True))), flush=True)
        except (OSError, subprocess.SubprocessError, IngestError) as exc:
            print(f"Import deferred for {mounted.path}: {exc}", file=sys.stderr)
            errors += 1
    return 1 if errors else 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--config", type=Path, default=Path(__file__).parents[1] / "canon-ingest.json")
    ap.add_argument("--check", action="store_true", help="read-only NAS identity/space check")
    args = ap.parse_args(argv)
    cfg = json.loads(args.config.read_text())
    if args.check:
        mounted = verify_mount(cfg)
        s = os.statvfs(mounted.path)
        print(json.dumps({"source": mounted.source, "destination": cfg["destination"],
                          "free_bytes": s.f_bavail * s.f_frsize, "enabled": cfg.get("enabled", False)}))
        return 0
    state = Path(cfg["local_state"])
    state.mkdir(parents=True, exist_ok=True)
    # A local flock is released on process exit, including interruption. Never a stale NAS lock.
    with (state / "import.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("Another importer is running; deferred")
            return 0
        return scan(cfg)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (IngestError, OSError, subprocess.SubprocessError, ValueError) as exc:
        print(f"Import deferred: {exc}", file=sys.stderr)
        raise SystemExit(1)

"""Only temporary synthetic cards and a simulated mount are used here."""
import hashlib
import json
import os
from pathlib import Path

import canon_ingest as I
import pytest


@pytest.fixture
def setup(tmp_path, monkeypatch):
    mount = tmp_path / "NAS"
    mount.mkdir()
    cfg = {"enabled": True, "mount_path": str(mount), "mount_source": "//admin@Moab.local/Videos",
           "destination": str(mount / "Katie YouTube"), "approved_card_uuids": ["TEST-CARD"]}
    monkeypatch.setattr(I, "mounts", lambda: [I.Mounted(cfg["mount_source"], mount, "smbfs")])
    card = tmp_path / "EOS_DIGITAL"
    folder = card / "DCIM/100CANON"
    folder.mkdir(parents=True)
    (folder / "MVI_0001.MOV").write_bytes(b"synthetic footage\n" * 160000)
    (folder / "MVI_0001.THM").write_bytes(b"camera sidecar")
    for p in folder.iterdir():
        os.utime(p, (1700000000, 1700000000))
    return card, cfg


def target_file(cfg):
    return next(Path(cfg["destination"]).rglob("MVI_0001.MOV"))


def test_verified_copy_preserves_card_tree_sidecars_and_deduplicates(setup):
    card, cfg = setup
    before = I.inventory(card)
    first = I.import_card(card, "TEST-CARD", cfg)
    assert first["copied"] == 2
    assert first["already_verified"] == 0
    dest = target_file(cfg)
    assert "DCIM/100CANON" in str(dest)
    assert dest.read_bytes() == (card / "DCIM/100CANON/MVI_0001.MOV").read_bytes()
    assert dest.with_suffix(".THM").read_bytes() == b"camera sidecar"
    second = I.import_card(card, "TEST-CARD", cfg)
    assert second["copied"] == 0 and second["already_verified"] == 2
    assert len(list(Path(cfg["destination"]).rglob("*.MOV"))) == 1
    assert len(list((Path(cfg["destination"]) / ".ingest/receipts").glob("*.json"))) == 1
    assert I.inventory(card) == before


def test_unavailable_nas_never_creates_a_local_fallback(setup, monkeypatch):
    card, cfg = setup
    monkeypatch.setattr(I, "mounts", lambda: [])
    with pytest.raises(I.IngestError, match="unavailable"):
        I.import_card(card, "TEST-CARD", cfg)
    assert not Path(cfg["destination"]).exists()


def test_wrong_share_or_local_mount_rejected(setup, monkeypatch):
    card, cfg = setup
    for source, kind in [("//wrong/Videos", "smbfs"), (cfg["mount_source"], "apfs")]:
        monkeypatch.setattr(I, "mounts", lambda: [I.Mounted(source, Path(cfg["mount_path"]), kind)])
        with pytest.raises(I.IngestError):
            I.import_card(card, "TEST-CARD", cfg)
    assert not Path(cfg["destination"]).exists()


def test_interrupted_import_resumes_and_only_then_writes_receipt(setup):
    card, cfg = setup
    before = I.inventory(card)
    def interrupt():
        raise KeyboardInterrupt()
    with pytest.raises(KeyboardInterrupt):
        I.import_card(card, "TEST-CARD", cfg, interrupt)
    assert list(Path(cfg["destination"]).rglob(".partial-*"))
    assert not list((Path(cfg["destination"]) / ".ingest/receipts").glob("*.json"))
    result = I.import_card(card, "TEST-CARD", cfg)
    assert result["copied"] == 2
    assert not list(Path(cfg["destination"]).rglob(".partial-*"))
    assert I.inventory(card) == before


def test_collision_never_overwrites_existing_file(setup):
    card, cfg = setup
    I.import_card(card, "TEST-CARD", cfg)
    dest = target_file(cfg)
    dest.write_bytes(b"existing different footage")
    with pytest.raises(I.IngestError, match="collision"):
        I.import_card(card, "TEST-CARD", cfg)
    assert dest.read_bytes() == b"existing different footage"


def test_final_publish_is_exclusive(tmp_path):
    (tmp_path / "existing.MOV").write_bytes(b"keep")
    (tmp_path / ".partial").write_bytes(b"new")
    fd = os.open(tmp_path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        with pytest.raises(OSError):
            I.publish(fd, ".partial", "existing.MOV")
    finally:
        os.close(fd)
    assert (tmp_path / "existing.MOV").read_bytes() == b"keep"
    assert (tmp_path / ".partial").read_bytes() == b"new"


def test_symlink_in_source_refused(setup, tmp_path):
    card, cfg = setup
    outside = tmp_path / "outside"
    outside.write_bytes(b"private")
    (card / "DCIM/100CANON/link.THM").symlink_to(outside)
    with pytest.raises(I.IngestError, match="symlink"):
        I.import_card(card, "TEST-CARD", cfg)
    assert not Path(cfg["destination"]).exists()


def test_symlink_in_destination_refused(setup, tmp_path):
    card, cfg = setup
    outside = tmp_path / "outside"
    outside.mkdir()
    Path(cfg["destination"]).symlink_to(outside)
    with pytest.raises(I.IngestError, match="symlink"):
        I.import_card(card, "TEST-CARD", cfg)
    assert not list(outside.iterdir())


def test_corrupt_partial_preserved_and_not_published(setup):
    card, cfg = setup
    with pytest.raises(KeyboardInterrupt):
        I.import_card(card, "TEST-CARD", cfg, lambda: (_ for _ in ()).throw(KeyboardInterrupt()))
    partial = next(Path(cfg["destination"]).rglob(".partial-*"))
    partial.write_bytes(b"corrupt")
    with pytest.raises(I.IngestError, match="differs"):
        I.import_card(card, "TEST-CARD", cfg)
    assert partial.read_bytes() == b"corrupt"
    assert not [p for p in Path(cfg["destination"]).rglob("*.MOV") if not p.name.startswith(".")]


def test_only_explicitly_enrolled_external_cards_are_accepted(setup):
    card, cfg = setup
    info = {"Internal": False, "Ejectable": True, "VolumeUUID": "TEST-CARD"}
    assert I.canon_card(card, info, cfg)
    assert not I.canon_card(card, {**info, "VolumeUUID": "OTHER-CARD"}, cfg)
    assert not I.canon_card(card, {**info, "Internal": True}, cfg)
    assert I.canon_card(card, {**info, "Internal": True, "RemovableMedia": True,
                              "BusProtocol": "Secure Digital"}, cfg)
    assert not I.canon_card(card, {**info, "Internal": True, "RemovableMedia": True,
                                  "BusProtocol": "SATA"}, cfg)


def test_disabled_configuration_does_not_scan_or_write(setup, monkeypatch):
    card, cfg = setup
    cfg["enabled"] = False
    monkeypatch.setattr(I, "mounts", lambda: (_ for _ in ()).throw(AssertionError("must not scan")))
    assert I.scan(cfg) == 0
    with pytest.raises(I.IngestError, match="disabled"):
        I.import_card(card, "TEST-CARD", cfg)
    assert not Path(cfg["destination"]).exists()


def test_smb_fallback_and_existing_private_target_are_safe(setup, monkeypatch):
    import errno
    card, cfg = setup
    monkeypatch.setattr(I, "exclusive_rename", lambda *a: (_ for _ in ()).throw(OSError(errno.ENOTSUP, "simulated SMB")))
    first = I.import_card(card, "TEST-CARD", cfg)
    assert first["copied"] == 2
    assert I.import_card(card, "TEST-CARD", cfg)["already_verified"] == 2
    dest = target_file(cfg)
    fd = os.open(dest, os.O_RDONLY)
    try:
        assert I.ownership_marker(fd) == b""
    finally:
        os.close(fd)
    dest.write_bytes(b"preserve unrelated bytes")
    with pytest.raises(I.IngestError, match="collision"):
        I.import_card(card, "TEST-CARD", cfg)
    assert dest.read_bytes() == b"preserve unrelated bytes"


def test_smb_publication_resumes_only_owned_matching_prefix(tmp_path, monkeypatch):
    import errno
    monkeypatch.setattr(I, "exclusive_rename", lambda *a: (_ for _ in ()).throw(OSError(errno.ENOTSUP, "simulated SMB")))
    data = b"synthetic complete contents"
    (tmp_path / ".partial").write_bytes(data)
    fd = os.open(tmp_path, os.O_RDONLY | os.O_DIRECTORY)
    dest = os.open("final", os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=fd)
    try:
        I.ownership_marker(dest, hashlib.sha256(data).hexdigest().encode())
        os.write(dest, data[:7])
    finally:
        os.close(dest)
    try:
        I.publish(fd, ".partial", "final")
    finally:
        os.close(fd)
    assert (tmp_path / "final").read_bytes() == data
    assert not (tmp_path / ".partial").exists()


def test_recording_timestamp_change_does_not_duplicate_originals(setup):
    card, cfg = setup
    first = I.import_card(card, "TEST-CARD", cfg)
    for path in (card / "DCIM/100CANON").iterdir():
        os.utime(path, (1800000000, 1800000000))
    again = I.import_card(card, "TEST-CARD", cfg)
    assert again["copied"] == 0 and again["already_verified"] == 2
    assert again["date"] == first["date"]
    assert len(list(Path(cfg["destination"]).rglob("MVI_0001.MOV"))) == 1


def test_missing_space_does_not_begin_a_copy(setup, monkeypatch):
    card, cfg = setup
    from types import SimpleNamespace
    monkeypatch.setattr(I.os, "fstatvfs", lambda *a: SimpleNamespace(f_bavail=0, f_frsize=1))
    with pytest.raises(I.IngestError, match="free space"):
        I.import_card(card, "TEST-CARD", cfg)
    assert not Path(cfg["destination"]).exists()


def test_video_import_preserves_sidecars_and_avchd_but_skips_unrelated_photos(setup):
    card, cfg = setup
    photos = card / "DCIM/100CANON/IMG_0020.CR3"
    photos.write_bytes(b"unrelated RAW photo")
    (photos.parent / "IMG_0020.JPG").write_bytes(b"unrelated still image")
    (photos.parent / "MVI_0001.JPG").write_bytes(b"video poster sidecar")
    avchd = card / "PRIVATE/AVCHD/BDMV"
    avchd.mkdir(parents=True)
    (avchd / "index.bdm").write_bytes(b"camera metadata")
    (avchd / "thumbnail.JPG").write_bytes(b"AVCHD thumbnail")
    result = I.import_card(card, "TEST-CARD", cfg)
    copied = [f["relative"] for f in result["files"]]
    assert "DCIM/100CANON/IMG_0020.CR3" not in copied
    assert "DCIM/100CANON/IMG_0020.JPG" not in copied
    assert "DCIM/100CANON/MVI_0001.JPG" in copied
    assert "PRIVATE/AVCHD/BDMV/index.bdm" in copied
    assert "PRIVATE/AVCHD/BDMV/thumbnail.JPG" in copied
    assert photos.read_bytes() == b"unrelated RAW photo"

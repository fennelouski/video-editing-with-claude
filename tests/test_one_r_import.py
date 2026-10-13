"""Disposable camera fixtures and simulated NAS only; no private media/device."""
import json
import os
from pathlib import Path
import pytest
import canon_ingest as I
from tools import import_selected_one_r as D


@pytest.fixture
def selected(tmp_path,monkeypatch):
    card=tmp_path/'card';folder=card/'DCIM/Camera01';folder.mkdir(parents=True)
    entries=[]
    for number in range(55,61):
        for role,index in [('VID','00'),('LRV','01')]:
            p=folder/f'{role}_20261006_103912_{index}_{number:03d}.mp4';p.write_bytes(b'x')
            entries.append({'relative':str(p.relative_to(card)),'expected_size':1})
    (card/'DCIM/fileinfo_list.list').write_bytes(b'index');entries.append({'relative':'DCIM/fileinfo_list.list'})
    uuid='TEST-ONE-R-CARD';spec={'card_uuid':uuid,'destination_relative':f'Originals/Insta360/2026-10-06-and-08-reported/card-{uuid}','files':entries}
    manifest=tmp_path/'selection.json';manifest.write_text(json.dumps(spec))
    mount=tmp_path/'NAS';mount.mkdir();cfg={'mount_path':str(mount),'mount_source':'//synthetic/Videos','destination':str(mount/'projects')}
    config=tmp_path/'config.json';config.write_text(json.dumps(cfg))
    evidence_root=tmp_path/'evidence';evidence_root.mkdir();evidence=evidence_root/'attempt'
    monkeypatch.setattr(D,'EVIDENCE_ROOT',evidence_root)
    monkeypatch.setattr(D,'disk_info',lambda path:{'VolumeUUID':uuid,'BusProtocol':'USB','Internal':False,'MountPoint':str(card)})
    monkeypatch.setattr(I,'mounts',lambda:[I.Mounted(cfg['mount_source'],mount,'smbfs')])
    monkeypatch.setattr('sys.argv',['import',str(card),str(manifest),str(config),str(evidence)])
    return card,folder,evidence,manifest,config,cfg


def test_complete_driver_readback_receipt_and_source_preservation(selected):
    card,folder,evidence,manifest,config,cfg=selected
    before={str(p.relative_to(card)):p.read_bytes() for p in card.rglob('*') if p.is_file()}
    D.main();result=json.loads((evidence/'result.json').read_text())
    assert result['all_readback_hashes_verified'] and result['copied']==13
    assert all(x['readback_sha256_verified'] for x in result['files'])
    assert {str(p.relative_to(card)):p.read_bytes() for p in card.rglob('*') if p.is_file()}==before
    receipt=(evidence/'receipt.json').read_bytes()
    with pytest.raises(FileExistsError):D.main()
    assert (evidence/'receipt.json').read_bytes()==receipt


def test_source_ancestor_alias_is_refused(selected,tmp_path):
    card,folder,*_=selected
    outside=tmp_path/'outside';folder.rename(outside);folder.symlink_to(outside)
    with pytest.raises(I.IngestError,match='aliased'):D.main()


def test_evidence_cannot_write_to_card(selected,monkeypatch):
    card,folder,evidence,manifest,config,cfg=selected
    monkeypatch.setattr('sys.argv',['import',str(card),str(manifest),str(config),str(card/'evidence')])
    with pytest.raises(I.IngestError,match='Evidence'):D.main()
    assert not (card/'evidence').exists()


def test_file_changed_after_preflight_cannot_bypass_manifest_size(selected,monkeypatch):
    card,folder,evidence,manifest,config,cfg=selected
    original=D.fingerprint;changed=[False]
    def mutate(path,**kwargs):
        if not changed[0]:path.write_bytes(b'xx');changed[0]=True
        return original(path,**kwargs)
    monkeypatch.setattr(D,'fingerprint',mutate)
    with pytest.raises(I.IngestError,match='changed since'):D.main()
    assert not (evidence/'receipt.json').exists()


def test_descriptor_remains_on_approved_file_after_parent_path_swap(selected,tmp_path):
    card,folder,*_=selected;rel=Path('DCIM/Camera01')/next(folder.iterdir()).name
    with D.open_source(card,rel) as descriptor:
        folder.rename(card/'DCIM/OriginalCamera01')
        outside=tmp_path/'outside';outside.mkdir();(outside/rel.name).write_bytes(b'outside')
        folder.symlink_to(outside)
        assert I.fingerprint(card/rel,source_descriptor=descriptor)[0]==1
    with pytest.raises(OSError):
        with D.open_source(card,rel):pass

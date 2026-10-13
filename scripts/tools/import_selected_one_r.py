"""Copy an explicitly selected ONE R set to a new NAS archive with read-back SHA.

Uses the reviewed descriptor-anchored importer. No camera writes, mounts, ejects,
credentials, enrollment, overwrites, or imports beyond the exact manifest occur.
"""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import time

sys.path.insert(0,str(Path(__file__).resolve().parent.parent))
from canon_ingest import Target, copy_verified, fingerprint, disk_info, verify_mount, IngestError

EVIDENCE_ROOT=Path(__file__).resolve().parents[2]/'.artifacts'

def source_identity(card,uuid):
    info=disk_info(card)
    if info.get('VolumeUUID')!=uuid or info.get('BusProtocol')!='USB' or info.get('Internal') is not False or info.get('MountPoint')!=str(card):
        raise IngestError('The selected ONE R source volume does not match the verified card.')
    for path in [card,card/'DCIM',card/'DCIM/Camera01']:
        if path.is_symlink() or not path.is_dir():raise IngestError('Camera folder unavailable or aliased.')


@contextmanager
def open_source(card, relative):
    # Every directory and file open is descriptor-relative and NOFOLLOW. A path
    # swap after inspection cannot redirect a read outside the verified card.
    relative=Path(relative)
    if relative.parent not in [Path('DCIM/Camera01'),Path('DCIM')] or relative.is_absolute() or '..' in relative.parts:
        raise IngestError('Unexpected camera source location.')
    descriptors=[]
    try:
        descriptors.append(os.open(card,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW))
        for part in relative.parts[:-1]:
            descriptors.append(os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=descriptors[-1]))
        descriptors.append(os.open(relative.name,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=descriptors[-1]))
        if not stat.S_ISREG(os.fstat(descriptors[-1]).st_mode):raise IngestError('Source must be a regular camera file.')
        yield descriptors[-1]
    finally:
        for descriptor in reversed(descriptors):os.close(descriptor)


def create_evidence(path, card):
    allowed=EVIDENCE_ROOT
    path=path.absolute()
    if path.parent!=allowed or path.resolve(strict=False)!=path or path.is_relative_to(card.resolve()):
        raise IngestError('Evidence must be a new direct folder under this checkout .artifacts, outside the card.')
    path.mkdir(exist_ok=False)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('card',type=Path);ap.add_argument('manifest',type=Path);ap.add_argument('nas_config',type=Path)
    ap.add_argument('local_evidence',type=Path)
    args=ap.parse_args();spec=json.loads(args.manifest.read_text());cfg=json.loads(args.nas_config.read_text())
    uuid=spec['card_uuid'];base=Path(spec['destination_relative']);entries=spec['files']
    if not re.fullmatch(r'[A-Za-z0-9-]{4,80}',uuid) or base!=Path('Originals/Insta360/2026-10-06-and-08-reported')/('card-'+uuid):
        raise IngestError('Invalid explicit archive identity.')
    relatives=[Path(e['relative']) for e in entries]
    if len(relatives)!=13 or len(set(relatives))!=13 or any(p.is_absolute() or '..' in p.parts for p in relatives):
        raise IngestError('Exactly six main takes, six previews and one metadata index required.')
    if sum(p.name.startswith('VID_202610') for p in relatives)!=6 or sum(p.name.startswith('LRV_202610') for p in relatives)!=6:
        raise IngestError('Unexpected source roles.')
    allowed=r'(?:VID|LRV)_202610(?:06|08)_\d{6}_\d{2}_0(?:55|56|57|58|59|60)\.mp4'
    if any(not (p.parent==Path('DCIM/Camera01') and re.fullmatch(allowed,p.name)) and str(p)!='DCIM/fileinfo_list.list' for p in relatives):
        raise IngestError('The manifest includes a take outside the authorized missing set.')
    for role in ['VID','LRV']:
        if {p.stem[-3:] for p in relatives if p.name.startswith(role)}!={'055','056','057','058','059','060'}:
            raise IngestError('Every authorized take needs exactly one main file and preview.')
    source_identity(args.card,uuid);verify_mount(cfg)
    for item in entries:
        with open_source(args.card,item['relative']) as descriptor:
            item['preflight_size']=os.fstat(descriptor).st_size
            if item.get('expected_size') is not None and item['preflight_size']!=item['expected_size']:
                raise IngestError('A selected camera file is missing, changed or aliased.')
    create_evidence(args.local_evidence,args.card)
    with (args.local_evidence/'import.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        target=Target(cfg)
        try:
            free=os.fstatvfs(target.fd)
            required=sum(item['preflight_size'] for item in entries)*2+cfg.get('reserve_bytes',0)
            if required>free.f_bavail*free.f_frsize:raise IngestError('Insufficient NAS space for safe staging.')
            result={'card_uuid':uuid,'selection':'Six earlier ONE R main takes and paired previews; camera clock dates retained, not asserted shoot dates',
                'copied':0,'already_verified':0,'files':[],'source_read_only':True,'all_readback_hashes_verified':False,'october9_not_copied':True}
            for index,item in enumerate(entries,1):
                source_identity(args.card,uuid)
                source=args.card/item['relative']
                print(json.dumps({'phase':'hash_source','file':index,'total':len(entries),'name':source.name,'bytes':item['preflight_size']}),flush=True)
                with open_source(args.card,item['relative']) as descriptor:
                    size,mtime,sha=fingerprint(source,source_descriptor=descriptor)
                    if item.get('expected_size') is not None and size!=item['expected_size']:
                        raise IngestError('A source changed since the explicit selection; no copy accepted.')
                    record={'relative':item['relative'],'size':size,'mtime_ns':mtime,'sha256':sha}
                    destination=base/item['relative']
                    print(json.dumps({'phase':'copy_and_readback_verify','file':index,'total':len(entries),'name':source.name}),flush=True)
                    last=[0.0]
                    def progress():
                        now=time.monotonic()
                        if now-last[0]>=15:
                            last[0]=now
                            print(json.dumps({'phase':'copying','file':index,'name':source.name}),flush=True)
                    status=copy_verified(source,target,destination,record,after_chunk=progress,source_descriptor=descriptor)
                result[status]+=1;result['files'].append({**record,'destination':str(destination),'readback_sha256_verified':True})
                (args.local_evidence/'checkpoint.json').write_text(json.dumps(result,indent=2))
                print(json.dumps({'phase':'file_verified','file':index,'name':source.name,'status':status,'bytes':size}),flush=True)
            source_identity(args.card,uuid)
            for record in result['files']:
                with open_source(args.card,record['relative']) as descriptor:s=os.fstat(descriptor)
                if (s.st_size,s.st_mtime_ns)!=(record['size'],record['mtime_ns']):raise IngestError('A source changed; completion receipt withheld.')
            result['all_readback_hashes_verified']=True;result['bytes']=sum(r['size'] for r in result['files'])
            encoded=(json.dumps(result,sort_keys=True,indent=2)+'\n').encode();receipt=args.local_evidence/'receipt.json'
            with receipt.open('xb') as stream:stream.write(encoded)
            rel=Path('.ingest/receipts')/('insta360-earlier-'+uuid+'-'+hashlib.sha256(encoded).hexdigest()+'.json')
            size,mtime,sha=fingerprint(receipt)
            copy_verified(receipt,target,rel,{'size':size,'mtime_ns':mtime,'sha256':sha})
            result['receipt']=str(Path(cfg['destination'])/rel);result['nas_originals']=str(Path(cfg['destination'])/base)
            (args.local_evidence/'result.json').write_text(json.dumps(result,indent=2))
            print(json.dumps({k:v for k,v in result.items() if k!='files'}),flush=True)
        finally:target.close()


if __name__=='__main__':main()

"""Opt-in, bounded Ogg-to-PCM cache. No playback, downloads or library writes.

The caller must supply catalog-verified original bytes and license authority.
This low-level adapter does not grant license approval or editor availability.
"""
from pathlib import Path
import fcntl
import io
import math
import os
import re
import stat
import subprocess
import uuid
import wave
import sound_timeline_adapter as A

MAX_INPUT=64*1024*1024
MAX_PCM=128*1024*1024
REVISION='ogg-pcm16-v1'

def pcm_info(data):
    with wave.open(io.BytesIO(data),'rb') as w:
        channels,rate,frames,width=w.getnchannels(),w.getframerate(),w.getnframes(),w.getsampwidth()
        if width!=2 or not 1<=channels<=8 or not 8000<=rate<=192000 or frames<=0:
            raise ValueError('Unsupported decoded PCM layout')
        if len(w.readframes(frames))!=frames*channels*width:
            raise ValueError('Incomplete decoded PCM')
        return dict(channels=channels,sampleRate=rate,frames=frames,duration=frames/rate)

def decode(original,*,asset_id,expected_sha256,duration,sample_rate,channels,cache_root,decoder,cancel_check=lambda:None):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}',asset_id):raise ValueError('Invalid stable asset ID')
    if not re.fullmatch(r'[0-9a-f]{64}',expected_sha256) or not 0<len(original)<=MAX_INPUT or A.sha(original)!=expected_sha256:
        raise ValueError('Original audio hash or size mismatch')
    if original[:4]!=b'OggS':raise ValueError('Expected original Ogg bytes')
    if type(duration) not in (int,float) or not math.isfinite(duration) or not 0<duration<=3600 or type(sample_rate) is not int or not 8000<=sample_rate<=192000 or type(channels) is not int or not 1<=channels<=8:
        raise ValueError('Invalid expected audio bounds')
    if (duration+.1)*sample_rate*channels*2>MAX_PCM-4096:raise ValueError('Decoded audio exceeds cache budget')
    decoder=Path(decoder)
    if not decoder.is_absolute() or not decoder.is_file() or not os.access(decoder,os.X_OK):raise ValueError('Choose an installed local decoder')
    def decoder_fingerprint():
        if decoder.stat().st_size>128*1024*1024:raise ValueError('Decoder executable exceeds budget')
        version=subprocess.run([str(decoder),'-version'],check=True,capture_output=True,timeout=5).stdout
        return A.sha(decoder.read_bytes()+version)
    cancel_check();fingerprint=decoder_fingerprint()
    identity=dict(revision=REVISION,assetID=asset_id,originalSHA256=expected_sha256,decoderSHA256=fingerprint,expectedDuration=duration,sampleRate=sample_rate,channels=channels)
    key=A.sha(A.encode(identity));root=A.Directory(cache_root);lock=None;stage=None;stage_name=None;published=False
    try:
        lock=os.open('decode.lock',os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600,dir_fd=root.fd)
        if not stat.S_ISREG(os.fstat(lock).st_mode):raise ValueError('Invalid cache lock')
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB);root.check()
        def read_entry(folder):
            receipt=A.strict(folder.read('receipt.json',65536));data=folder.read('decoded.wav',MAX_PCM)
            info=pcm_info(data)
            if receipt.get('identity')!=identity or receipt.get('decodedSHA256')!=A.sha(data) or receipt.get('pcm')!=info:
                raise ValueError('Decoded cache changed; remove the damaged entry explicitly')
            if info['sampleRate']!=sample_rate or info['channels']!=channels or abs(info['duration']-duration)>.01:
                raise ValueError('Decoded audio differs from catalog bounds')
            root.check();folder.check();return data,receipt
        try:entry=root.child(key)
        except FileNotFoundError:entry=None
        if entry:
            try:return read_entry(entry)
            finally:entry.close()
        stage_name='pending-'+str(uuid.uuid4());stage=root.child(stage_name,create=True)
        stage.write_new('original.ogg',original);cancel_check()
        subprocess.run([str(decoder),'-nostdin','-v','error','-protocol_whitelist','file,pipe','-threads','1','-f','ogg','-i',str(stage.path/'original.ogg'),'-map','0:a:0','-vn','-sn','-dn','-t',str(duration+.1),'-fs',str(MAX_PCM),'-threads','1','-c:a','pcm_s16le','-f','wav','-n',str(stage.path/'decoded.wav')],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,timeout=30)
        cancel_check()
        if decoder_fingerprint()!=fingerprint:raise ValueError('Decoder changed during conversion')
        root.check();stage.check();data=stage.read('decoded.wav',MAX_PCM);info=pcm_info(data)
        if info['sampleRate']!=sample_rate or info['channels']!=channels or abs(info['duration']-duration)>.01:
            raise ValueError('Decoded audio differs from catalog bounds')
        receipt=dict(identity=identity,decodedSHA256=A.sha(data),pcm=info,humanAudition='NOT_AUDITIONED')
        stage.write_new('receipt.json',A.encode(receipt));os.unlink('original.ogg',dir_fd=stage.fd)
        cancel_check();root.check();stage.check();os.rename(stage_name,key,src_dir_fd=root.fd,dst_dir_fd=root.fd);published=True
        entry=root.child(key)
        try:return read_entry(entry)
        finally:entry.close()
    finally:
        if stage:
            if not published:
                for name in ['original.ogg','decoded.wav','receipt.json']:
                    try:os.unlink(name,dir_fd=stage.fd)
                    except FileNotFoundError:pass
                try:os.rmdir(stage_name,dir_fd=root.fd)
                except FileNotFoundError:pass
            stage.close()
        if lock is not None:os.close(lock)
        root.close()


def decode_catalog_asset(*,library_root,asset_id,cache_root,decoder):
    """Public adapter: only pinned catalog/package/license inputs can reach decode."""
    raw=(A.RESOURCES/'catalog.json').read_bytes();compat=(A.RESOURCES/'package-compatibility.json').read_bytes()
    if A.sha(raw)!=A.CATALOG_SHA or A.sha(compat)!=A.COMPATIBILITY_SHA:raise ValueError('Pinned sound release changed')
    catalog,compatibility=A.strict(raw),A.strict(compat)
    for evidence in catalog['licenseRecords']:
        if A.sha((A.RESOURCES/evidence['path']).read_bytes())!=evidence['sha256']:raise ValueError('License evidence changed')
    asset=next((a for a in catalog['assets'] if a['id']==asset_id),None)
    if not asset or asset['format']!='ogg' or asset['license']!='CC0-1.0' or not asset['redistributionAllowed']:
        raise ValueError('Choose a supported CC0 Ogg catalog asset')
    source=A.Directory(library_root)
    try:
        subset=source.read('asset-library.json');package=next((p for p in compatibility['packages'] if p['package_manifest_sha256']==A.sha(subset)),None)
        rows=A.strict(subset)['assets']
        if not package or len(rows)!=package['asset_count'] or not any(a['asset_id']==asset_id and a['sha256']==asset['sha256'] and a['file_path']==asset['relativePath'] for a in rows):
            raise ValueError('Unpinned package or asset membership')
        original=source.read(asset['relativePath'],asset['bytes']);source.check()
        if len(original)!=asset['bytes']:raise ValueError('Original audio size mismatch')
        _,receipt=decode(original,asset_id=asset_id,expected_sha256=asset['sha256'],duration=asset['duration'],sample_rate=asset['sampleRate'],channels=asset['channels'],cache_root=cache_root,decoder=decoder)
        source.check()
        return dict(reference=dict(schemaVersion=1,libraryID=catalog['libraryID'],libraryVersion=catalog['version'],assetID=asset_id,assetURI='sfx://asset/'+asset_id,expectedSHA256=asset['sha256'],license=asset['license'],sourceDurationSeconds=asset['duration'],auditionStatus=asset['auditionStatus']),cacheKey=A.sha(A.encode(receipt['identity'])),decodedCacheReceipt=receipt,receiptSHA256=A.sha(A.encode(receipt)))
    finally:source.close()

if __name__=='__main__':
    import argparse,json
    parser=argparse.ArgumentParser(description='Explicit local Ogg cache preparation; never plays or downloads audio')
    parser.add_argument('--library-root',type=Path,required=True)
    parser.add_argument('--asset-id',required=True)
    parser.add_argument('--cache-root',type=Path,required=True)
    parser.add_argument('--decoder',type=Path,required=True)
    args=parser.parse_args()
    try:
        result=decode_catalog_asset(library_root=args.library_root,asset_id=args.asset_id,cache_root=args.cache_root,decoder=args.decoder)
        print(json.dumps(dict(state='complete',**result),sort_keys=True))
    except (ValueError,OSError,subprocess.SubprocessError,wave.Error) as exc:
        print(json.dumps(dict(state='failed',detail=str(exc)),sort_keys=True))
        raise SystemExit(1)

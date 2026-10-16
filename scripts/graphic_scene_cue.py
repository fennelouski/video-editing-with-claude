"""Verified local generated-scene selections for saved-cut composition.

Reads only bounded, descriptor-pinned regular files. It never invokes a model,
installs a font, changes a parent cut, or treats generated pixels as scanned art.
"""
from __future__ import annotations
from dataclasses import dataclass
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
from uuid import UUID

MOVIE_LIMIT = 16 * 1024**3
INPUT_LIMIT = 384 * 1024**2
LABELS = {
    'particles': '2D fixed-step toy physics · ideal disks, no air resistance',
    'molecule': 'Typed molecular diagram · geometry and chemistry need human review',
    'atom': 'Illustrative orbit diagram · not a quantum simulation',
    'reaction': 'Atom-balanced typed reaction · no kinetics or safety inference',
    'object': 'Projected triangle mesh · illustrative lighting',
    'market': 'Illustrative linear market · supplied assumptions, not a forecast',
}


def strict_json(data: bytes | str):
    def pairs(items):
        value = {}
        for key, item in items:
            if key in value: raise ValueError('Duplicate graphic metadata key.')
            value[key] = item
        return value
    def constant(_): raise ValueError('Nonfinite graphic metadata.')
    return json.loads(data, object_pairs_hook=pairs, parse_constant=constant)


def valid_sha(value):
    return isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value) is not None


def valid_id(value):
    try: return isinstance(value, str) and str(UUID(value)).upper() == value.upper()
    except (ValueError, TypeError, AttributeError): return False


def fingerprint(folder: Path, leaf: str, limit: int, *, capture=False):
    if not isinstance(leaf,str) or not re.fullmatch('[A-Za-z0-9_.-]{1,100}',leaf) or leaf in ('.','..'):
        raise ValueError('Invalid graphic artifact leaf.')
    canonical = folder.resolve(strict=True)
    directory = os.open(canonical, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        physical = os.fstat(directory)
        fd = os.open(leaf, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory)
        try:
            before = os.fstat(fd)
            def signature(info): return (info.st_dev,info.st_ino,info.st_size,info.st_mtime_ns,info.st_ctime_ns)
            if not stat.S_ISREG(before.st_mode) or not 0 < before.st_size <= limit:
                raise ValueError('Graphic artifact exceeds its regular-file budget.')
            digest, count, chunks = hashlib.sha256(), 0, []
            while True:
                block = os.read(fd, min(1024**2, limit-count+1))
                if not block: break
                count += len(block)
                if count > limit: raise ValueError('Graphic artifact grew beyond its budget.')
                digest.update(block)
                if capture: chunks.append(block)
            current = os.stat(leaf, dir_fd=directory, follow_symlinks=False)
            parent = folder.resolve(strict=True).stat()
            if signature(os.fstat(fd)) != signature(before) or signature(current) != signature(before) or count != before.st_size or (parent.st_dev,parent.st_ino) != (physical.st_dev,physical.st_ino):
                raise ValueError('Graphic artifact changed during verification.')
            return {'sha256':digest.hexdigest(),'byteCount':count}, b''.join(chunks) if capture else None
        finally: os.close(fd)
    finally: os.close(directory)


@dataclass(frozen=True)
class GraphicCue:
    revision: Path
    request: dict

    def inspect(self, cut_duration: float):
        r = self.request
        fields = {'projectID','sceneID','revisionID','manifestSHA256','movieSHA256','at','sourceStart','duration','scale','x','y'}
        if not isinstance(r,dict) or set(r) != fields or not all(valid_id(r[k]) for k in ('projectID','sceneID','revisionID')) or not all(valid_sha(r[k]) for k in ('manifestSHA256','movieSHA256')):
            raise ValueError('Select an exported project graphic revision.')
        if any(isinstance(r[k],bool) or not isinstance(r[k],(int,float)) or not math.isfinite(r[k]) for k in ('at','sourceStart','duration','scale','x','y')):
            raise ValueError('Graphic timing and framing must be finite numbers.')
        if not (0 <= r['at'] < cut_duration and r['sourceStart'] >= 0 and r['duration'] > 0 and r['at']+r['duration'] <= cut_duration+1e-8 and .1 <= r['scale'] <= 4 and abs(r['x']) <= 100 and abs(r['y']) <= 100):
            raise ValueError('Keep the graphic range inside this export and use supported framing.')
        if self.revision.name != 'revision.json': raise ValueError('Choose the exact generated-scene revision manifest.')
        folder = self.revision.parent
        record, raw = fingerprint(folder,'revision.json',65536,capture=True)
        if record['sha256'] != r['manifestSHA256']: raise ValueError('The graphic revision changed after selection.')
        manifest = strict_json(raw)
        if manifest.get('schemaVersion') != 1 or any(str(manifest.get(k,'')).upper() != r[q].upper() for k,q in (('projectID','projectID'),('sceneID','sceneID'),('id','revisionID'))):
            raise ValueError('The graphic belongs to a different scene or project.')
        files = manifest.get('files')
        required = {'scene.json','animation.mov','annotation-font.ttf','annotation-OFL.txt','decode-proof.json','frame-first.png','frame-last.png','timeline.fcpxml'}
        if not isinstance(files,dict) or not required <= files.keys() or len(files)>100:
            raise ValueError('The graphic revision is incomplete.')
        source_hashes, consumed = {str(self.revision.resolve()):record['sha256']}, 0
        for leaf, expected in files.items():
            if not isinstance(expected,dict) or set(expected) != {'sha256','byteCount'} or not valid_sha(expected['sha256']) or isinstance(expected['byteCount'],bool) or not isinstance(expected['byteCount'],int) or expected['byteCount'] <= 0:
                raise ValueError('Invalid graphic artifact record.')
            limit = MOVIE_LIMIT if leaf=='animation.mov' else 256*1024**2
            if leaf != 'animation.mov':
                consumed += expected['byteCount']
                if consumed > INPUT_LIMIT: raise ValueError('Graphic revision input budget exceeded.')
            if expected['byteCount'] > limit: raise ValueError('Graphic artifact budget exceeded.')
            actual,_ = fingerprint(folder,leaf,expected['byteCount'])
            if actual != expected: raise ValueError('An immutable graphic artifact changed.')
            source_hashes[str((folder/leaf).resolve())] = actual['sha256']
        _, scene_raw = fingerprint(folder,'scene.json',1024**2,capture=True)
        scene = strict_json(scene_raw)
        if any(str(scene.get(k,'')).upper() != r[q].upper() for k,q in (('projectID','projectID'),('id','sceneID'))) or manifest.get('draftSHA256') != files['scene.json']['sha256']:
            raise ValueError('The graphic input does not match its captured scene.')
        model, proof = scene.get('scene',{}), manifest.get('proof',{})
        width,height,frames = (model.get(k) for k in ('width','height','frameCount'))
        if any(isinstance(v,bool) or not isinstance(v,int) for v in (width,height,frames)) or not (320<=width<=7680 and 240<=height<=7680 and width*height<=8_388_608 and 1<=frames<=2880):
            raise ValueError('Unsupported generated-scene canvas or frame count.')
        assumptions = model.get('assumptions')
        if not isinstance(assumptions,list) or len(assumptions)>32 or any(not isinstance(a,dict) or not valid_id(a.get('id')) or not isinstance(a.get('text'),str) or not 0<len(a['text'].encode())<=2048 for a in assumptions):
            raise ValueError('Invalid declared graphic assumptions.')
        if model.get('kind') not in LABELS or manifest.get('validationLabel') != LABELS[model['kind']] or manifest.get('assumptions') != [a['text'] for a in assumptions] or not isinstance(manifest.get('rendererVersion'),str) or not valid_sha(manifest.get('metalShaderSHA256')):
            raise ValueError('The graphic scientific classification or renderer provenance is missing.')
        integers = ('width','height','frameCount','durationValue','durationScale','maximumEndpointAlphaError')
        if any(type(proof.get(k)) is not int for k in integers) or proof.get('movie') != files['animation.mov'] or files['animation.mov']['sha256'] != r['movieSHA256'] or proof.get('decodedEveryFrame') is not True or proof.get('codec') != 'ap4h' or any(proof.get(k)!=v for k,v in (('width',width),('height',height),('frameCount',frames),('durationValue',frames*1001),('durationScale',24000))) or not 0<=proof['maximumEndpointAlphaError']<=2:
            raise ValueError('The graphic lacks its exact encoded frame/alpha proof.')
        _, proof_raw = fingerprint(folder,'decode-proof.json',65536,capture=True)
        if strict_json(proof_raw) != proof: raise ValueError('The captured graphic decode proof changed.')
        source_duration = frames*1001/24000
        if r['sourceStart']+r['duration'] > source_duration+1e-8:
            raise ValueError('The graphic range exceeds its exported animation; it cannot be held or padded.')
        at, start, count, cut_count = (round(v*(24000/1001)) for v in (r['at'],r['sourceStart'],r['duration'],cut_duration))
        if count<=0 or at+count>cut_count or start+count>frames:
            raise ValueError('The graphic range must fit both movies on their exact frame grid.')
        placement = {'at':at*1001/24000,'source_start':start*1001/24000,'duration':count*1001/24000,'scale':r['scale'],'x':r['x'],'y':r['y']}
        return folder.resolve(strict=True)/'animation.mov', {'request':r,'source_dimensions':[width,height],'source_frame_count':frames,'placement':placement,'revision_path':str(self.revision.resolve()),'renderer_version':manifest['rendererVersion'],'metal_shader_sha256':manifest['metalShaderSHA256'],'validation_label':manifest['validationLabel'],'assumptions':manifest['assumptions'],'source_sha256':source_hashes}, raw, scene_raw

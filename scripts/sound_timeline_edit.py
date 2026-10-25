"""Bounded proof for a native sound edit consumed by normal derivative export."""
from __future__ import annotations
from dataclasses import dataclass
from pathlib import Path
import sys
from urllib.parse import urlparse, unquote
from xml.etree import ElementTree as ET

def xml(data):
    text=data.decode('utf-8')
    if '<!ENTITY' in text.upper() or 'SYSTEM' in text.split('<fcpxml',1)[0].upper() or 'PUBLIC' in text.split('<fcpxml',1)[0].upper(): raise ValueError('External timeline declarations are unsupported')
    return ET.fromstring(data)

def node(root,key):
    values=key.split(':')
    if len(values)!=2 or not all(x.isdecimal() for x in values): raise ValueError('Invalid cue path')
    spine=root.find('./library/event/project/sequence/spine')
    try:return list(list(spine)[int(values[0])])[int(values[1])]
    except (IndexError,TypeError):raise ValueError('Selected cue no longer exists')

def canonical(element):
    text=element.text or '';tail=element.tail or ''
    return (element.tag,tuple(sorted(element.attrib.items())),text if text.strip() else '',tuple(canonical(c) for c in element),tail if tail.strip() else '')

@dataclass(frozen=True)
class SoundTimelineEdit:
    manifest: Path
    parent: Path
    selection: dict
    def inspect(self,timeline):
        # Ordinary exports retain their existing installation requirements.
        # This optional adapter needs the matching, metadata-only sound package.
        sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'SoundBrowser/Integration'))
        try:import sound_timeline_adapter as A
        except ImportError as exc:raise ValueError('Install the matching Clauto sound metadata integration before exporting a sound edit') from exc
        s=self.selection
        if s.get('schemaVersion')!=1:raise ValueError('Unsupported sound-edit selection')
        folder=A.Directory(self.manifest.parent)
        try:
            if folder.path.name.lower()!=s['editID'].lower() or folder.path.parent.name!='derivatives' or folder.path.parent.parent.name!='build':raise ValueError('Sound edit is outside its owned derivative folder')
            project=A.Directory(folder.path.parent.parent.parent)
            try:
                manifest=A.strict(project.read('clauto-project.json'))
                relative=Path(self.parent).resolve().relative_to(project.path).as_posix()
                pieces=A.parts(relative)
                if len(pieces)!=4 or pieces[0]!='cuts' or pieces[2]!='exports' or manifest['id'].lower()!=s['projectID'].lower():raise ValueError('Sound edit project ownership mismatch')
                version=A.strict(project.read('/'.join(pieces[:2]+['clauto-version.json'])))
                if version['id'].lower()!=s['parentVersionID'].lower():raise ValueError('Sound edit saved-version ownership mismatch')
                original=project.read(relative,8*1024*1024);project.check()
            finally:project.close()
            raw=folder.read('sound-timeline-edit.json',2*1024*1024)
            edited=folder.read('timeline.fcpxml',8*1024*1024)
            if Path(timeline).resolve()!=folder.path/'timeline.fcpxml' or A.sha(raw)!=s['manifestSHA256'] or A.sha(edited)!=s['timelineSHA256']:raise ValueError('Sound edit or receipt changed')
            receipt=A.strict(raw)
            for key in ['projectID','parentVersionID','parentTimelineSHA256','timelineSHA256']:
                if receipt[key]!=s[key]:raise ValueError('Sound edit belongs to another saved source')
            if A.sha(original)!=s['parentTimelineSHA256']:raise ValueError('Original saved parent changed')
            catalog_bytes=(A.RESOURCES/'catalog.json').read_bytes()
            if A.sha(catalog_bytes)!=A.CATALOG_SHA:raise ValueError('Pinned sound catalog changed')
            catalog=A.strict(catalog_bytes);assets={a['id']:a for a in catalog['assets']}
            for record in catalog['licenseRecords']:
                if A.sha((A.RESOURCES/record['path']).read_bytes())!=record['sha256']:raise ValueError('Pinned sound license evidence changed')
            refs=receipt['references']
            if not isinstance(refs,dict) or not 0<len(refs)<=100:raise ValueError('Invalid replacement reference count')
            before,after=xml(original),xml(edited);resources=after.find('resources');old_ids={a.get('id') for a in before.findall('resources/asset')}
            actual_assets=after.findall('resources/asset');new_ids=[a.get('id') for a in actual_assets]
            if len(set(new_ids))!=len(new_ids):raise ValueError('Duplicate sound resource ID')
            hashes={};budget=0
            for key,ref in refs.items():
                asset=assets.get(ref['assetID'])
                if not asset or any(ref.get(k)!=v for k,v in dict(schemaVersion=1,libraryID=catalog['libraryID'],libraryVersion=catalog['version'],assetURI='sfx://asset/'+asset['id'],expectedSHA256=asset['sha256'],license=asset['license'],sourceDurationSeconds=asset['duration'],auditionStatus=asset['auditionStatus']).items()) or asset['license']!='CC0-1.0' or not asset['redistributionAllowed'] or asset['format']!='wav':raise ValueError('Unsupported or changed sound reference')
                leaf=ref['expectedSHA256']+'.wav';data=folder.read(leaf,64*1024*1024);budget+=len(data)
                if budget>128*1024*1024 or len(data)!=asset['bytes'] or A.sha(data)!=ref['expectedSHA256']:raise ValueError('Changed or over-budget sound snapshot')
                old,new=node(before,key),node(after,key)
                resource=next((a for a in actual_assets if a.get('id')==new.get('ref')),None)
                rep=None if resource is None else resource.find('media-rep')
                uri=urlparse('' if rep is None else rep.get('src',''))
                if uri.scheme!='file' or uri.netloc not in ('','localhost') or Path(unquote(uri.path)).resolve()!=folder.path/leaf:raise ValueError('Replacement source does not match verified audio')
                for attr in ('ref','name'):
                    if attr in old.attrib:new.set(attr,old.get(attr))
                    else:new.attrib.pop(attr,None)
                hashes[str(folder.path/leaf)]=ref['expectedSHA256']
            for asset in actual_assets:
                if asset.get('id') not in old_ids:resources.remove(asset)
            if canonical(before)!=canonical(after):raise ValueError('Sound edit changed unrelated picture, timing, gain or fades')
            folder.check()
            metadata=dict(selection=s,references=refs,source_sha256=hashes)
            return metadata,raw,edited
        finally:folder.close()

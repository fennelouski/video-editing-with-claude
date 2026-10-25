"""Derive the lightweight catalog from an explicitly verified metadata release.

No network or audio transfer. The caller supplies independently retained release
version/hash pins; existing stable IDs may not silently change their media hashes.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

def digest(data): return hashlib.sha256(data).hexdigest()
def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('release',type=Path);p.add_argument('manifest',type=Path)
    p.add_argument('--expected-version',required=True);p.add_argument('--expected-manifest-sha256',required=True)
    args=p.parse_args();source=args.release.resolve()
    for line in (source/'SHA256SUMS.txt').read_text().splitlines():
        expected,name=line.split(None,1);path=(source/name.lstrip('*')).resolve()
        if not path.is_relative_to(source) or digest(path.read_bytes())!=expected: raise ValueError('Release checksum mismatch: '+name)
    data=args.manifest.read_bytes()
    if digest(data)!=args.expected_manifest_sha256 or data!=(source/'asset-library.json').read_bytes(): raise ValueError('Canonical manifest release pin mismatch')
    master=json.loads(data);compat=json.loads((source/'public-package-compatibility-v3.json').read_text())
    if master['library_version']!=args.expected_version or compat['canonical_reference_manifest_sha256']!=digest(data): raise ValueError('Version/compatibility mismatch')
    root=Path(__file__).resolve().parents[1];target=root/'Sources/SoundBrowserCore/Resources'
    prior=json.loads((target/'catalog.json').read_text());old={a['id']:a['sha256'] for a in prior['assets']}
    incoming={a['asset_id']:a['sha256'] for a in master['assets']}
    if any(incoming.get(key)!=value for key,value in old.items()): raise ValueError('Existing stable asset identity/hash changed; explicit migration required')
    providers={a['asset_id']:a['provider_ref'] for a in json.loads((source/'public-install-reference-catalog.json').read_text())['assets']}
    licenses=[]
    for path in sorted((source/'licenses').iterdir()):
        shutil.copyfile(path,target/'licenses'/path.name);licenses.append(dict(path='licenses/'+path.name,sha256=digest(path.read_bytes())))
    assets=[]
    for a in master['assets']:
        assets.append(dict(id=a['asset_id'],title=a['title'],category=a['category'],tags=a['tags'],relativePath=a['file_path'],sha256=a['sha256'],bytes=a['size_bytes'],duration=a['duration_seconds'],format=a['file_format'],sampleRate=a['sample_rate_hz'],channels=a['channels'],license=a['license'],creator=a['creator'],sourceURL=a['source_url'],licenseURL=a['license_url'],providerID=providers[a['asset_id']],packageID=a['package_id'],auditionStatus=a['audition_status'],note=a.get('selection_note') or '',redistributionAllowed=a['rights']['redistribute_raw']))
    compact=(json.dumps(dict(schemaVersion=1,libraryID=master['library_id'],version=master['library_version'],sourceManifestSHA256=digest(data),assets=assets,licenseRecords=licenses),separators=(',',':'),ensure_ascii=False)+'\n').encode()
    catalog_source=root/'Sources/SoundBrowserCore/Catalog.swift';swift=catalog_source.read_text()
    swift=swift.replace(digest((target/'catalog.json').read_bytes()),digest(compact))
    swift=swift.replace(digest((target/'package-compatibility.json').read_bytes()),digest((source/'public-package-compatibility-v3.json').read_bytes()))
    (target/'catalog.json').write_bytes(compact);catalog_source.write_text(swift)
    shutil.copyfile(source/'public-provider-references.json',target/'providers.json')
    shutil.copyfile(source/'public-package-compatibility-v3.json',target/'package-compatibility.json')
    print(json.dumps(dict(version=master['library_version'],assetCount=len(assets),preservedIDs=len(old),catalogSHA256=digest(compact),audioDownloads=0)))
if __name__=='__main__':main()

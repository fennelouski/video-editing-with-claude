"""Create synthetic codec QA data only, using an explicitly supplied source WAV."""
import json,subprocess,sys
from pathlib import Path
import decoded_sound_cache as C
import sound_timeline_adapter as A
source,root=map(Path,sys.argv[1:]);root.mkdir(parents=True,exist_ok=True)
original=root/'original.ogg';cache=root/'cache';cache.mkdir(exist_ok=True)
subprocess.run(['/opt/homebrew/bin/ffmpeg','-nostdin','-v','error','-threads','1','-i',str(source),'-threads','1','-c:a','libvorbis','-y',str(original)],check=True)
data=original.read_bytes();info=json.loads(subprocess.run(['/opt/homebrew/bin/ffprobe','-v','error','-show_entries','stream=sample_rate,channels,duration','-of','json',str(original)],capture_output=True,check=True).stdout)['streams'][0]
asset=A.strict((A.RESOURCES/'catalog.json').read_bytes())['assets'][0].copy()
asset.update(id='synthetic-codec-fixture',title='Synthetic codec QA only',relativePath='original.ogg',sha256=A.sha(data),bytes=len(data),duration=float(info['duration']),format='ogg',sampleRate=int(info['sample_rate']),channels=info['channels'],auditionStatus='NOT_AUDITIONED')
_,receipt=C.decode(data,asset_id=asset['id'],expected_sha256=asset['sha256'],duration=asset['duration'],sample_rate=asset['sampleRate'],channels=asset['channels'],cache_root=cache,decoder='/opt/homebrew/bin/ffmpeg')
(root/'asset.json').write_bytes(A.encode(asset));(root/'fixture.json').write_bytes(A.encode(dict(cacheKey=A.sha(A.encode(receipt['identity'])),decoderSHA256=receipt['identity']['decoderSHA256'],receiptSHA256=A.sha(A.encode(receipt)))))

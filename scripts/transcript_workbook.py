"""Create complete source-bound transcript rows, without editorial exclusions."""
from pathlib import Path
import csv,hashlib,json,re,shutil,subprocess

BASE=Path('/Volumes/Videos/Food Videos/Katie YouTube/Projects/Current/Build')
OUT=BASE/'Yeast transcript selection 2026-10-14'
V5=BASE/'Pizza v5 — script first 2026-10-14'
CANON=BASE/'Pizza correction 2026-10-13-a17c/canon-dialogue-prep'
HEADERS=['Keep','Sequence','Stable row ID','Source clip','In timecode','Out timecode','Verbatim transcript (ASR)','Katie notes','Katie requested graphics','Assistant graphic suggestions','Shoot','Transcription uncertainty','Original order','First word index','Last word index','In seconds','Out seconds','Source SHA-256','Handwritten asset reference']

def tc(s):
 ms=round(s*1000);h,ms=divmod(ms,3600000);m,ms=divmod(ms,60000);sec,ms=divmod(ms,1000)
 return f'{h:02}:{m:02}:{sec:02}.{ms:03}'

def groups(words):
 first=0
 function_words=set('a an the and or but to of for with from by in on at is are was were be been being will would can could should my your our their its that which when because going'.split())
 def boundary(i):
  if i==len(words)-1:return True
  sentence=bool(re.search(r'[.!?]["\u201d\u2019]?$',words[i]['word']))
  gap=words[i+1]['start']-words[i]['end']
  content=re.sub(r'[^a-z]','',words[i]['word'].lower()) not in function_words
  return sentence or (gap>=.65 and content)
 while first<len(words):
  i=first
  while i<len(words)-1:
   count=i-first+1;span=words[i]['end']-words[first]['start']
   if count>=5 and boundary(i):break
   if count>=28 or (span>16 and count>=8):
    # Finish a sentence/clause rather than chopping a phrase at the size cap.
    end=min(len(words)-1,i+20)
    next_boundary=next((j for j in range(i,end+1) if boundary(j)),None)
    if next_boundary is not None:i=next_boundary;break
    # Rare unpunctuated run-ons stay manageable and are explicitly linked below.
    i=end;break
   i+=1
  yield first,i
  first=i+1

def suggestion(text):
 low=text.lower()
 if 'carbon dioxide' in low or 'co2' in low:return 'Optional paper CO₂ bubbles; keep the real dough visible.'
 if ('fridge' in low or 'cold' in low) and ('yeast' in low or 'ferment' in low):return 'Optional cold-versus-warm time card; avoid a fixed fermentation-rate claim.'
 if 'saccharomyces' in low:return 'Optional yeast-name tag; check the recording and spelling.'
 if '100 degrees' in low:return 'Optional source-confirmed temperature label with °F and °C.'
 return ''

def prepare():
 OUT.mkdir(exist_ok=True)
 originals=OUT/'original-transcripts';originals.mkdir(exist_ok=True)
 manifest={r['source_id']:r for r in json.loads((V5/'script-review/SOURCE_MANIFEST.json').read_text())}
 verified={s['source_id']:s for s in json.loads((OUT/'COMPLETE_TRANSCRIPT_DATA.json').read_text())['sources']} if (OUT/'COMPLETE_TRANSCRIPT_DATA.json').exists() else {}
 sources=[];rows=[]
 for section,files in [('Main pizza shoot',sorted(CANON.glob('MVI_*.words.json'))),('Older yeast shoot',sorted((V5/'acam-transcripts').glob('other_a_*.words.json')))]:
  for file in files:
   sid=file.name.split('.')[0];raw=file.read_bytes();data=json.loads(raw);words=data['words'];m=manifest[sid]
   source=Path(m['path']);stat=source.stat();assert stat.st_size==m['size']
   prior=verified.get(sid,{})
   cached_hash_ok=prior.get('path')==str(source.resolve()) and (prior.get('source_sha256'),prior.get('size'),prior.get('mtime_ns'))==(m['sha256'],stat.st_size,stat.st_mtime_ns)
   if stat.st_mtime_ns!=m['mtime_ns'] and not cached_hash_ok:
    h=hashlib.sha256()
    with source.open('rb') as f:
     for block in iter(lambda:f.read(8*1024*1024),b''):h.update(block)
    assert h.hexdigest()==m['sha256'],'Changed source bytes require fresh transcript binding'
    assert source.stat().st_mtime_ns==stat.st_mtime_ns
   original=originals/file.name
   if original.exists():assert original.read_bytes()==raw,'Preserve original transcript snapshot'
   else:original.write_bytes(raw)
   # Canon clip order is retained. Camera clocks disagree with import-folder dates.
   # Blue sweatshirt clips are identified from previously inspected local stills.
   wardrobe='Blue sweatshirt' if sid in {'MVI_8179','MVI_8180','MVI_8181'} else 'Other main-shoot clip' if sid.startswith('MVI_') else 'Older yeast narration'
   duration=float(data.get('source_duration',data.get('duration')))
   method='reused prior full SHA with matching resolved path/size/mtime' if cached_hash_ok else 'fresh full SHA after metadata change' if stat.st_mtime_ns!=m['mtime_ns'] else 'original full SHA with unchanged source size/mtime'
   rec={'source_id':sid,'path':str(source.resolve()),'source_sha256':m['sha256'],'size':stat.st_size,'mtime_ns':stat.st_mtime_ns,'source_device':stat.st_dev,'source_inode':stat.st_ino,'hash_verification_method':method,'prior_manifest_mtime_ns':m['mtime_ns'],'fresh_hash_after_metadata_change':stat.st_mtime_ns!=m['mtime_ns'] and not cached_hash_ok,'duration_seconds':duration,'section':section,'wardrobe':wardrobe,'word_count':len(words),'transcript_sha256':hashlib.sha256(raw).hexdigest(),'original_transcript':str(original),'words':words}
   sources.append(rec)
   for a,b in groups(words):
    part=words[a:b+1];text=' '.join(w['word'] for w in part);flags=[]
    low=[w['word'] for w in part if w.get('score',w.get('probability',1)) is not None and w.get('score',w.get('probability',1))<.5]
    if low:flags.append('Low-confidence ASR: '+', '.join(low[:5]))
    if any(w['end']-w['start']>max(.8,.15*len(w['word'])) for w in part):flags.append('Word timing may be stretched')
    if any(w['start']<0 or w['end']>duration for w in part):flags.append('Raw alignment crosses source bounds; verify before editing')
    if not flags:flags.append('ASR unverified')
    flags.append('Speaker not verified')
    stable=f'{sid}-w{a:05}-{b:05}-{m["sha256"][:8]}'
    rows.append({'keep':True,'sequence':len(rows)+1,'id':stable,'source_id':sid,'in_tc':tc(part[0]['start']),'out_tc':tc(part[-1]['end']),'text':text,'notes':'','requested_graphics':'','assistant_graphics':suggestion(text),'handwritten_asset':'','section':section+' / '+wardrobe,'uncertainty':'; '.join(flags),'original_order':len(rows)+1,'first_word':a,'last_word':b,'start':part[0]['start'],'end':part[-1]['end'],'source_sha256':m['sha256']})
 for s in sources:
  selected=[r for r in rows if r['source_id']==s['source_id']]
  indexes=[i for r in selected for i in range(r['first_word'],r['last_word']+1)]
  assert indexes==list(range(len(s['words']))),'Every raw token must occur exactly once'
  assert ' '.join(r['text'] for r in selected)==' '.join(w['word'] for w in s['words'])
 assert len({r['id'] for r in rows})==len(rows)
 for a,b in zip(rows,rows[1:]):
  if a['source_id']==b['source_id'] and not re.search(r'[.!?]["\u201d\u2019]?$',a['text']) and b['start']-a['end']<.65:
   a['uncertainty']+='; Thought continues in '+b['id']
   b['uncertainty']+='; Continues from '+a['id']
 science_path=OUT/'Assistant science graphic suggestions.json'
 if science_path.exists():
  science=json.loads(science_path.read_text())
  source_by_id={s['source_id']:s for s in sources}
  for sid,p in science['raw_transcript_provenance'].items():
   assert (p['sha256'],p['word_count'])==(source_by_id[sid]['transcript_sha256'],source_by_id[sid]['word_count']),'Stale science transcript provenance'
  for entry in science['suggestions']+science['transcript_selection_flags']:
   words=source_by_id[entry['source_id']]['words'];lo=entry['word_start_index_0based'];hi=entry['word_end_index_0based_inclusive']
   assert 0<=lo<=hi<len(words)
   assert ' '.join(w['word'] for w in words[lo:hi+1])==entry['raw_word_text']
   assert abs(words[lo]['start']-entry['source_start_s'])<1e-6 and abs(words[hi]['end']-entry['source_end_s'])<1e-6
  for row in rows:
   relevant=lambda x:x['source_id']==row['source_id'] and x['word_start_index_0based']<=row['last_word'] and x['word_end_index_0based_inclusive']>=row['first_word']
   suggestions=[x['assistant_graphic_suggestion'] for x in science['suggestions'] if relevant(x)]
   flags=['Science wording to review: '+x['finding']+'. '+x['selection_note'] for x in science['transcript_selection_flags'] if relevant(x)]
   if suggestions or flags:row['assistant_graphics']='\n\n'.join(suggestions+flags)
 dataset={'schema_version':1,'title':'Yeast while making pizza — complete transcript selection','headers':HEADERS,'sources':sources,'rows':rows,'default_all_kept':True,'chronology':'Main Canon clip-number order, then separately labeled older yeast Canon clip-number order; not combined camera-clock chronology.','scope':'Complete cached ASR from every canonical spoken-source clip. False starts, mistakes and unidentified other speakers retained. ASR is not certified verbatim listening. No duplicate ONE R/main/LRV narration added.','v7_script_locked':False}
 dataset['dataset_sha256']=hashlib.sha256(json.dumps({'sources':[(s['source_id'],s['source_sha256'],s['transcript_sha256']) for s in sources],'rows':rows},ensure_ascii=False,sort_keys=True).encode()).hexdigest()
 (OUT/'COMPLETE_TRANSCRIPT_DATA.json').write_text(json.dumps(dataset,indent=2,ensure_ascii=False)+'\n')
 matrix=[[r['keep'],r['sequence'],r['id'],r['source_id'],r['in_tc'],r['out_tc'],r['text'],r['notes'],r['requested_graphics'],r['assistant_graphics'],r['section'],r['uncertainty'],r['original_order'],r['first_word'],r['last_word'],r['start'],r['end'],r['source_sha256'],r['handwritten_asset']] for r in rows]
 with (OUT/'Complete chronological transcript.csv').open('w',newline='') as f:
  w=csv.writer(f);w.writerow(HEADERS);w.writerows(matrix)
 receipt={'rows':len(rows),'sources':len(sources),'raw_words':sum(s['word_count'] for s in sources),'main_sources':sum(s['section']=='Main pizza shoot' for s in sources),'older_sources':sum(s['section']=='Older yeast shoot' for s in sources),'main_words':sum(s['word_count'] for s in sources if s['section']=='Main pizza shoot'),'older_words':sum(s['word_count'] for s in sources if s['section']=='Older yeast shoot'),'every_raw_token_once':True,'false_starts_and_mistakes_removed':False,'originals_preserved':True,'A_B_duplicate_narration_added':False,'blue_sweatshirt_sources':['MVI_8179','MVI_8180','MVI_8181'],'dataset_sha256':dataset['dataset_sha256'],'audio_listening_verified':False,'full_recording_transcription_fidelity_certified':False,'v7_waiting_for_Katie_selection':True}
 (OUT/'COMPLETENESS_QA.json').write_text(json.dumps(receipt,indent=2)+'\n')
 print(json.dumps(receipt),flush=True)

if __name__=='__main__':prepare()

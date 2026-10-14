"""Read a returned working-sheet export without losing row order or provenance."""
from pathlib import Path
import argparse,csv,hashlib,json,math,xml.etree.ElementTree as ET,zipfile

NS={'s':'http://schemas.openxmlformats.org/spreadsheetml/2006/main','r':'http://schemas.openxmlformats.org/officeDocument/2006/relationships'}
def read_xlsx(path):
 with zipfile.ZipFile(path) as z:
  strings=[]
  if 'xl/sharedStrings.xml' in z.namelist():
   strings=[''.join(x.itertext()) for x in ET.fromstring(z.read('xl/sharedStrings.xml')).findall('s:si',NS)]
  rels={x.attrib['Id']:x.attrib['Target'] for x in ET.fromstring(z.read('xl/_rels/workbook.xml.rels'))}
  sheets=ET.fromstring(z.read('xl/workbook.xml')).findall('s:sheets/s:sheet',NS)
  matches=[s for s in sheets if s.attrib['name']=='Working script' or s.attrib['name'].startswith('Working script - ')]
  if len(matches)!=1:raise ValueError('Return one Working script sheet, with its original name.')
  target=rels[matches[0].attrib['{'+NS['r']+'}id']];target=target.lstrip('/') if target.startswith('/') else 'xl/'+target
  parsed=[]
  for row in ET.fromstring(z.read(target)).findall('s:sheetData/s:row',NS):
   values={}
   for c in row.findall('s:c',NS):
    key=''.join(x for x in c.attrib['r'] if x.isalpha());typ=c.attrib.get('t');v=c.find('s:v',NS)
    value=v.text if v is not None else ''
    if typ=='s':value=strings[int(value)]
    elif typ=='inlineStr':value=''.join(c.find('s:is',NS).itertext())
    elif typ=='b':value=value=='1'
    elif typ=='e':raise ValueError('Workbook contains a cell error at '+c.attrib['r'])
    values[key]=value
   parsed.append(values)
  headers=parsed[0];return [{headers[k]:r.get(k,'') for k in headers} for r in parsed[1:]]

def read_rows(path):
 if path.suffix.lower()=='.xlsx':return read_xlsx(path)
 if path.suffix.lower()=='.csv':
  with path.open(encoding='utf-8-sig',newline='') as f:return list(csv.DictReader(f))
 raise ValueError('Return an exported .xlsx or Working script .csv file.')

def keep_value(value):
 if value is True or str(value).strip().lower() in {'true','1'}:return True
 if value is False or str(value).strip().lower() in {'false','0'}:return False
 raise ValueError('Keep must contain TRUE/FALSE, not a blank or an unrecognized value.')

def validate(rows,dataset):
 original={r['id']:r for r in dataset['rows']};seen=set();selected=[];annotations=[]
 for position,row in enumerate(rows,1):
  if not row.get('Stable row ID'):continue
  sid=row['Stable row ID']
  if sid not in original:raise ValueError('Unknown stable row ID: '+sid)
  if sid in seen:raise ValueError('Duplicate stable row ID: '+sid)
  seen.add(sid);source=original[sid]
  for key,expected in [('Source clip',source['source_id']),('Verbatim transcript (ASR)',source['text']),('Source SHA-256',source['source_sha256'])]:
   if row.get(key)!=expected:raise ValueError('Source-bound '+key+' changed for '+sid+'; put requested wording changes in Katie notes.')
  for key,expected in [('First word index',source['first_word']),('Last word index',source['last_word']),('In seconds',source['start']),('Out seconds',source['end'])]:
   try:actual=float(row[key])
   except (KeyError,ValueError,TypeError):raise ValueError('Missing source mapping: '+key+' for '+sid)
   if not math.isfinite(actual) or abs(actual-expected)>1e-6:raise ValueError('Source-bound '+key+' changed for '+sid)
  kept=keep_value(row.get('Keep'))
  entry={'physical_working_order':position,'id':sid,'keep':kept,'source_id':source['source_id'],'source_sha256':source['source_sha256'],'first_word':source['first_word'],'last_word':source['last_word'],'start':source['start'],'end':source['end'],'text':source['text'],'Katie_notes':row.get('Katie notes',''),'Katie_requested_graphics':row.get('Katie requested graphics',''),'assistant_graphic_suggestions':row.get('Assistant graphic suggestions',''),'handwritten_asset_reference':row.get('Handwritten asset reference',''),'uncertainty':source['uncertainty']}
  annotations.append(entry)
  if kept:selected.append(entry)
 missing=set(original)-seen
 if missing:raise ValueError(f'{len(missing)} source rows were deleted. Restore them and untick Keep so removal choices remain explicit.')
 return {'schema_version':1,'dataset_sha256':dataset['dataset_sha256'],'selection_imported':True,'human_identity_or_final_approval_asserted':False,'v7_narrative_locked':False,'ordered_selected_rows':selected,'all_row_annotations':annotations,'selected_rows':len(selected),'total_rows':len(annotations),'row_order_source':'physical Working script order; Sequence formula is informational','source_bounds_review_required':[r['id'] for r in selected if 'crosses source bounds' in r['uncertainty']]}

def main():
 p=argparse.ArgumentParser();p.add_argument('workbook',type=Path);p.add_argument('--dataset',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
 result=validate(read_rows(a.workbook),json.loads(a.dataset.read_text()));result['returned_workbook_sha256']=hashlib.sha256(a.workbook.read_bytes()).hexdigest()
 # Exclusive publication prevents accidentally replacing an earlier selection.
 with a.output.open('x') as f:json.dump(result,f,indent=2,ensure_ascii=False);f.write('\n')
 print(json.dumps({'selection_exported':str(a.output),'selected_rows':result['selected_rows'],'total_rows':result['total_rows'],'v7_narrative_locked':False}))
if __name__=='__main__':main()

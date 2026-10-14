import copy
import pytest
from import_transcript_selection import keep_value,validate

def fixture():
 source={'id':'clip-w00000-00004-12345678','source_id':'clip','source_sha256':'a'*64,'first_word':0,'last_word':4,'start':1.25,'end':2.5,'text':'The yeast makes carbon dioxide.','uncertainty':'ASR unverified'}
 row={'Keep':True,'Stable row ID':source['id'],'Source clip':'clip','Source SHA-256':'a'*64,'First word index':0,'Last word index':4,'In seconds':1.25,'Out seconds':2.5,'Verbatim transcript (ASR)':source['text'],'Katie notes':'Keep this thought','Katie requested graphics':'Show bubbles','Handwritten asset reference':'title.png'}
 return {'dataset_sha256':'b'*64,'rows':[source]},row

def test_annotation_state_survives_with_source_mapping():
 dataset,row=fixture();result=validate([row],dataset);entry=result['ordered_selected_rows'][0]
 assert entry['Katie_notes']=='Keep this thought'
 assert entry['Katie_requested_graphics']=='Show bubbles'
 assert entry['handwritten_asset_reference']=='title.png'
 assert entry['start']==1.25 and not result['v7_narrative_locked']

@pytest.mark.parametrize('change',[{'Source clip':'different'},{'In seconds':3.0},{'Verbatim transcript (ASR)':'New invented sentence.'},{'Keep':''}])
def test_corrupted_source_or_ambiguous_choice_is_rejected(change):
 dataset,row=fixture();row.update(change)
 with pytest.raises(ValueError):validate([row],dataset)

def test_deleting_a_row_is_rejected_while_unticking_is_allowed():
 dataset,row=fixture()
 with pytest.raises(ValueError,match='deleted'):validate([],dataset)
 row['Keep']=False;result=validate([row],dataset)
 assert result['selected_rows']==0 and result['total_rows']==1

def test_duplicate_stable_id_is_rejected():
 dataset,row=fixture()
 with pytest.raises(ValueError,match='Duplicate'):validate([row,copy.deepcopy(row)],dataset)

@pytest.mark.parametrize('value,expected',[(True,True),(False,False),('TRUE',True),('FALSE',False),('1',True),('0',False)])
def test_native_export_keep_encodings(value,expected):assert keep_value(value)==expected

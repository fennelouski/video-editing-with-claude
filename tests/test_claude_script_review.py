"""Synthetic transport checks; these tests invoke no provider or private footage."""
import json
import pytest
import claude_script_review as R
from editorial_workflow import EditorialError

@pytest.mark.parametrize('mode',['different_session','missing_session','bad_denials','error'])
def test_unverified_provider_result_cannot_count_as_an_independent_turn(tmp_path,monkeypatch,mode):
    class FakeProcess:
        returncode=0
        def __init__(self,args,**kwargs):self.args=args;self.output=kwargs['stdout']
        def communicate(self,prompt,timeout):
            session=self.args[self.args.index('--session-id')+1]
            event={'type':'result','subtype':'success','is_error':False,'session_id':session,'permission_denials':[],'structured_output':{'synthetic':True}}
            if mode=='different_session':event['session_id']='unrelated-actual-session'
            if mode=='missing_session':del event['session_id']
            if mode=='bad_denials':event['permission_denials']=False
            if mode=='error':event['is_error']=True
            self.output.write((json.dumps(event)+'\n').encode());self.output.flush()
    monkeypatch.setattr(R.subprocess,'Popen',FakeProcess)
    with pytest.raises(EditorialError):R.run_turn(tmp_path/'synthetic-cli',tmp_path/'turn','Synthetic words.',{},'No tools.')
    assert not (tmp_path/'turn/result.json').exists()

def test_only_observed_completed_identity_is_returned_with_paid_transports_disabled(tmp_path,monkeypatch):
    captured={}
    class FakeProcess:
        returncode=0
        def __init__(self,args,**kwargs):captured.update({'args':args,'env':kwargs['env']});self.args=args;self.output=kwargs['stdout']
        def communicate(self,prompt,timeout):
            session=self.args[self.args.index('--session-id')+1]
            event={'type':'result','subtype':'success','is_error':False,'session_id':session,'permission_denials':[],'uuid':'synthetic-provider-receipt','structured_output':{'synthetic':True}}
            self.output.write((json.dumps(event)+'\n').encode());self.output.flush()
    monkeypatch.setenv('ANTHROPIC_API_KEY','synthetic-never-send')
    monkeypatch.setenv('CLAUDE_CODE_USE_BEDROCK','1')
    monkeypatch.setattr(R.subprocess,'Popen',FakeProcess)
    value,receipt=R.run_turn(tmp_path/'synthetic-cli',tmp_path/'turn','Synthetic words.',{},'No tools.')
    assert value=={'synthetic':True}
    assert receipt['session_identity_verified'] is True
    assert receipt['session_id']==receipt['observed_session_id']
    assert 'ANTHROPIC_API_KEY' not in captured['env'] and 'CLAUDE_CODE_USE_BEDROCK' not in captured['env']
    args=captured['args']
    assert args[args.index('--tools')+1]=='StructuredOutput'
    assert args[args.index('--mcp-config')+1]=='{"mcpServers":{}}'
    assert '--safe-mode' in args and '--no-chrome' in args and '--no-session-persistence' in args

def test_changed_context_cannot_create_ledger_or_send_a_turn(tmp_path,monkeypatch):
    context=tmp_path/'context.json';context.write_text('{"synthetic":true}')
    def refused(*args,**kwargs):pytest.fail('A changed context must never reach the provider.')
    monkeypatch.setattr(R,'run_turn',refused)
    with pytest.raises(EditorialError,match='context changed'):
        R.review(tmp_path/'cli',tmp_path/'sources.json',context,'0'*64,tmp_path/'output')
    assert not (tmp_path/'output').exists()

def test_cancelled_parent_stops_independent_child_and_records_no_completion(tmp_path,monkeypatch):
    killed=[]
    class FakeProcess:
        returncode=None;pid=999001
        def __init__(self,*args,**kwargs):pass
        def communicate(self,*args,**kwargs):raise KeyboardInterrupt()
        def wait(self,timeout=None):self.returncode=-15;return -15
    monkeypatch.setattr(R.subprocess,'Popen',FakeProcess)
    monkeypatch.setattr(R.os,'killpg',lambda pid,signal:killed.append((pid,signal)))
    previous=R.signal.getsignal(R.signal.SIGTERM)
    with pytest.raises(KeyboardInterrupt):R.run_turn(tmp_path/'cli',tmp_path/'turn','Synthetic words.',{},'No tools.')
    assert killed==[(999001,R.signal.SIGTERM)]
    assert R.signal.getsignal(R.signal.SIGTERM)==previous
    finish=json.loads((tmp_path/'turn/FINISH.json').read_text())
    assert finish['status']=='interrupted' and finish['completed_review'] is False
    assert not (tmp_path/'turn/result.json').exists()

def test_omitted_critical_issue_continues_real_round_loop_until_explicit_resolution(tmp_path,monkeypatch):
    import hashlib
    source={'source_id':'synthetic-a','source_sha256':'a'*64,'duration':2,'words':[{'word':'Make','start':.1,'end':.4},{'word':'pizza.','start':.5,'end':1}]}
    script={'schema_version':1,'sections':[{'segments':[{'source_id':'synthetic-a','source_sha256':'a'*64,'first_word':0,'last_word':1}]}]}
    sources=tmp_path/'sources.json';sources.write_text(json.dumps([source]))
    context=tmp_path/'context.json';context.write_text('{"synthetic":true}')
    count={'turns':0,'reviews':0,'pending_seen':False}
    def fake_turn(cli,folder,prompt,schema,system):
        folder.mkdir();count['turns']+=1
        receipt={'session_id':f'synthetic-independent-session-{count["turns"]}','receipt_id':f'synthetic-receipt-{count["turns"]}'}
        if folder.name=='writer-draft':value={'script':script,'author_notes':'Synthetic.'}
        else:
            digest=hashlib.sha256((folder.parent/'script.json').read_bytes()).hexdigest()
            issue={'id':'meaning-01','description':'Synthetic missing prerequisite.','severity':'critical','status':'open'}
            if folder.name=='adversarial-reviewer':
                count['reviews']+=1
                if count['reviews']==1:value={'decision':'revise','script_sha256':digest,'issues':[issue]}
                elif count['reviews']==2:value={'decision':'agree','script_sha256':digest,'issues':[]}
                else:
                    value={'decision':'agree','script_sha256':digest,'issues':[{**issue,'status':'resolved','resolution':'Synthetic exact source context verifies the prerequisite.','resolved_by':'reviewer'}]}
                    count['pending_seen']='authoritative_pending_issues' in prompt and 'meaning-01' in prompt
            else:value={'decision':'agree','script_sha256':digest,'issues':[]}
        R.save(folder/'result.json',value)
        return value,receipt
    monkeypatch.setattr(R,'run_turn',fake_turn)
    state=R.review(tmp_path/'cli',sources,context,hashlib.sha256(context.read_bytes()).hexdigest(),tmp_path/'output',3)
    assert state['round_count']==3 and state['approved'] is True and count['pending_seen'] is True

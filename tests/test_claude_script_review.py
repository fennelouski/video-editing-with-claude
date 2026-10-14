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
            event={'type':'result','subtype':'success','is_error':False,'session_id':session,'permission_denials':[],'uuid':'synthetic-provider-receipt','result':'{"synthetic":true}'}
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
    assert args[args.index('--tools')+1]=='' and '--json-schema' not in args
    assert args[args.index('--permission-mode')+1]=='dontAsk'
    assert args[args.index('--permission-prompts')+1]=='none'
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

def test_resume_keeps_actual_count_and_refuses_changed_input(tmp_path,monkeypatch):
    from editorial_workflow import RoundLedger,TranscriptSource,ReviewReceipt,validate_script,sha256
    source={'source_id':'synthetic-a','source_sha256':'a'*64,'duration':2,'words':[{'word':'Make','start':.1,'end':.4},{'word':'pizza.','start':.5,'end':1}]}
    script={'sections':[{'segments':[{'source_id':'synthetic-a','source_sha256':'a'*64,'first_word':0,'last_word':1}]}]}
    sources=tmp_path/'sources.json';sources.write_text(json.dumps([source]))
    context=tmp_path/'context.json';context.write_text('{"synthetic":true}')
    output=tmp_path/'output';output.mkdir()
    ledger=RoundLedger.create(output/'ledger',max_rounds=1);ledger.complete_transcripts([TranscriptSource(**source)])
    validated=validate_script(script,[TranscriptSource(**source)])
    issue={'id':'meaning-01','description':'Synthetic unresolved premise.'}
    writer=ReviewReceipt.from_artifact('writer-existing','writer-receipt',{'decision':'revise','script_sha256':validated.script_sha256,'issues':[issue]})
    reviewer=ReviewReceipt.from_artifact('reviewer-existing','reviewer-receipt',{'decision':'revise','script_sha256':validated.script_sha256,'issues':[issue]})
    ledger.append_round(validated,writer=writer,reviewer=reviewer,round_id='actual-round-01')
    identity={'context_sha256':sha256(context.read_bytes()),'sources_sha256':sha256(sources.read_bytes()),'max_rounds':1,'render_enabled':False}
    R.save(output/'INPUT_IDENTITY.json',identity)
    def refused(*args,**kwargs):pytest.fail('Exhausted or changed review must not send another turn.')
    monkeypatch.setattr(R,'run_turn',refused)
    state=R.review(tmp_path/'cli',sources,context,identity['context_sha256'],output,1,True)
    assert state['round_count']==1 and state['exhausted_without_approval'] and not state['approved']
    sources.write_text(json.dumps([{**source,'duration':3}]))
    with pytest.raises(EditorialError,match='input identity changed'):
        R.review(tmp_path/'cli',sources,context,identity['context_sha256'],output,1,True)

def test_invalid_writer_draft_is_repaired_without_counting_a_review_round(tmp_path,monkeypatch):
    from editorial_workflow import sha256
    source={'source_id':'synthetic-a','source_sha256':'a'*64,'duration':2,'words':[{'word':'Make','start':.1,'end':.4},{'word':'pizza.','start':.5,'end':1}]}
    script={'sections':[{'segments':[{'source_id':'synthetic-a','source_sha256':'a'*64,'first_word':0,'last_word':1}]}]}
    sources=tmp_path/'sources.json';sources.write_text(json.dumps([source]));context=tmp_path/'context.json';context.write_text('{}')
    count={'drafts':0,'turns':0}
    def fake(cli,folder,prompt,schema,system):
        folder.mkdir();count['turns']+=1
        receipt={'session_id':f'synthetic-session-{count["turns"]}','receipt_id':f'synthetic-receipt-{count["turns"]}'}
        if folder.name=='writer-draft':
            count['drafts']+=1
            value={'script':{**script,'fact_flags':[{'id':'fact-01','description':'Synthetic fact','status':'resolved','resolution':'Model says yes','resolved_by':'writer'}]} if count['drafts']==1 else script,'author_notes':'Synthetic'}
        else:value={'decision':'agree','script_sha256':sha256((folder.parent/'script.json').read_bytes()),'issues':[]}
        R.save(folder/'result.json',value);return value,receipt
    monkeypatch.setattr(R,'run_turn',fake)
    state=R.review(tmp_path/'cli',sources,context,sha256(context.read_bytes()),tmp_path/'output',1)
    assert count['drafts']==2 and state['round_count']==1 and state['approved']
    assert len(list((tmp_path/'output').glob('round-*/attempt-*/VALIDATION_REFUSAL.json')))==1


def synthetic_review_inputs(tmp_path):
    source={'source_id':'synthetic-a','source_sha256':'a'*64,'duration':2,'words':[{'word':'Make','start':.1,'end':.4},{'word':'pizza.','start':.5,'end':1}]}
    script={'sections':[{'segments':[{'source_id':'synthetic-a','source_sha256':'a'*64,'first_word':0,'last_word':1}]}]}
    sources=tmp_path/'sources.json';sources.write_text(json.dumps([source]))
    context=tmp_path/'context.json';context.write_text('{}')
    return source,script,sources,context

def completed_synthetic_receipt(number):
    return {'session_id':f'synthetic-{number}','receipt_id':f'receipt-{number}',
            'exit_code':0,'result_subtype':'success','is_error':False,'session_identity_verified':True,'permission_denial_count':0}

def test_saved_minimum_survives_resume_without_directive(tmp_path,monkeypatch):
    from editorial_workflow import sha256,RoundLedger
    source,script,sources,context=synthetic_review_inputs(tmp_path)
    directive=tmp_path/'directive.json';directive.write_text('{"minimum_finished_seconds":480}')
    output=tmp_path/'output'
    counter={'turns':0}
    def short_draft(cli,folder,prompt,schema,system):
        assert 'minimum_finished_seconds' in prompt
        folder.mkdir();counter['turns']+=1
        value={'script':script,'author_notes':'Synthetic.'} if folder.name=='writer-draft' else {'decision':'agree','script_sha256':sha256((folder.parent/'script.json').read_bytes()),'issues':[]}
        receipt=completed_synthetic_receipt(counter['turns'])
        R.save(folder/'result.json',value);R.save(folder/'FINISH.json',receipt)
        return value,receipt
    monkeypatch.setattr(R,'run_turn',short_draft)
    first=R.review(tmp_path/'cli',sources,context,sha256(context.read_bytes()),output,2,False,directive,sha256(directive.read_bytes()))
    resumed=R.review(tmp_path/'cli',sources,context,sha256(context.read_bytes()),output,2,True)
    for state in [first,resumed]:
        assert not state['approved']
        assert any(i['id']==R.DURATION_EVIDENCE_ISSUE for i in state['unresolved_critical'])
    assert resumed['round_count']==2 and resumed['exhausted_without_approval']
    assert len(list(output.glob('round-*/attempt-*/PRODUCTION_EVIDENCE_REQUIRED.json')))==2
    assert len(list((output/'revision-directives').iterdir()))==1

def test_model_cannot_clear_protected_duration_evidence_by_assertion(tmp_path):
    from editorial_workflow import TranscriptSource
    source,script,_,_=synthetic_review_inputs(tmp_path)
    script['coverage_gaps']=[{'id':R.DURATION_EVIDENCE_ISSUE,'description':'Synthetic claim','severity':'critical','status':'resolved','resolution':'Pretend B-roll fills the deficit.','resolved_by':'writer'}]
    prepared,validated,projection=R.prepare_duration_review(script,[TranscriptSource(**source)],{'minimum_finished_seconds':480},{'unresolved_critical':[]})
    issue=next(i for i in prepared['coverage_gaps'] if i['id']==R.DURATION_EVIDENCE_ISSUE)
    assert issue['status']=='open' and 'resolved_by' not in issue
    assert validated.unresolved_critical and projection['finished_estimate_seconds']<480
    assert projection['invented_nonverbal_seconds']==0

def test_measured_articulation_can_resolve_host_duration_issue(tmp_path):
    from editorial_workflow import TranscriptSource,RoundLedger,ReviewReceipt
    source=TranscriptSource('synthetic-long','a'*64,500,[{'word':'Explanation','start':i,'end':i+1} for i in range(500)])
    def selected(last):return {'sections':[{'segments':[{'source_id':source.source_id,'source_sha256':source.source_sha256,'first_word':0,'last_word':last}]}]}
    ledger=RoundLedger.create(tmp_path/'ledger',max_rounds=2);ledger.complete_transcripts([source])
    def record(script,number):
        return ledger.append_round(script,writer=ReviewReceipt.from_artifact(f'writer-{number}',f'w-{number}',{'decision':'agree','script_sha256':script.script_sha256,'issues':[]}),reviewer=ReviewReceipt.from_artifact(f'reviewer-{number}',f'r-{number}',{'decision':'agree','script_sha256':script.script_sha256,'issues':[]}),round_id=f'round-{number}')
    _,short,_=R.prepare_duration_review(selected(0),[source],{'minimum_finished_seconds':480},ledger.summary())
    assert not record(short,1)['approved']
    prepared,long,projection=R.prepare_duration_review(selected(499),[source],{'minimum_finished_seconds':480},ledger.summary())
    assert prepared['coverage_gaps'][0]['resolved_by']=='local_duration_projection'
    assert projection['finished_estimate_seconds']==510 and record(long,2)['approved']

def test_prior_approved_short_script_cannot_bypass_new_minimum(tmp_path,monkeypatch):
    from editorial_workflow import sha256
    source,script,sources,context=synthetic_review_inputs(tmp_path)
    output=tmp_path/'output';counter={'turns':0}
    def fake(cli,folder,prompt,schema,system):
        folder.mkdir();counter['turns']+=1
        value={'script':script,'author_notes':'Synthetic.'} if folder.name=='writer-draft' else {'decision':'agree','script_sha256':sha256((folder.parent/'script.json').read_bytes()),'issues':[]}
        receipt=completed_synthetic_receipt(counter['turns'])
        R.save(folder/'result.json',value);R.save(folder/'FINISH.json',receipt)
        return value,receipt
    monkeypatch.setattr(R,'run_turn',fake)
    assert R.review(tmp_path/'cli',sources,context,sha256(context.read_bytes()),output,1)['approved']
    directive=tmp_path/'directive.json';directive.write_text('{"minimum_finished_seconds":480}')
    with pytest.raises(EditorialError,match='below the 480'):
        R.review(tmp_path/'cli',sources,context,sha256(context.read_bytes()),output,1,True,directive,sha256(directive.read_bytes()))
    with pytest.raises(EditorialError,match='below the 480'):
        R.review(tmp_path/'cli',sources,context,sha256(context.read_bytes()),output,1,True)
    assert counter['turns']==3

def test_unjournaled_completed_pair_stops_resume_before_new_turns(tmp_path,monkeypatch):
    from editorial_workflow import sha256,RoundLedger
    source,script,sources,context=synthetic_review_inputs(tmp_path)
    output=tmp_path/'output';counter={'turns':0}
    def fake(cli,folder,prompt,schema,system):
        folder.mkdir();counter['turns']+=1
        receipt={'session_id':f'synthetic-{counter["turns"]}','receipt_id':f'receipt-{counter["turns"]}',
                 'exit_code':0,'result_subtype':'success','is_error':False,'session_identity_verified':True,'permission_denial_count':0}
        value={'script':script,'author_notes':'Synthetic.'} if folder.name=='writer-draft' else {'decision':'agree','script_sha256':sha256((folder.parent/'script.json').read_bytes()),'issues':[]}
        R.save(folder/'result.json',value);R.save(folder/'FINISH.json',receipt)
        return value,receipt
    monkeypatch.setattr(R,'run_turn',fake)
    real_append=RoundLedger.append_round
    def interrupted(*args,**kwargs):raise InterruptedError('Synthetic interruption before append')
    monkeypatch.setattr(RoundLedger,'append_round',interrupted)
    with pytest.raises(InterruptedError):R.review(tmp_path/'cli',sources,context,sha256(context.read_bytes()),output,1)
    monkeypatch.setattr(RoundLedger,'append_round',real_append)
    with pytest.raises(EditorialError,match='completed actual provider review pair is not journaled'):
        R.review(tmp_path/'cli',sources,context,sha256(context.read_bytes()),output,1,True)
    assert counter['turns']==3 and RoundLedger.load(output/'ledger').summary()['round_count']==0

def test_changed_story_brief_never_inherits_prior_approval_on_later_resume(tmp_path,monkeypatch):
    from editorial_workflow import sha256
    source,script,sources,context=synthetic_review_inputs(tmp_path)
    output=tmp_path/'output';counter={'turns':0}
    def fake(cli,folder,prompt,schema,system):
        folder.mkdir();counter['turns']+=1
        value={'script':script,'author_notes':'Synthetic.'} if folder.name=='writer-draft' else {'decision':'agree','script_sha256':sha256((folder.parent/'script.json').read_bytes()),'issues':[]}
        receipt=completed_synthetic_receipt(counter['turns'])
        R.save(folder/'result.json',value);R.save(folder/'FINISH.json',receipt)
        return value,receipt
    monkeypatch.setattr(R,'run_turn',fake)
    assert R.review(tmp_path/'cli',sources,context,sha256(context.read_bytes()),output,1)['approved']
    directive=tmp_path/'directive.json';directive.write_text('{"minimum_finished_seconds":1,"new_story_requirement":"An earned recorded mid-video question and payoff."}')
    for args in [(directive,sha256(directive.read_bytes())),(None,None),(directive,sha256(directive.read_bytes()))]:
        with pytest.raises(EditorialError,match='cannot inherit prior script approval'):
            R.review(tmp_path/'cli',sources,context,sha256(context.read_bytes()),output,1,True,*args)
    assert counter['turns']==3

def test_terminal_review_stream_without_finish_receipt_blocks_resume(tmp_path,monkeypatch):
    from editorial_workflow import sha256,RoundLedger
    source,script,sources,context=synthetic_review_inputs(tmp_path)
    output=tmp_path/'output';counter={'turns':0}
    def fake(cli,folder,prompt,schema,system):
        folder.mkdir();counter['turns']+=1;receipt=completed_synthetic_receipt(counter['turns'])
        value={'script':script,'author_notes':'Synthetic.'} if folder.name=='writer-draft' else {'decision':'agree','script_sha256':sha256((folder.parent/'script.json').read_bytes()),'issues':[]}
        R.save(folder/'START.json',{'session_id':receipt['session_id']})
        if folder.name=='adversarial-reviewer':
            R.save(folder/'stream.jsonl',{'type':'result','subtype':'success','is_error':False,'session_id':receipt['session_id'],'permission_denials':[],'result':json.dumps(value)})
            raise InterruptedError('Synthetic parent death after terminal stream, before FINISH')
        R.save(folder/'result.json',value);R.save(folder/'FINISH.json',receipt)
        return value,receipt
    monkeypatch.setattr(R,'run_turn',fake)
    with pytest.raises(InterruptedError):R.review(tmp_path/'cli',sources,context,sha256(context.read_bytes()),output,1)
    with pytest.raises(EditorialError,match='started verdict role has no final receipt'):
        R.review(tmp_path/'cli',sources,context,sha256(context.read_bytes()),output,1,True)
    assert counter['turns']==3 and RoundLedger.load(output/'ledger').summary()['round_count']==0

@pytest.mark.parametrize('changed',[{'session_identity_verified':False},{'permission_denial_count':None},{'exit_code':None},{'status':'interrupted','result_subtype':None}])
def test_unknown_verdict_receipt_never_implies_an_uncompleted_pair(tmp_path,changed):
    from editorial_workflow import RoundLedger,TranscriptSource
    source,script,sources,context=synthetic_review_inputs(tmp_path)
    output=tmp_path/'output';output.mkdir();ledger=RoundLedger.create(output/'ledger',max_rounds=1)
    ledger.complete_transcripts([TranscriptSource(**source)])
    attempt=output/'round-01/attempt-1-synthetic';attempt.mkdir(parents=True)
    for number,role in enumerate(['writer-verdict','adversarial-reviewer'],1):
        folder=attempt/role;folder.mkdir();receipt=completed_synthetic_receipt(number)
        R.save(folder/'FINISH.json',{**receipt,**changed} if number==2 else receipt)
    with pytest.raises(EditorialError,match='unverified verdict role needs terminal-stream accounting'):
        R.check_round_accounting(output,ledger)

def complete_writer_value(source):
    return {'script':{'schema_version':1,'title':'Synthetic','purpose':'Protocol test','notes':'Unspoken notes',
        'sections':[{'id':'s1','title':'Synthetic section','purpose':'Test','segments':[{'source_id':source['source_id'],'source_sha256':source['source_sha256'],'first_word':0,'last_word':1,'join_notes':'No invented join'}]}],
        'pickups':[],'coverage_gaps':[],'fact_flags':[]},'author_notes':'Literal string braces }} remain unchanged.'}

def test_writer_can_recover_only_one_redundant_trailing_brace(tmp_path):
    from editorial_workflow import TranscriptSource,canonical_json
    source,_,_,_=synthetic_review_inputs(tmp_path);value=complete_writer_value(source)
    body=canonical_json(value).decode()+'}'
    assert R.writer_response_value(body,R.script_schema([TranscriptSource(**source)]),tmp_path)==value
    receipt=json.loads((tmp_path/'RESPONSE_SYNTAX_REPAIR.json').read_bytes())
    assert not receipt['scalar_content_changed'] and not receipt['source_selection_changed'] and not receipt['approval']

@pytest.mark.parametrize('suffix',['}}','{}',' prose','}\u00a0'])
def test_writer_syntax_recovery_refuses_other_trailers(tmp_path,suffix):
    from editorial_workflow import TranscriptSource,canonical_json
    source,_,_,_=synthetic_review_inputs(tmp_path)
    with pytest.raises(EditorialError):R.writer_response_value(canonical_json(complete_writer_value(source)).decode()+suffix,R.script_schema([TranscriptSource(**source)]),tmp_path)
    assert not (tmp_path/'RESPONSE_SYNTAX_REPAIR.json').exists()

def completed_writer_folder(round_folder,source):
    from editorial_workflow import canonical_json
    folder=round_folder/'attempt-1-synthetic/writer-draft';folder.mkdir(parents=True)
    receipt=completed_synthetic_receipt(1)
    R.save(folder/'START.json',{'session_id':receipt['session_id'],'started_utc':'2026-10-14T00:00:00Z'})
    R.save(folder/'FINISH.json',receipt)
    value=complete_writer_value(source)
    R.save(folder/'stream.jsonl',{'type':'result','subtype':'success','is_error':False,'session_id':receipt['session_id'],'permission_denials':[],'result':canonical_json(value).decode()+'}'})
    return folder,value

def test_recovered_real_draft_remains_unreviewed_and_pairs_are_accounted(tmp_path):
    from editorial_workflow import TranscriptSource,RoundLedger
    source,_,_,_=synthetic_review_inputs(tmp_path);output=tmp_path/'output';output.mkdir()
    ledger=RoundLedger.create(output/'ledger',max_rounds=1);ledger.complete_transcripts([TranscriptSource(**source)])
    round_folder=output/'round-01';folder,value=completed_writer_folder(round_folder,source)
    original=(folder/'stream.jsonl').read_bytes()
    recovered,current=R.recover_unreviewed_draft(round_folder,[TranscriptSource(**source)])
    assert recovered==value and current.name.startswith('attempt-recovered-')
    assert (folder/'stream.jsonl').read_bytes()==original and ledger.summary()['round_count']==0
    assert not json.loads((current/'DRAFT_RECOVERY.json').read_bytes())['approval']
    for number,role in enumerate(['writer-verdict','adversarial-reviewer'],2):
        role_folder=current/role;role_folder.mkdir();R.save(role_folder/'FINISH.json',completed_synthetic_receipt(number))
    with pytest.raises(EditorialError,match='completed actual provider review pair is not journaled'):R.check_round_accounting(output,ledger)

def test_invalid_source_or_already_reviewed_draft_is_not_recovered(tmp_path):
    from editorial_workflow import TranscriptSource
    source,_,_,_=synthetic_review_inputs(tmp_path);round_folder=tmp_path/'round-01'
    folder,_=completed_writer_folder(round_folder,source)
    different={**source,'source_sha256':'b'*64}
    assert R.recover_unreviewed_draft(round_folder,[TranscriptSource(**different)]) is None
    (folder.parent/'writer-verdict').mkdir()
    assert R.recover_unreviewed_draft(round_folder,[TranscriptSource(**source)]) is None

def test_recovery_refuses_provider_receipt_mismatch(tmp_path):
    from editorial_workflow import TranscriptSource
    source,_,_,_=synthetic_review_inputs(tmp_path);round_folder=tmp_path/'round-01'
    folder,_=completed_writer_folder(round_folder,source)
    terminal=json.loads((folder/'stream.jsonl').read_bytes());terminal['uuid']='unrelated-provider-receipt'
    (folder/'stream.jsonl').write_text(json.dumps(terminal)+'\n')
    with pytest.raises(EditorialError,match='provider receipt identity differs'):R.recover_unreviewed_draft(round_folder,[TranscriptSource(**source)])
    assert not list(round_folder.glob('attempt-recovered-*'))

@pytest.mark.parametrize('artifact',['START.json','FINISH.json','stream.jsonl','result.json','RESPONSE_SYNTAX_REPAIR.json'])
def test_recovery_refuses_artifact_aliases_before_provider_prompt_or_new_attempt(tmp_path,artifact):
    from editorial_workflow import TranscriptSource
    source,_,_,_=synthetic_review_inputs(tmp_path);round_folder=tmp_path/'round-01'
    folder,_=completed_writer_folder(round_folder,source)
    path=folder/artifact;outside=tmp_path/'unrelated.json'
    original=path.read_bytes() if path.exists() else b'{"unrelated":"do not include"}'
    outside.write_bytes(original)
    if path.exists():path.unlink()
    path.symlink_to(outside)
    with pytest.raises(EditorialError,match='symbolic-link aliases'):R.recover_unreviewed_draft(round_folder,[TranscriptSource(**source)])
    assert outside.read_bytes()==original and not list(round_folder.glob('attempt-recovered-*'))

@pytest.mark.parametrize('payload',['{"decision":"agree","unexpected":true}','{"decision":"agree","decision":"revise"}','{"decision":"agree"}}'])
def test_plain_json_requires_exact_unambiguous_schema(tmp_path,monkeypatch,payload):
    class FakeProcess:
        returncode=0
        def __init__(self,args,**kwargs):self.args=args;self.output=kwargs['stdout']
        def communicate(self,prompt,timeout):
            event={'type':'result','subtype':'success','is_error':False,'session_id':self.args[self.args.index('--session-id')+1],'permission_denials':[],'result':payload}
            self.output.write((json.dumps(event)+'\n').encode());self.output.flush()
    monkeypatch.setattr(R.subprocess,'Popen',FakeProcess)
    with pytest.raises(EditorialError):R.run_turn(tmp_path/'cli',tmp_path/'turn','Synthetic.',R.obj({'decision':{'type':'string','enum':['agree','revise']}}),'No tools.')
    assert not (tmp_path/'turn/result.json').exists()

def completed_synthetic_pair(tmp_path, writer_hash='', writer_decision='revise', limit=10):
    from editorial_workflow import TranscriptSource,RoundLedger,validate_script
    source=TranscriptSource('synthetic-a','a'*64,2,[{'word':'Make','start':.1,'end':.4},{'word':'pizza.','start':.5,'end':1}])
    script={'sections':[{'segments':[{'source_id':source.source_id,'source_sha256':source.source_sha256,'first_word':0,'last_word':1}]}]}
    validated=validate_script(R.canonical_json(script)+b'\n',[source])
    output=tmp_path/'output';output.mkdir()
    ledger=RoundLedger.create(output/'ledger',max_rounds=limit);ledger.complete_transcripts([source])
    attempt=output/'round-01'/'attempt-original';attempt.mkdir(parents=True)
    (attempt/'script.json').write_bytes(validated.script_json)
    for role in ('writer-verdict','adversarial-reviewer'):
        folder=attempt/role;folder.mkdir()
        prompt='Synthetic independent review.\n\n'+json.dumps({'exact_saved_script':script,'script_sha256':validated.script_sha256})+'\n\nThis turn only returns JSON text.\n{}'
        (folder/'prompt.txt').write_text(prompt)
        run={'session_id':role,'receipt_id':role+'-actual-receipt','prompt_sha256':R.sha256(prompt),'exit_code':0,'result_subtype':'success','is_error':False,'session_identity_verified':True,'observed_session_id':role,'permission_denial_count':0,'observed_tools':[]}
        R.save(folder/'START.json',{'session_id':role,'prompt_sha256':R.sha256(prompt)})
        R.save(folder/'FINISH.json',run)
        value={'decision':writer_decision if role=='writer-verdict' else 'revise','script_sha256':writer_hash if role=='writer-verdict' else validated.script_sha256,'issues':[]}
        R.save(folder/'result.json',value)
        terminal={'type':'result','session_id':role,'uuid':run['receipt_id'],'subtype':'success','is_error':False,'permission_denials':[],'result':json.dumps(value)}
        (folder/'stream.jsonl').write_text(json.dumps(terminal)+'\n')
    return output,ledger,source,validated,attempt

def test_input_bound_refusal_counts_once_preserves_original_and_cannot_approve(tmp_path):
    output,ledger,source,validated,attempt=completed_synthetic_pair(tmp_path,limit=1)
    original=(attempt/'writer-verdict/result.json').read_bytes()
    R.reconcile_completed_pairs(output,ledger,[source]);R.check_round_accounting(output,ledger)
    state=ledger.summary()
    assert state['round_count']==1 and state['exhausted_without_approval'] and not state['approved']
    assert any(i['id']==R.INPUT_BINDING_ISSUE for i in state['unresolved_critical'])
    wrapper=json.loads(state['rounds'][0]['writer']['artifact_json'])
    assert wrapper['decision']=='revise' and wrapper['script_sha256']==validated.script_sha256
    assert wrapper['input_bound_provider_refusal']['original_artifact_sha256']==R.sha256(original)
    assert (attempt/'writer-verdict/result.json').read_bytes()==original
    R.reconcile_completed_pairs(output,ledger,[source])
    assert ledger.summary()['round_count']==1

@pytest.mark.parametrize('mutation',['prompt','start_hash','finish_hash','terminal_receipt','saved_result','script'])
def test_input_bound_refusal_rejects_changed_original_evidence(tmp_path,mutation):
    output,ledger,source,validated,attempt=completed_synthetic_pair(tmp_path)
    folder=attempt/'writer-verdict'
    if mutation=='prompt':(folder/'prompt.txt').write_text('Changed prompt.')
    elif mutation in {'start_hash','finish_hash'}:
        path=folder/('START.json' if mutation=='start_hash' else 'FINISH.json')
        data=json.loads(path.read_bytes());data['prompt_sha256']='0'*64;path.write_text(json.dumps(data))
    elif mutation=='terminal_receipt':
        path=folder/'stream.jsonl';data=json.loads(path.read_bytes());data['uuid']='different';path.write_text(json.dumps(data)+'\n')
    elif mutation=='saved_result':
        path=folder/'result.json';data=json.loads(path.read_bytes());data['issues']=[{'id':'forged','description':'Changed.'}];path.write_text(json.dumps(data))
    else:
        path=attempt/'script.json';data=json.loads(path.read_bytes());data['title']='Changed input';path.write_bytes(R.canonical_json(data)+b'\n')
    with pytest.raises(EditorialError):R.reconcile_completed_pairs(output,ledger,[source])
    assert ledger.summary()['round_count']==0 and not ledger.summary()['approved']

def test_unbound_agreement_is_never_downgraded_or_counted(tmp_path):
    output,ledger,source,_,_=completed_synthetic_pair(tmp_path,writer_decision='agree')
    with pytest.raises(EditorialError,match='unbound agreement'):R.reconcile_completed_pairs(output,ledger,[source])
    assert ledger.summary()['round_count']==0

def test_binding_marker_closes_only_with_later_exact_sha_receipt(tmp_path):
    from editorial_workflow import ReviewReceipt
    output,ledger,source,validated,attempt=completed_synthetic_pair(tmp_path)
    R.reconcile_completed_pairs(output,ledger,[source])
    wrapper=json.loads((attempt/'writer-verdict/INPUT_BOUND_REFUSAL.json').read_bytes())
    forged={**wrapper,'issues':[{'id':R.INPUT_BINDING_ISSUE,'description':'Closed by unbound model.','severity':'critical','status':'resolved','resolution':'Assertion','resolved_by':'writer'}]}
    with pytest.raises(EditorialError,match='protected critical'):ReviewReceipt.from_artifact('next-writer','next-receipt',forged)
    writer=ReviewReceipt.from_artifact('next-writer','next-writer-receipt',{'decision':'agree','script_sha256':validated.script_sha256,'issues':[]})
    reviewer=ReviewReceipt.from_artifact('next-reviewer','next-reviewer-receipt',{'decision':'agree','script_sha256':validated.script_sha256,'issues':[]})
    state=ledger.append_round(validated,writer=writer,reviewer=reviewer,round_id='actual-round-02')
    assert state['round_count']==2 and state['approved'] and not state['unresolved_critical']

def test_recovered_actual_receipts_cannot_be_counted_again(tmp_path):
    output,ledger,source,validated,attempt=completed_synthetic_pair(tmp_path)
    R.reconcile_completed_pairs(output,ledger,[source])
    writer=R.completed_input_receipt(attempt/'writer-verdict',validated)
    reviewer=R.completed_input_receipt(attempt/'adversarial-reviewer',validated)
    with pytest.raises(EditorialError,match='unique identity'):
        ledger.append_round(validated,writer=writer,reviewer=reviewer,round_id='duplicate-pair')
    assert ledger.summary()['round_count']==1

def test_larger_prior_seed_is_source_valid_unapproved_material_only(tmp_path):
    from editorial_workflow import TranscriptSource
    source,_,_,_=synthetic_review_inputs(tmp_path)
    folder,value=completed_writer_folder(tmp_path/'round-01',source)
    R.save(folder/'result.json',value)
    seed=R.unapproved_revision_seed(tmp_path,[TranscriptSource(**source)],0)
    assert seed['selected_words']==2 and seed['script']==value['script']
    assert seed['identity_or_editorial_approval'] is False and seed['counts_as_review_round'] is False
    assert R.unapproved_revision_seed(tmp_path,[TranscriptSource(**source)],2) is None
    (folder.parent/'writer-verdict').mkdir()
    assert R.unapproved_revision_seed(tmp_path,[TranscriptSource(**source)],0) is None

def test_revision_seed_rejects_changed_saved_provider_response(tmp_path):
    from editorial_workflow import TranscriptSource
    source,_,_,_=synthetic_review_inputs(tmp_path)
    folder,value=completed_writer_folder(tmp_path/'round-01',source)
    value['script']['title']='Changed but still source-valid'
    R.save(folder/'result.json',value)
    with pytest.raises(EditorialError,match='differs from its original provider response'):
        R.unapproved_revision_seed(tmp_path,[TranscriptSource(**source)],0)

@pytest.mark.parametrize('level',['round','attempt','role'])
def test_completed_pair_rejects_ancestor_alias_before_any_external_write(tmp_path,level):
    output,ledger,source,_,attempt=completed_synthetic_pair(tmp_path)
    path={'round':attempt.parent,'attempt':attempt,'role':attempt/'writer-verdict'}[level]
    outside=tmp_path/('outside-'+level);path.rename(outside);path.symlink_to(outside,target_is_directory=True)
    original={str(p.relative_to(outside)):p.read_bytes() for p in outside.rglob('*') if p.is_file()}
    with pytest.raises(EditorialError,match='alias'):R.reconcile_completed_pairs(output,ledger,[source])
    assert ledger.summary()['round_count']==0
    assert {str(p.relative_to(outside)):p.read_bytes() for p in outside.rglob('*') if p.is_file()}==original

@pytest.mark.parametrize('level',['round','attempt','role'])
def test_revision_seed_rejects_ancestor_alias_before_any_external_write(tmp_path,level):
    from editorial_workflow import TranscriptSource
    source,_,_,_=synthetic_review_inputs(tmp_path)
    output=tmp_path/'output';folder,value=completed_writer_folder(output/'round-01',source)
    R.save(folder/'result.json',value)
    path={'round':folder.parent.parent,'attempt':folder.parent,'role':folder}[level]
    outside=tmp_path/('outside-'+level);path.rename(outside);path.symlink_to(outside,target_is_directory=True)
    original={str(p.relative_to(outside)):p.read_bytes() for p in outside.rglob('*') if p.is_file()}
    with pytest.raises(EditorialError,match='alias'):R.unapproved_revision_seed(output,[TranscriptSource(**source)],0)
    assert {str(p.relative_to(outside)):p.read_bytes() for p in outside.rglob('*') if p.is_file()}==original

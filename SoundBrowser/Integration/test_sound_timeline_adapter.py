import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid
from xml.etree import ElementTree as ET

sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'scripts'))
import config as C
import fcpxml as FX
import timeline_derivatives as D
import sound_timeline_adapter as A

class TimelineIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.library = Path(os.environ['CLAUTO_SFX_TEST_ROOT'])
        cls.temp = tempfile.TemporaryDirectory(prefix='clauto-sound-integration-')
        cls.base = Path(cls.temp.name)
        cls.video = cls.base/'synthetic-silent-video.mp4'
        subprocess.run(['/opt/homebrew/bin/ffmpeg','-nostdin','-v','error','-f','lavfi','-i','color=c=gray:s=320x180:r=24000/1001','-f','lavfi','-i','anullsrc=r=48000:cl=stereo','-t','3','-c:v','libx264','-c:a','aac','-n',str(cls.video)],check=True)
        cls.catalog = json.loads((A.RESOURCES/'catalog.json').read_text())
        cls.asset = next(x for x in cls.catalog['assets'] if x['id']=='BSB-1399')
    @classmethod
    def tearDownClass(cls): cls.temp.cleanup()
    def fixture(self):
        project = self.base/str(uuid.uuid4());project.mkdir()
        exports = project/'cuts/v001/exports';exports.mkdir(parents=True)
        pid,vid = str(uuid.uuid4()),str(uuid.uuid4())
        manifest = dict(schemaVersion=1,id=pid,name='SYNTHETIC SOUND ADAPTER FIXTURE',aspect='16:9',engineVersion=C.ENGINE_VERSION,exportResolution='720p',mutationRevision=1,files=[])
        (project/'clauto-project.json').write_bytes(A.encode(manifest))
        version = dict(id=vid,number=1,label='Synthetic saved parent',engineVersion=C.ENGINE_VERSION,artifacts=['exports/timeline.fcpxml'])
        (project/'cuts/v001/clauto-version.json').write_bytes(A.encode(version))
        (project/'cuts/current.json').write_bytes(A.encode(vid))
        builder = FX.FCPXMLBuilder('Synthetic immutable saved parent','16:9',resolution='720p')
        step = 1001/24000
        builder.write(builder.build([FX.Clip(self.video,0,0,24*step,name='First shot'),FX.Clip(self.video,24*step,24*step,24*step,name='Second shot')],[],[(12*step,'Fixture chapter')]),exports/'timeline.fcpxml')
        asset = self.asset
        ref = dict(schemaVersion=1,libraryID=self.catalog['libraryID'],libraryVersion=self.catalog['version'],assetID=asset['id'],assetURI='sfx://asset/'+asset['id'],expectedSHA256=asset['sha256'],license=asset['license'],sourceDurationSeconds=asset['duration'],auditionStatus=asset['auditionStatus'])
        request = dict(reference=ref,timelineStartFrame=20,sourceStartFrame=3,durationFrames=12,gainDB=-18,frameDurationNumerator=1001,frameDurationDenominator=24000)
        job = dict(schemaVersion=1,id=str(uuid.uuid4()),projectID=pid,parentVersionID=vid,parentTimelineRelativePath='cuts/v001/exports/timeline.fcpxml',parentTimelineSHA256=A.sha((exports/'timeline.fcpxml').read_bytes()),parentVersionSHA256=A.sha((project/'cuts/v001/clauto-version.json').read_bytes()),expectedCurrentID=vid,request=request)
        return project,job
    def test_real_sound_insertion_crosses_shot_boundary_and_preserves_parent(self):
        project,job = self.fixture()
        paths = ['clauto-project.json','cuts/current.json','cuts/v001/clauto-version.json','cuts/v001/exports/timeline.fcpxml']
        before = {p:(project/p).read_bytes() for p in paths}
        original = (self.library/self.asset['relativePath']).read_bytes()
        receipt = A.insert(project,self.library,job)
        out = project/'build/derivatives'/job['id']
        self.assertTrue(receipt['structuralRoundTripPassed']);self.assertFalse(receipt['previewRendered']);self.assertFalse(receipt['admittedToEditorHistory'])
        self.assertEqual({p:(project/p).read_bytes() for p in paths},before)
        self.assertEqual((out/'source-asset.wav').read_bytes(),original)
        self.assertEqual((self.library/self.asset['relativePath']).read_bytes(),original)
        self.assertEqual(FX.validate(out/'timeline.fcpxml'),[])
        duration,primary,connected,chapters,_ = D.read_timeline(out/'timeline.fcpxml')
        self.assertEqual(len(primary),2);self.assertEqual(len(connected),1)
        self.assertEqual([[C.frames(x.at),C.frames(x.start),C.frames(x.duration)] for x in connected],[[20,3,12]])
        for cue in connected:
            self.assertLess(cue.lane,0);self.assertTrue(cue.audio_only);self.assertEqual(cue.role,'effects.foley');self.assertEqual(cue.gain_db,-18)
        self.assertEqual(len(chapters),1)
        self.assertEqual(A.insert(project,self.library,job),receipt)
        changed = copy.deepcopy(job);changed['request']['gainDB']=-12
        with self.assertRaisesRegex(ValueError,'immutable'): A.insert(project,self.library,changed)
        (out/'timeline.fcpxml').write_bytes((out/'timeline.fcpxml').read_bytes()+b'\n')
        with self.assertRaisesRegex(ValueError,'changed'): A.insert(project,self.library,job)
    def test_stale_parent_current_pointer_hash_and_version_are_refused(self):
        for field,value in [('parentTimelineSHA256','0'*64),('parentVersionSHA256','0'*64),('expectedCurrentID',str(uuid.uuid4()))]:
            project,job = self.fixture();job[field]=value
            with self.assertRaisesRegex(ValueError,'Saved cut'): A.insert(project,self.library,job)
            self.assertFalse((project/'build/derivatives'/job['id']/'sound-timeline-adapter.json').exists())
        project,job = self.fixture();job['request']['reference']['libraryVersion']='2.0.0'
        with self.assertRaisesRegex(ValueError,'Reference'): A.insert(project,self.library,job)
    def test_invalid_placements_and_gain_never_publish(self):
        for field,value in [('timelineStartFrame',47),('sourceStartFrame',1000),('durationFrames',0),('gainDB',float('nan')),('frameDurationDenominator',24)]:
            project,job = self.fixture();job['request'][field]=value
            with self.assertRaises(ValueError): A.insert(project,self.library,job)
            self.assertFalse((project/'build/derivatives'/job['id']/'sound-timeline-adapter.json').exists())
    def test_cancel_or_changed_current_during_work_cannot_publish(self):
        project,job = self.fixture();parent = (project/job['parentTimelineRelativePath']).read_bytes()
        def cancel(): raise KeyboardInterrupt('Fixture cancellation')
        with self.assertRaises(KeyboardInterrupt): A.insert(project,self.library,job,before_publish=cancel)
        self.assertFalse((project/'build/derivatives'/job['id']/'sound-timeline-adapter.json').exists())
        self.assertEqual((project/job['parentTimelineRelativePath']).read_bytes(),parent)
        project,job = self.fixture()
        def change(): (project/'cuts/current.json').write_bytes(A.encode(str(uuid.uuid4())))
        with self.assertRaisesRegex(ValueError,'Inputs changed'): A.insert(project,self.library,job,before_publish=change)
        self.assertFalse((project/'build/derivatives'/job['id']/'sound-timeline-adapter.json').exists())
    def test_missing_tampered_and_symlink_libraries_are_refused(self):
        project,job = self.fixture();library = self.base/str(uuid.uuid4());library.mkdir()
        (library/'asset-library.json').write_bytes((self.library/'asset-library.json').read_bytes())
        target = library/self.asset['relativePath'];target.parent.mkdir(parents=True)
        target.symlink_to(self.library/self.asset['relativePath'])
        with self.assertRaises(OSError): A.insert(project,library,job)
        target.unlink();target.write_bytes(b'bad')
        with self.assertRaisesRegex(ValueError,'hash mismatch'): A.insert(project,library,job)
        target.unlink()
        with self.assertRaises(FileNotFoundError): A.insert(project,library,job)
    def test_root_replacement_and_lock_conflict_do_not_publish(self):
        project,job = self.fixture()
        def replace():
            project.rename(project.with_name(project.name+'-old'));project.mkdir()
        with self.assertRaises(ValueError): A.insert(project,self.library,job,before_publish=replace)
        self.assertFalse((project/'build').exists())
        project,job = self.fixture()
        with A.lease(A.Directory(project)):
            with self.assertRaisesRegex(ValueError,'Another window'): A.insert(project,self.library,job)

if __name__=='__main__': unittest.main(verbosity=2)

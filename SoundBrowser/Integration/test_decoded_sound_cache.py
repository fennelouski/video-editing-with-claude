import fcntl
import os
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import decoded_sound_cache as C

class CacheTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory();cls.root=Path(cls.temp.name)
        ogg=cls.root/'probe.ogg'
        subprocess.run(['/opt/homebrew/bin/ffmpeg','-nostdin','-v','error','-f','lavfi','-i','sine=frequency=440:sample_rate=48000:duration=1','-c:a','libvorbis',str(ogg)],check=True)
        cls.original=ogg.read_bytes()
    @classmethod
    def tearDownClass(cls):cls.temp.cleanup()
    def setUp(self):
        self.cache=Path(tempfile.mkdtemp(dir=self.root))
        self.args=dict(asset_id='synthetic-codec-fixture',expected_sha256=hashlib.sha256(self.original).hexdigest(),duration=1.,sample_rate=48000,channels=1,cache_root=self.cache,decoder='/opt/homebrew/bin/ffmpeg')
    def test_decode_cache_reuse_preserves_original_identity(self):
        pcm,receipt=C.decode(self.original,**self.args)
        self.assertEqual(receipt['identity']['originalSHA256'],self.args['expected_sha256'])
        self.assertNotEqual(receipt['decodedSHA256'],self.args['expected_sha256'])
        self.assertEqual(receipt['humanAudition'],'NOT_AUDITIONED')
        self.assertEqual(receipt['pcm']['sampleRate'],48000)
        self.assertAlmostEqual(receipt['pcm']['duration'],1,places=2)
        before={str(p):p.stat().st_mtime_ns for p in self.cache.rglob('*') if p.is_file() and p.name!='decode.lock'}
        self.assertEqual(C.decode(self.original,**self.args),(pcm,receipt))
        self.assertEqual(before,{str(p):p.stat().st_mtime_ns for p in self.cache.rglob('*') if p.is_file() and p.name!='decode.lock'})
        self.assertFalse(list(self.cache.rglob('original.ogg')))
    def test_tampered_pcm_is_refused(self):
        C.decode(self.original,**self.args)
        next(self.cache.rglob('decoded.wav')).write_bytes(b'bad')
        with self.assertRaises(Exception):C.decode(self.original,**self.args)
    def test_wrong_hash_and_metadata_do_not_publish(self):
        for key,value in [('expected_sha256','0'*64),('channels',2),('sample_rate',44100),('duration',.5),('duration',3601)]:
            args=self.args|{key:value}
            with self.assertRaises(ValueError):C.decode(self.original,**args)
            self.assertFalse(list(self.cache.glob('pending-*')))
            self.assertFalse(list(self.cache.glob('*/receipt.json')))
    def test_symlink_cache_and_decoder_missing_fail(self):
        alias=self.root/'alias';alias.symlink_to(self.cache)
        with self.assertRaises(OSError):C.decode(self.original,**(self.args|{'cache_root':alias}))
        with self.assertRaises(ValueError):C.decode(self.original,**(self.args|{'decoder':'/missing/ffmpeg'}))
    def test_cancellation_before_publication_cleans_snapshot(self):
        calls=0
        def cancel():
            nonlocal calls
            calls+=1
            if calls==3:raise InterruptedError('Cancelled fixture')
        with self.assertRaises(InterruptedError):C.decode(self.original,**self.args,cancel_check=cancel)
        self.assertFalse(list(self.cache.glob('pending-*')))
        self.assertFalse(list(self.cache.glob('*/receipt.json')))
    def test_public_adapter_refuses_unknown_or_non_ogg_asset(self):
        for asset_id in ['unknown','BSB-2278']:
            with self.assertRaises(ValueError):C.decode_catalog_asset(library_root=self.root,asset_id=asset_id,cache_root=self.cache,decoder='/opt/homebrew/bin/ffmpeg')
        self.assertFalse(list(self.cache.iterdir()))
    def test_busy_cache_fails_without_waiting_or_publication(self):
        with open(self.cache/'decode.lock','wb') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError):C.decode(self.original,**self.args)
        self.assertFalse(list(self.cache.glob('*/receipt.json')))
    def test_symlinked_decoded_entry_is_refused(self):
        pcm,_=C.decode(self.original,**self.args)
        target=next(self.cache.rglob('decoded.wav'));outside=self.root/'outside.wav';outside.write_bytes(pcm)
        target.unlink();target.symlink_to(outside)
        with self.assertRaises(OSError):C.decode(self.original,**self.args)
    def test_cli_returns_structured_refusal_without_decoder_work(self):
        result=subprocess.run([sys.executable,str(Path(C.__file__)), '--library-root',str(self.root),'--asset-id','BSB-2278','--cache-root',str(self.cache),'--decoder','/opt/homebrew/bin/ffmpeg'],capture_output=True,text=True)
        self.assertEqual(result.returncode,1)
        self.assertEqual(json.loads(result.stdout)['state'],'failed')
        self.assertNotIn('Traceback',result.stderr)
    def test_failed_decoder_cleans_partial_cache(self):
        damaged=b'OggS'+b'bad'*50
        with self.assertRaises(subprocess.CalledProcessError):C.decode(damaged,**(self.args|{'expected_sha256':hashlib.sha256(damaged).hexdigest()}))
        self.assertFalse(list(self.cache.glob('pending-*')))
        self.assertFalse(list(self.cache.glob('*/receipt.json')))

if __name__=='__main__':unittest.main(verbosity=2)

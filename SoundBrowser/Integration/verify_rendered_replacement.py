"""Silent PCM verification for the isolated normal-export test; never plays audio."""
from array import array
import json
import math
import subprocess
import sys

def samples(path, filters=None):
    args=['/opt/homebrew/bin/ffmpeg','-nostdin','-v','error','-i',path,'-vn','-ac','1','-ar','48000']
    if filters:args+=['-af',filters]
    raw=subprocess.run(args+['-f','f32le','pipe:1'],check=True,stdout=subprocess.PIPE).stdout
    result=array('f');result.frombytes(raw);return result

movie,new,old=sys.argv[1:]
actual=samples(movie)[10*2002:34*2002]
filters='aresample=48000,atrim=start_sample=40040:end_sample=88088,asetpts=PTS-STARTPTS,volume=-15dB'
expected=samples(new,filters);previous=samples(old,filters)
def compare(a,b):
    a,b=a[1000:-1000],b[1000:-1000]
    count=min(len(a),len(b));a,b=a[:count],b[:count]
    aa=sum(x*x for x in a);bb=sum(x*x for x in b)
    return sum(x*y for x,y in zip(a,b))/math.sqrt(aa*bb),math.sqrt(aa/bb)
corr,gain=compare(actual,expected);old_corr,_=compare(actual,previous)
report=dict(replacementCorrelation=corr,amplitudeRatio=gain,previousSoundCorrelation=old_corr,automatedPlaybackStarts=0)
print(json.dumps(report,sort_keys=True))
assert corr>.98 and .90<gain<1.10 and abs(old_corr)<.80,report

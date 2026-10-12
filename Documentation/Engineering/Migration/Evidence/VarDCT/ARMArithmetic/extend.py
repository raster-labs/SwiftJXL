"""Bounded forced-large diagnostic; preserve original acceptance files."""
from pathlib import Path
import subprocess, os, struct, math, json, hashlib
root=Path(__file__).resolve().parent
base=root.parent/'encoder-large-writer'
out=root/'remaining-large';out.mkdir(exist_ok=True)
commands=[];results=[];hashes={}
def record(path): hashes[str(path)]=hashlib.sha256(path.read_bytes()).hexdigest()
def run(cmd, env=None):
 r=subprocess.run(list(map(str,cmd)),env=env,capture_output=True,text=True)
 commands.append(dict(command=list(map(str,cmd)),environment={'BIAS_MODE':env['BIAS_MODE']} if env else {},exit=r.returncode,stdout=r.stdout,stderr=r.stderr))
 if r.returncode: raise RuntimeError(commands[-1])
def pixels(path,floating=False):
 record(path);b=path.read_bytes();v=struct.unpack('<'+('f' if floating else 'H')*(len(b)//(4 if floating else 2)),b)
 return [int(min(1,max(0,x))*65535+.5) for x in v] if floating else v
def compare(a,b):
 assert len(a)==len(b)
 d=[x-y for x,y in zip(a,b)]
 return dict(samples=len(d),peakLSB=max(map(abs,d)),rmsLSB=math.sqrt(sum(x*x for x in d)/len(d)),differentSamples=sum(x!=0 for x in d))
for i in [5,6,7,8,9,10,11,18,19,20]:
 name=f'writer-{i}';source=base/(name+'.jxl');record(source)
 armfile=out/(name+'.arm-float');run([root.parent/'pixel-oracle-float','decode-float',source,armfile]);arm=pixels(armfile,True)
 original=pixels(base/(name+'.decoded'));integer=pixels(base/(name+'.oracle'));scalar=pixels(base/(name+'.scalar'),True)
 row=dict(name=name,armIntegerVsArmFloatNearest=compare(integer,arm),scalarVsArmFloatNearest=compare(scalar,arm),variants={})
 for mode in ['original','approx-unfused']:
  f=out/(name+'.'+mode+'.decoded');run([root/'.build/debug/BiasProbe',source,f],dict(os.environ,BIAS_MODE=mode));v=pixels(f)
  row['variants'][mode]=dict(vsArmFloatNearest=compare(v,arm),vsArmInteger=compare(v,integer),vsSavedSwift=compare(v,original))
 results.append(row)
for f in [root/'.build/debug/BiasProbe',root.parent/'pixel-oracle-float',Path(__file__)]:record(f)
for name,value in [('results',results),('commands',commands),('sha256',hashes)]: (out/(name+'.json')).write_text(json.dumps(value,indent=2)+'\n')
print(json.dumps(results,indent=2))

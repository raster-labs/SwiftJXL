from pathlib import Path
import subprocess,json,struct,math
root=Path('work/vardct-preflight');out=root/'encoder-dct8';results=[]
for item in json.loads((out/'results.json').read_text()):
 name=item['name'];bits=int(item['bits']);channels=int(item['channels']);step=bits//8;maximum=(1<<bits)-1;r={'name':name}
 if item['status']!='accepted':r['status']=item['status'];results.append(r);continue
 outputs=[('neonInteger',root/'pixel-oracle','decode',out/(name+'.oracle')),('scalarFloatNearest',root/'pixel-oracle-reference-scalar','decode-float',out/(name+'.scalar'))]
 actual=list((out/(name+'.decoded')).read_bytes()) if step==1 else list(struct.unpack('<'+'H'*((out/(name+'.decoded')).stat().st_size//2),(out/(name+'.decoded')).read_bytes()))
 source=list((out/(name+'.input')).read_bytes()) if step==1 else list(struct.unpack('<'+'H'*((out/(name+'.input')).stat().st_size//2),(out/(name+'.input')).read_bytes()))
 for label,exe,mode,path in outputs:
  check=subprocess.run([str(exe),mode,str(out/(name+'.jxl')),str(path)],capture_output=True,timeout=30)
  if check.returncode:r[label]={'exitCode':check.returncode,'stderr':check.stderr.decode()[-400:]};continue
  raw=path.read_bytes()
  expected=[int(min(1,max(0,v))*maximum+.5) for v in struct.unpack('<'+'f'*(len(raw)//4),raw)] if label=='scalarFloatNearest' else (list(raw) if step==1 else list(struct.unpack('<'+'H'*(len(raw)//2),raw)))
  if len(expected)!=len(actual):r[label]={'sampleCountMismatch':[len(expected),len(actual)]};continue
  differences=[abs(a-b) for i,(a,b) in enumerate(zip(actual,expected)) if channels%2 or i%channels!=channels-1]
  alpha=all(a==b==source[i] for i,(a,b) in enumerate(zip(actual,expected)) if channels%2==0 and i%channels==channels-1)
  rms=math.sqrt(sum(e*e for e in differences)/len(differences));peak=max(differences)
  r[label]={'exitCode':0,'peakLSB':peak,'rmsLSB':rms,'alphaExact':alpha,'passed':peak<=2 and rms<=.5 and alpha}
 differences=[abs(a-b)/maximum for i,(a,b) in enumerate(zip(actual,source)) if channels%2 or i%channels!=channels-1]
 r['sourceDistortionDiagnostic']={'peakNormalised':max(differences),'rmsNormalised':math.sqrt(sum(e*e for e in differences)/len(differences))}
 results.append(r)
(out/'independent-oracles.json').write_text(json.dumps(results,indent=2)+'\n')
for label in ['neonInteger','scalarFloatNearest']:print(label,sum(v.get(label,{}).get('passed',False) for v in results),'/',len(results))
for v in results:
 if not v.get('scalarFloatNearest',{}).get('passed',False):print(v)

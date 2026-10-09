from pathlib import Path
import subprocess,json,hashlib,time
root=Path('../native-jpeg-audit/results').resolve();root.mkdir(exist_ok=False)
legacy=Path('../JXLSwift/.build/out/Products/Release/jxl-tool').resolve()
tools={n:Path('/opt/homebrew/bin')/n for n in ['cjpeg','cjxl','djxl']}
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
report={'predecessor':'57e81cb9e2411d1efac435b429a306a031744c1e','legacy_binary_sha256':sha(legacy),'tools':{k:{'sha256':sha(v),'path':str(v)} for k,v in tools.items()},'fixtures':[],'status':'running'}
def save():(root/'report.json').write_text(json.dumps(report,indent=2)+'\n')
def run(label,argv):
 start=time.monotonic()
 try:
  r=subprocess.run(list(map(str,argv)),capture_output=True,timeout=30)
  record={'command':list(map(str,argv)),'exit':r.returncode,'seconds':time.monotonic()-start,'stderr':r.stderr.decode(errors='replace')[-4000:]}
 except subprocess.TimeoutExpired:record={'command':list(map(str,argv)),'exit':'timeout','seconds':time.monotonic()-start}
 return record
variants=[('gray',True,[],None),('444',False,['-sample','1x1,1x1,1x1'],None),('422',False,['-sample','2x1,1x1,1x1'],None),('420',False,['-sample','2x2,1x1,1x1'],None),('440',False,['-sample','1x2,1x1,1x1'],None),('progressive',False,['-progressive'],None),('restart',False,['-restart','1B'],None),('metadata-tail',False,[], 'metadata'),('fill-marker',False,[], 'fill')]
for name,gray,extra,mutation in variants:
 d=root/name;d.mkdir();channels=1 if gray else 3;w,h=31,17
 pnm=d/('input.pgm' if gray else 'input.ppm');pnm.write_bytes(f'{"P5" if gray else "P6"}\n{w} {h}\n255\n'.encode()+bytes((i*19+i//7*31)%256 for i in range(w*h*channels)))
 jpg=d/'source.jpg'
 generated=run('generate',[tools['cjpeg'],'-outfile',jpg,'-quality','80',*extra,pnm]);assert generated['exit']==0,generated
 original=jpg.read_bytes()
 if mutation=='metadata':
  payload=b'synthetic comment';segment=b'\xff\xfe'+(len(payload)+2).to_bytes(2,'big')+payload
  original=original[:2]+segment+original[2:]+b'SYNTHETIC-TAIL'
 if mutation=='fill':original=original[:2]+b'\xff'+original[2:]
 jpg.write_bytes(original)
 item={'name':name,'source_sha256':sha(jpg),'bytes':len(original),'checks':{'fixture':generated}}
 ours=d/'legacy.jxl';ref=d/'reference.jxl'
 item['checks']['legacy_forward']=run('legacy_forward',[legacy,'transcode',jpg,ours,'--mode','coefficient-bridge'])
 item['checks']['reference_forward']=run('reference_forward',[tools['cjxl'],jpg,ref,'--lossless_jpeg=1','-e','3'])
 for source,label in [(ours,'legacy'),(ref,'reference')]:
  if not source.exists():continue
  for decoder in ['legacy','reference']:
   output=d/(label+'-'+decoder+'.jpg')
   argv=[legacy,'transcode',source,output,'--mode','reverse'] if decoder=='legacy' else [tools['djxl'],source,output]
   r=run(label+'_'+decoder,argv)
   r['exact_bytes']=output.exists() and output.read_bytes()==original
   if output.exists():r['output_sha256']=sha(output);r['output_bytes']=output.stat().st_size
   item['checks'][label+'_'+decoder]=r
 report['fixtures'].append(item);save()
 print(name,[(k,r['exit'],r.get('exact_bytes')) for k,r in item['checks'].items() if k!='fixture'],flush=True)
report['status']='baseline_recorded';save()

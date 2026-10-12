#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Run separate optimised probes in ABBA order; preserve raw timings and invalid baselines."""
import argparse,hashlib,json,math,os,statistics,subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True);p.add_argument('--predecessor',type=Path,required=True);p.add_argument('--djxl',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
p.add_argument('--cases',type=Path,help='JSON rows: name,width,height,channels,bits,pattern')
p.add_argument('--serial-predecessor',type=Path,help='Diagnostic predecessor with only parallelMap serialised')
p.add_argument('--operations',nargs='+',choices=['encode','decode','caller'],default=['encode','decode','caller'])
p.add_argument('--preflight-only',action='store_true',help='Validate generated streams without collecting timing samples')
p.add_argument('--candidate-workers',type=int,choices=range(1,9),default=1,help='Successor encoder worker ceiling; defaults to the historical serial comparison')
a=p.parse_args()
if a.preflight_only:a.operations=[]
a.output.mkdir(parents=True,exist_ok=False)
probes={'candidate':a.candidate.resolve(),'predecessor':a.predecessor.resolve()}
if a.serial_predecessor:probes['serial-predecessor']=a.serial_predecessor.resolve()
order=['predecessor','serial-predecessor','candidate','candidate','serial-predecessor','predecessor'] if a.serial_predecessor else ['predecessor','candidate','candidate','predecessor']
report={'status':'running','order':order,'method':'Two interleaved blocks per implementation;5 warmups and10 timed iterations per block. Separate process per operation/block. No sanitizers. Decode uses the same independently verified candidate codestream. Serial predecessor is diagnostic only.','cases':[],'binaries':{k:hashlib.sha256(v.read_bytes()).hexdigest() for k,v in probes.items()}}
report['candidateWorkers']=a.candidate_workers
def save(): (a.output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
def run(args,log):
 r=subprocess.run(list(map(str,args)),capture_output=True,text=True,timeout=600,env={**os.environ,'MODULAR_BENCH_PATTERN':pattern,'MODULAR_BENCH_WORKERS':str(a.candidate_workers)})
 log.write_text(r.stdout+r.stderr)
 return r
cases=json.loads(a.cases.read_text()) if a.cases else [('small-rgb8',31,17,3,8,'ramp'),('gray16',512,512,1,16,'ramp'),('rgb8',256,257,3,8,'ramp'),('group-rgb8',513,259,3,8,'ramp'),('group-rgba16',513,259,4,16,'ramp')]
for name,w,h,c,bits,pattern in cases:
 assert pattern in ['ramp','flat','noise'] and 1<=w<=4096 and 1<=h<=4096 and 1<=c<=4 and bits in [8,16]
 case={'name':name,'width':w,'height':h,'channels':c,'bits':bits,'pattern':pattern,'preflight':{},'runs':[],'summaries':{}}
 report['cases'].append(case);save()
 paths={};valid={};maximum=(1<<bits)-1
 expected=bytearray();random=20261012
 for i in range(w*h):
  for channel in range(c):
   random=(random*1664525+1013904223)&0xffffffff
   value=maximum//3 if pattern=='flat' else (random>>8)&maximum if pattern=='noise' else (i*71+(i//w)*37+channel*113)&maximum
   expected.extend(value.to_bytes(bits//8,'big'))
 for kind,probe in probes.items():
  path=a.output/f'{name}-{kind}.jxl';paths[kind]=path
  command=[probe,'encode',w,h,c,bits,0,path]
  prepared=run(command,a.output/f'{name}-{kind}-prepare.log')
  if prepared.returncode:
   case['preflight'][kind]={'status':'failed','stage':'native preparation','exit':prepared.returncode};valid[kind]=False;continue
  output=a.output/f'{name}-{kind}.pam'
  oracle=run([a.djxl,path,output,f'--bits_per_sample={bits}','--quiet'],a.output/f'{name}-{kind}-oracle.log')
  exact=oracle.returncode==0 and output.read_bytes().endswith(expected)
  valid[kind]=exact
  case['preflight'][kind]={'status':'passed' if exact else 'failed','oracleExit':oracle.returncode,'exactSamples':exact,'codestreamSHA256':hashlib.sha256(path.read_bytes()).hexdigest(),'encodedBytes':path.stat().st_size}
  save()
 if not valid.get('candidate'):raise RuntimeError(f'Candidate fidelity failed: {name}')
 for operation in a.operations:
  for block,kind in enumerate(order):
   if operation=='caller' and kind!='candidate':continue
   if operation=='encode' and not valid.get(kind):continue # Never time invalid encoding as an accepted baseline.
   if not paths[kind].exists():continue
   dest=a.output/f'{name}-{kind}-{operation}-{block}.jxl'
   command=[probes[kind],operation,w,h,c,bits,10,dest,paths['candidate']]
   result=run(command,a.output/f'{name}-{kind}-{operation}-{block}.log')
   entry={'implementation':kind,'operation':operation,'block':block,'command':list(map(str,command)),'exit':result.returncode}
   if result.returncode==0:entry['result']=json.loads(result.stdout)
   else:entry['status']='failed; no accepted timing'
   case['runs'].append(entry);save()
   if kind=='candidate' and result.returncode:raise RuntimeError(f'Candidate operation failed: {name}/{operation}')
 for kind in probes:
  for operation in ['encode','decode','caller']:
   runs=[r['result'] for r in case['runs'] if r['implementation']==kind and r['operation']==operation and r['exit']==0]
   times=[x for r in runs for x in r['milliseconds']]
   if not times:continue
   ordered=sorted(times);median=statistics.median(times)
   case['summaries'][kind+'/'+operation]={'warmups':sum(r['warmups'] for r in runs),'iterations':len(times),'medianMS':median,'p95MS':ordered[math.ceil(len(times)*.95)-1],'minMS':min(times),'maxMS':max(times),'pixelsPerSecond':w*h*1000/median,'processPeakRSSBytes':max(r['processPeakRSSBytes'] for r in runs),'thermalStates':sorted({r[k] for r in runs for k in ['thermalStart','thermalEnd']})}
 for operation in ['encode','decode']:
  old=case['summaries'].get('predecessor/'+operation);new=case['summaries'].get('candidate/'+operation)
  if old and new:
   new['medianChangePercent']=100*(new['medianMS']/old['medianMS']-1)
   new['requiresInvestigation']=new['medianChangePercent']>5
  serial=case['summaries'].get('serial-predecessor/'+operation)
  if serial and new:new['medianChangeVersusSerialPercent']=100*(new['medianMS']/serial['medianMS']-1)
 save()
 print(name,case['preflight'],case['summaries'],flush=True)
report['status']='completed';save()

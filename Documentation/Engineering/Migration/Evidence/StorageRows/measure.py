from pathlib import Path
import json,os,select,statistics,subprocess,sys,time

w=Path(__file__).resolve().parent;label=sys.argv[1];out=w/label;out.mkdir(exist_ok=False)
names=sys.argv[2:] if len(sys.argv)>=4 else ['baseline','current'];records=[];processes={};resources={}
try:
 for name in names:
  resources[name]=(out/(name+'-resources.log')).open('w')
  processes[name]=subprocess.Popen(['/usr/bin/time','-l',str(w/name/'probe')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=resources[name],text=True,bufsize=1,env=dict(os.environ,SWIFT_DETERMINISTIC_HASHING='1'))
 def run(name,width):
  p=processes[name];p.stdin.write(str(width)+'\n');p.stdin.flush()
  assert select.select([p.stdout],[],[],240)[0],(name,width,'deadline')
  line=p.stdout.readline();assert line,(name,p.poll())
  return json.loads(line)
 for width in [64,512,2048]:
  for _ in range(5):
   for name in names:run(name,width)
  for iteration in range(20):
   order=names if (iteration+('confirmation' in label))%2==0 else names[::-1]
   for name in order:
    r=dict(name=name,width=width,iteration=iteration,**run(name,width))
    r['total_ns']=r['allocate_ns']+r['write_ns']+r['read_ns'];records.append(r)
    (out/'raw.json').write_text(json.dumps(records,indent=2)+'\n')
  print(label,width,'complete',flush=True)
 exits={}
 for name,p in processes.items():
  p.stdin.close();exits[name]=p.wait(timeout=30);resources[name].close()
 assert all(x==0 for x in exits.values()),exits
 summary=[]
 for width in [64,512,2048]:
  for metric in ['allocate_ns','write_ns','read_ns','total_ns']:
   values={name:[r[metric] for r in records if r['name']==name and r['width']==width] for name in names}
   medians={name:statistics.median(v) for name,v in values.items()}
   summary.append(dict(width=width,metric=metric,medians=medians,changePercent=100*(medians[names[-1]]/medians[names[0]]-1),p95={name:sorted(v)[18] for name,v in values.items()},minimum={name:min(v) for name,v in values.items()},maximum={name:max(v) for name,v in values.items()}))
 result={'method':'Original public greyscale16 storage probe renamed from SwiftJ2K to SwiftJXL. Same-host same-compiler -O WMO builds; 5 warmups then 20 interleaved samples per implementation per size. Separate fresh process pair for confirmation; order reversed. Comparators are identified by recorded source hashes. A full historical/current comparison is not an isolated span effect; candidate differences apply only to the recorded current-source patch.','builds':{name:json.loads((w/name/'build.json').read_text()) for name in names},'exitCodes':exits,'summary':summary,'records':records,'unmeasured':['Peak algorithm workspace','Direct allocation/copy telemetry','Physical device and minimum OS runtime','Codec throughput']}
 (out/'result.json').write_text(json.dumps(result,indent=2)+'\n')
 print(json.dumps(summary,indent=2),flush=True)
finally:
 for p in processes.values():
  if p.poll() is None:p.terminate()

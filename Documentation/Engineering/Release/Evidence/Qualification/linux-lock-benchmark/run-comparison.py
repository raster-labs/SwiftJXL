import datetime
import hashlib
import json
from pathlib import Path
import statistics
import subprocess
import time

root = Path(__file__).resolve().parent
output = root/'comparison'
output.mkdir(exist_ok=False)
image = 'swift@sha256:bca121f6eb59fd80340d1296887b2698ed8f3eb9eca7d80c181f8af769dc7ee0'
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
binaries = {name: root/(name+'-client/.build/release/Probe') for name in ('baseline','candidate')}
report = {'status':'running','startedUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),
          'image':image,'architecture':'aarch64','cpuset':'0-3','warmups':3,'timedIterations':10,
          'rounds':['ABBA','BAAB'],'baselineRevision':(root/'baseline-revision.txt').read_text().strip(),
          'candidateRevision':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),
          'binarySHA256':{name:sha(path) for name,path in binaries.items()},
          'benchmarkSourceSHA256':sha(root/'candidate-client/Sources/Probe/Probe.swift'),
          'driverSHA256':sha(Path(__file__)), 'rows':[], 'runs':[], 'regressionTriggers':[],
          'scope':'Controlled local native Linux ARM64 release comparison of the Linux lock change. Synthetic512x512RGB16; public API encode/decode latency and whole-process peakRSS. No general performance, heap-allocation or exact-workspace claim.'}
def save(): (output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
save()
try:
    for family in ['modular','vardct']:
        for operation in ['encode','decode']:
            for workers in [1,4]:
                name=f'{family}-{operation}-w{workers}'
                row={'case':name,'rounds':[]}
                hashes=set()
                for round_index, order in enumerate(['ABBA','BAAB']):
                    measurements={'baseline':[],'candidate':[]}
                    for index, letter in enumerate(order):
                        side='baseline' if letter=='A' else 'candidate'
                        label=f'{name}-r{round_index}-{index}-{side}'
                        prefix='/work/comparison/'+label
                        command=['docker','run','--rm','--network','none','--cpuset-cpus','0-3',
                                 '-e','SWIFT_DETERMINISTIC_HASHING=1','-v',str(root)+':/work','-w','/work',image,
                                 '/work/'+side+'-client/.build/release/Probe',family,operation,str(workers),'512','10',prefix]
                        start=time.monotonic()
                        result=subprocess.run(command,capture_output=True,text=True,timeout=300)
                        raw={'command':command,'exitCode':result.returncode,'stdout':result.stdout,
                             'stderr':result.stderr,'seconds':time.monotonic()-start}
                        path=output/(label+'.json');path.write_text(json.dumps(raw,indent=2)+'\n')
                        assert result.returncode==0,(label,result.stdout,result.stderr)
                        data=json.loads(result.stdout)
                        assert data['iterations']==10 and data['warmups']==3 and data['workers']==workers
                        assert len(data['milliseconds'])==10 and all(value>0 for value in data['milliseconds'])
                        digest=(sha(output/(label+'.jxl')),sha(output/(label+'.raw')))
                        hashes.add(digest)
                        item={'side':side,'raw':path.name,'rawSHA256':sha(path),
                              'latencyMedianMS':statistics.median(data['milliseconds']),
                              'latencyMinMS':min(data['milliseconds']),'latencyMaxMS':max(data['milliseconds']),
                              'peakRSSBytes':data['processPeakRSSBytes'],'encodedBytes':data['encodedBytes'],
                              'encodedSHA256':digest[0],'decodedSHA256':digest[1]}
                        measurements[side].append(item);report['runs'].append(item);save()
                    round_result={'order':order,'measurements':measurements}
                    for field in ['latencyMedianMS','peakRSSBytes']:
                        a=statistics.median(item[field]for item in measurements['baseline'])
                        b=statistics.median(item[field]for item in measurements['candidate'])
                        round_result[field]={'baseline':a,'candidate':b,'ratio':b/a}
                    row['rounds'].append(round_result)
                assert len(hashes)==1,(name,'Compressed bytes or decoded samples changed')
                row['identicalCompressedAndDecodedBytes']=True
                for field in ['latencyMedianMS','peakRSSBytes']:
                    row[field+'RepeatedRegression']=all(item[field]['ratio']>1.05 for item in row['rounds'])
                    if row[field+'RepeatedRegression']:report['regressionTriggers'].append({'case':name,'metric':field})
                report['rows'].append(row);save();print(name,'complete',flush=True)
    assert all(sha(path)==report['binarySHA256'][name]for name,path in binaries.items())
    report['status']='passed' if not report['regressionTriggers'] else 'investigation-required'
except Exception as error:
    report.update(status='failed',error=str(error))
report['finishedUTC']=datetime.datetime.now(datetime.timezone.utc).isoformat();save()
print(json.dumps({'status':report['status'],'triggers':report['regressionTriggers']}))
raise SystemExit(0 if report['status']=='passed' else 1)

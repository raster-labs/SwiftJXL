from pathlib import Path
import subprocess,hashlib,json
root=Path('Tests/SwiftJXLCoreTests/Fixtures/JPEG');work=Path('../native-jpeg-audit/extended');work.mkdir(exist_ok=True)
source=work/'input.ppm';w=h=17
source.write_bytes(f'P6\n{w} {h}\n255\n'.encode()+bytes((i*19+i//7*31)%256 for i in range(w*h*3)))
scans=work/'dc-refine.scans'
scans.write_text('0: 0 0 0 1;\n1: 0 0 0 1;\n2: 0 0 0 1;\n0: 1 63 0 0;\n1: 1 63 0 0;\n2: 1 63 0 0;\n0: 0 0 1 0;\n1: 0 0 1 0;\n2: 0 0 1 0;\n')
sequential=work/'sequential.scans';sequential.write_text('0;\n1;\n2;\n')
variants={'progressive-edge':['-progressive'],'progressive-restart':['-progressive','-restart','1B'],'progressive-422':['-progressive','-sample','2x1,1x1,1x1'],'progressive-440':['-progressive','-sample','1x2,1x1,1x1'],'progressive-dc-refine':['-scans',str(scans)],'sequential-multiscan':['-scans',str(sequential)]}
records=[]
for name,args in variants.items():
 path=root/(name+'.jpg');command=['/opt/homebrew/bin/cjpeg','-quality','80',*args,'-outfile',str(path),str(source)]
 subprocess.run(command,check=True,capture_output=True)
 oracle=subprocess.run(['../native-jpeg-audit/coefficient-oracle',str(path)],check=True,capture_output=True)
 path.with_suffix('.json').write_bytes(oracle.stdout)
 records.append({'name':name,'command':command,'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'oracleSHA256':hashlib.sha256(oracle.stdout).hexdigest()})
(work/'manifest.json').write_text(json.dumps(records,indent=2)+'\n')
print('Added six independent multi-scan/restart/edge regression fixtures.')

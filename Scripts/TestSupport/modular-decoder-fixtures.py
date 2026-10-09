# SPDX-License-Identifier: Apache-2.0
# Synthetic fixtures for the internal decoder. Run from the repository root.
import json,subprocess,hashlib,os,sys
from pathlib import Path
root=Path('Tests/SwiftJXLCoreTests/Fixtures/Modular/Decoder');work=Path('../modular-preflight/decoder')
specs=[('gray8',31,17,1,8,False),('grayalpha8',31,17,2,8,False),('rgb8',31,17,3,8,False),('rgba8',31,17,4,8,False),('rgb12',31,17,3,12,False),('rgba16',31,17,4,16,False),('groups-rgb8',513,259,3,8,False),('groups-rgba16',1025,17,4,16,False),('responsive-gray8',513,259,1,8,True),('responsive-rgb8',513,259,3,8,True)]
specs += [('responsive-wide-rgb8',4097,17,3,8,True),('responsive-small-rgb8',31,17,3,8,True),('grayalpha16',31,17,2,16,False),('palette-rgb8',31,17,3,8,False),('palette-rgb16',31,17,3,16,False)]
specs += [('groups-grayalpha16',1025,17,2,16,False)]
selected = set(sys.argv[1:])
root.mkdir(parents=True,exist_ok=True)
work.mkdir(parents=True,exist_ok=True)
records=json.loads((root/'manifest.json').read_text()) if selected else []
for name,w,h,c,bits,progressive in specs:
    if selected and name not in selected: continue
    records = [r for r in records if r["name"] != name]
    maximum=(1<<bits)-1
    header=f'P7\nWIDTH {w}\nHEIGHT {h}\nDEPTH {c}\nMAXVAL {maximum}\nTUPLTYPE '+{1:'GRAYSCALE',2:'GRAYSCALE_ALPHA',3:'RGB',4:'RGB_ALPHA'}[c]+'\nENDHDR\n'
    body=bytearray()
    for i in range(w*h):
        for ch in range(c):
            v=((i%4)*47+ch*31)&maximum if name.startswith('palette-') else (i*71+(i//w)*37+ch*113)&maximum
            body.extend(v.to_bytes(1 if bits==8 else 2,'big'))
    inp=work/(name+'.pam');inp.write_bytes(header.encode()+body)
    out=root/(name+'.jxl')
    cmd=[os.environ.get('CJXL', '/opt/homebrew/bin/cjxl'),str(inp),str(out),'-d','0','-e',('9' if name.startswith('palette-') else '3'),'-m','1','--num_threads=2']+(['-p'] if progressive else [])
    p=subprocess.run(cmd,capture_output=True,text=True);(work/(name+'.log')).write_text(p.stdout+p.stderr)
    if p.returncode: raise RuntimeError((name,p.stderr))
    records.append(dict(name=name,width=w,height=h,channels=c,bits=bits,progressive=progressive,command=cmd,inputSHA256=hashlib.sha256(inp.read_bytes()).hexdigest(),sha256=hashlib.sha256(out.read_bytes()).hexdigest()))
(root/'manifest.json').write_text(json.dumps(records,indent=2)+'\n')
print('Generated',len(records),'independent libjxl fixtures')

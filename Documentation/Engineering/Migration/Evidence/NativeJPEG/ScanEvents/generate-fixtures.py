from pathlib import Path
import subprocess,json,hashlib
root=Path('Tests/SwiftJXLCoreTests/Fixtures/JPEGEvents'); root.mkdir(exist_ok=True)
work=Path('../native-jpeg-audit/events')
def segment(marker,payload):return bytes([255,marker])+ (len(payload)+2).to_bytes(2,'big')+payload
def packed(bits):
 bits+='1'*(-len(bits)%8)
 return bytes(int(bits[i:i+8],2) for i in range(0,len(bits),8)).replace(b'\xff',b'\xff\0')
def sos(ss,se,ah,al):return segment(0xda,bytes([1,1,0,ss,se,(ah<<4)|al]))
def header(progressive,restart=False):
 data=b'\xff\xd8'+segment(0xdb,bytes([0])+bytes([1])*64)
 data+=segment(0xc2 if progressive else 0xc0,bytes([8,0,8,0,32,1,1,0x11,0]))
 # DC category zero: code 0. AC: EOB=00, ZRL=01, 0x10=10 (progressive), 0x01=10 (sequential).
 data+=segment(0xc4,bytes([0,1])+bytes(15)+bytes([0])+bytes([0x10,0,3])+bytes(14)+bytes([0,0xf0,0x10 if progressive else 1]))
 if restart:data+=segment(0xdd,b'\0\2')
 return data
cases=[]
def add(name,data,resets,extras):cases.append((name,data,resets,extras))
add('sequential-extra-zero',header(False)+sos(0,63,0,0)+packed('0010100'+'000'+'00110100'+'001010100')+b'\xff\xd9',[[]],[[[0,2],[3,3]]])
for name,ac in [('progressive-split','00000000'),('progressive-grouped','100100')]:
 data=header(True)+sos(0,0,0,0)+packed('0000')+sos(1,63,0,1)+packed(ac)+sos(1,63,1,0)+packed(ac)+b'\xff\xd9'
 points=[1,2,3] if 'split' in name else [2]
 add(name,data,[[],points,points],[[],[],[]])
data=header(True,True)+sos(0,0,0,0)+packed('00')+b'\xff\xd0'+packed('00')
for ah,al in [(0,1),(1,0)]:data+=sos(1,63,ah,al)+packed('0000')+b'\xff\xd0'+packed('0000')
add('progressive-restart-split',data+b'\xff\xd9',[[],[1,3],[1,3]],[[],[],[]])
# A complete sixteen-zero band has no EOB marker at its end. The next EOB
# starts fresh; it must not be mistaken for an adjacent EOB run.
data=header(True)+sos(0,0,0,0)+packed('0000')+sos(1,16,0,0)+packed('01'+'00'+'01'+'00')+sos(17,63,0,0)+packed('100100')+b'\xff\xd9'
add('progressive-band-zero',data,[[],[],[2]],[[],[[0,1],[2,1]],[]])
unsupported = header(True)+sos(0,0,0,0)+packed('0000')+sos(1,63,0,1)+packed('100100')+sos(1,63,1,0)+packed('0100'+'100'+'00')+b'\xff\xd9'
unsupportedPath=root/'refinement-extra-zero-unsupported.jpg'
unsupportedPath.write_bytes(unsupported)
rejected=subprocess.run(['/opt/homebrew/bin/cjxl',str(unsupportedPath),str(work/'unsupported.jxl'),'--lossless_jpeg=1','-e','3'],capture_output=True)
assert rejected.returncode != 0
(work/'unsupported-oracle.json').write_text(json.dumps({'exit':rejected.returncode,'stderr':rejected.stderr.decode(),'sha256':hashlib.sha256(unsupported).hexdigest()},indent=2)+'\n')
records=[]
for name,data,resets,extras in cases:
 src=root/(name+'.jpg');src.write_bytes(data)
 jxl=work/(name+'.jxl');restored=work/(name+'-restored.jpg')
 cmd=['/opt/homebrew/bin/cjxl',str(src),str(jxl),'--lossless_jpeg=1','-e','3']
 subprocess.run(cmd,check=True,capture_output=True)
 subprocess.run(['/opt/homebrew/bin/djxl',str(jxl),str(restored)],check=True,capture_output=True)
 assert restored.read_bytes()==data,name
 encoded=jxl.read_bytes();p=12;bundles=[]
 while p<len(encoded):
  size=int.from_bytes(encoded[p:p+4],'big');kind=encoded[p+4:p+8];assert size>=8
  if kind==b'jbrd':bundles.append(encoded[p+8:p+size])
  p+=size
 assert len(bundles)==1
 (root/(name+'.jbrd')).write_bytes(bundles[0])
 sha=lambda b:hashlib.sha256(b).hexdigest()
 records.append({'name':name,'resetPoints':resets,'extraZeroRuns':extras,'jpegSHA256':sha(data),'jbrdSHA256':sha(bundles[0]),'referenceJXLSHA256':sha(encoded),'referenceByteExactRestoration':True,'command':cmd})
(root/'manifest.json').write_text(json.dumps({'description':'Authored JPEG entropy vectors; expected events derived from explicit scan bits. Independent libjxl 0.12.0 reconstruction verifies byte-exact representability.','cjxlVersion':subprocess.check_output(['/opt/homebrew/bin/cjxl','--version'],stderr=subprocess.STDOUT,text=True).strip(),'cjxlSHA256':sha(Path('/opt/homebrew/bin/cjxl').read_bytes()),'unsupportedFixture':{'name':'refinement-extra-zero-unsupported','jpegSHA256':sha(unsupported)},'fixtures':records},indent=2)+'\n')
print('Verified',len(records),'JPEG event fixtures with independent byte-exact restoration')

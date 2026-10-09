from pathlib import Path
import subprocess,struct,json,hashlib,ctypes
root=Path('Tests/SwiftJXLCoreTests/Fixtures/JBRD');root.mkdir(parents=True,exist_ok=True)
work=Path('../native-jpeg-audit/jbrd-reference');work.mkdir(exist_ok=True)
libpath=Path('/opt/homebrew/opt/brotli/lib/libbrotlidec.dylib')
lib=ctypes.CDLL(str(libpath));decode=lib.BrotliDecoderDecompress
decode.argtypes=[ctypes.c_size_t,ctypes.c_void_p,ctypes.POINTER(ctypes.c_size_t),ctypes.c_void_p];decode.restype=ctypes.c_int
lib.BrotliDecoderVersion.restype=ctypes.c_uint32
sha=lambda b:hashlib.sha256(b).hexdigest()
fixtures=list(Path('Tests/SwiftJXLCoreTests/Fixtures/JPEG').glob('*.jpg'))
zero=bytearray(Path('Tests/SwiftJXLCoreTests/Fixtures/JPEG/gray.jpg').read_bytes());zero[-3]&=254
(work/'zero-padding.jpg').write_bytes(zero)
original=json.loads(Path('Tests/SwiftJXLCoreTests/Fixtures/JPEG/gray.json').read_text())
assert json.loads(subprocess.run(['../native-jpeg-audit/coefficient-oracle',str(work/'zero-padding.jpg')],check=True,capture_output=True).stdout)==original
fixtures.append(work/'zero-padding.jpg')
records=[]
for jpeg in fixtures:
 data=jpeg.read_bytes();pos=2;markers=[];apps=[];coms=[];inter=[];scans=[];quants=[];huffs=[];tail=b''
 while True:
  start=pos;assert data[pos]==255
  while data[pos]==255:pos+=1
  fill=pos-start-1
  if fill:inter.append(data[start:start+fill])
  m=data[pos];pos+=1;markers.append(m)
  if m==217:tail=data[pos:];break
  length=int.from_bytes(data[pos:pos+2],'big');body=data[pos+2:pos+length];marker=bytes([m])+data[pos:pos+length];pos+=length
  if 224<=m<=239:apps.append(marker)
  if m==254:coms.append(marker)
  if m==219:
   q=0
   while q<len(body):
    info=body[q];quants.append({'precision':info>>4,'index':info&15});q+=1+64*(1+(info>>4))
  if m==196:
   h=0
   while h<len(body):
    info=body[h];counts=list(body[h+1:h+17]);n=sum(counts);values=list(body[h+17:h+17+n]);huffs.append({'slot':info,'counts':counts,'values':values});h+=17+n
  if m==218:
   n=body[0];scans.append({'count':n,'ss':body[-3],'se':body[-2],'ah':body[-1]>>4,'al':body[-1]&15})
   while True:
    if data[pos]!=255:pos+=1;continue
    scan=pos
    while data[pos]==255:pos+=1
    if data[pos]==0 or 208<=data[pos]<=215:pos+=1;continue
    pos=scan;break
 name=jpeg.stem;jxl=work/(name+'.jxl')
 command=['/opt/homebrew/bin/cjxl',str(jpeg),str(jxl),'--lossless_jpeg=1','-e','3']
 subprocess.run(command,check=True,capture_output=True)
 encoded=jxl.read_bytes();p=0;bundles=[]
 while p<len(encoded):
  n=int.from_bytes(encoded[p:p+4],'big');kind=encoded[p+4:p+8];header=8
  if n==1:n=int.from_bytes(encoded[p+8:p+16],'big');header=16
  if n==0:n=len(encoded)-p
  assert n>=header and p+n<=len(encoded)
  if kind==b'jbrd':bundles.append(encoded[p+header:p+n])
  p+=n
 assert len(bundles)==1
 bundle=bundles[0];raw=b''.join(apps+coms+inter)+tail
 # Independently locate the Brotli start by exact successful bounded decoding.
 matches=[]
 for offset in range(len(bundle)):
  compressed=ctypes.create_string_buffer(bundle[offset:]);output=ctypes.create_string_buffer(len(raw)+1);size=ctypes.c_size_t(len(raw)+1)
  result=decode(len(bundle)-offset,compressed,ctypes.byref(size),output)
  if result==1 and output.raw[:size.value]==raw:matches.append(offset)
 assert len(matches)==1,(name,matches)
 (root/(name+'.jbrd')).write_bytes(bundle);(root/(name+'.raw')).write_bytes(raw)
 expected={'markers':markers,'appLengths':[len(a) for a in apps],'comLengths':[len(c) for c in coms],'interLengths':[len(i) for i in inter],'tailLength':len(tail),'scans':scans,'quantisation':quants,'huffman':huffs,'brotliOffset':matches[0],'hasZeroPadding':name=='zero-padding'}
 (root/(name+'.json')).write_text(json.dumps(expected,separators=(',',':'))+'\n')
 records.append({'name':name,'sourceJPEG_SHA256':sha(data),'referenceJXL_SHA256':sha(encoded),'jbrdSHA256':sha(bundle),'rawSHA256':sha(raw),'fieldsSHA256':sha((root/(name+'.json')).read_bytes()),'command':command})
print('Retained',len(records),'independent JBRD bundles, offsets and raw metadata bodies.')
(root/'manifest.json').write_text(json.dumps({'cjxlVersion':'0.12.0','brotliVersion':lib.BrotliDecoderVersion(),'brotliLibrarySHA256':sha(libpath.read_bytes()),'cjxlSHA256':sha(Path('/opt/homebrew/bin/cjxl').read_bytes()),'fixtures':records},indent=2)+'\n')

import ctypes as C, hashlib, json, random
from pathlib import Path
root=Path('Tests/SwiftJXLCoreTests/Fixtures/Brotli')
enc=C.CDLL('/opt/homebrew/opt/brotli/lib/libbrotlienc.dylib');dec=C.CDLL('/opt/homebrew/opt/brotli/lib/libbrotlidec.dylib')
enc.BrotliEncoderCompress.argtypes=[C.c_int,C.c_int,C.c_int,C.c_size_t,C.c_void_p,C.POINTER(C.c_size_t),C.c_void_p]
enc.BrotliEncoderCompress.restype=C.c_int
enc.BrotliEncoderVersion.restype=C.c_uint
enc.BrotliEncoderCreateInstance.argtypes=[C.c_void_p]*3;enc.BrotliEncoderCreateInstance.restype=C.c_void_p
enc.BrotliEncoderDestroyInstance.argtypes=[C.c_void_p]
enc.BrotliEncoderSetParameter.argtypes=[C.c_void_p,C.c_int,C.c_uint];enc.BrotliEncoderSetParameter.restype=C.c_int
enc.BrotliEncoderCompressStream.argtypes=[C.c_void_p,C.c_int,C.POINTER(C.c_size_t),C.POINTER(C.c_void_p),C.POINTER(C.c_size_t),C.POINTER(C.c_void_p),C.c_void_p];enc.BrotliEncoderCompressStream.restype=C.c_int
enc.BrotliEncoderIsFinished.argtypes=[C.c_void_p];enc.BrotliEncoderIsFinished.restype=C.c_int
enc.BrotliEncoderHasMoreOutput.argtypes=[C.c_void_p];enc.BrotliEncoderHasMoreOutput.restype=C.c_int
dec.BrotliDecoderDecompress.argtypes=[C.c_size_t,C.c_void_p,C.POINTER(C.c_size_t),C.c_void_p];dec.BrotliDecoderDecompress.restype=C.c_int
rng=random.Random(7932)
raws={
 'text':('compression dictionary transformed words INTERNATIONAL international! '+''.join(chr(i) for i in range(32,127))+'\n').encode()*90,
 'unicode':('日本語 UTF-8 кириллица Ελληνικά العربية français naïve\n').encode()*90,
 'binary':bytes(rng.randrange(256) for _ in range(4096)),
 'runs':bytes((i//257+i//31)%256 for i in range(32768)),
 'mixed':(b'word reading transformation performance asynchronous context\n'*1000+bytes(rng.randrange(256) for _ in range(8192))+b'a'*30000)*3,
}
records=[]
def record(name,rawname,data):
 raw=raws[rawname];capacity=C.c_size_t(max(1,len(raw)));out=C.create_string_buffer(capacity.value)
 assert dec.BrotliDecoderDecompress(len(data),data,C.byref(capacity),out)==1 and out.raw[:capacity.value]==raw,name
 (root/(name+'.br')).write_bytes(data)
 records.append(dict(name=name,raw=rawname,encodedSHA256=hashlib.sha256(data).hexdigest(),rawSHA256=hashlib.sha256(raw).hexdigest(),bytes=len(raw)))
for rawname,raw in raws.items():
 (root/(rawname+'.raw')).write_bytes(raw)
 for quality in [0,1,4,6,9,11]:
  for mode in ([0,1,2] if quality==11 and rawname in ['text','runs'] else [0]):
   window=10 if quality==4 else 22
   capacity=C.c_size_t(len(raw)*2+1024);out=C.create_string_buffer(capacity.value)
   assert enc.BrotliEncoderCompress(quality,window,mode,len(raw),raw,C.byref(capacity),out)==1
   record('%s-q%d-m%d'%(rawname,quality,mode),rawname,out.raw[:capacity.value])
for postfix,direct in [(0,0),(1,12),(3,120)]:
 state=enc.BrotliEncoderCreateInstance(None,None,None);assert state
 for param,val in [(1,11),(2,16),(7,postfix),(8,direct)]:assert enc.BrotliEncoderSetParameter(state,param,val)
 rawname='mixed';raw=raws[rawname];output=bytearray()
 parts=[(1,raw[:20000]),(3,b'not image output'),(1,raw[20000:80000]),(2,raw[80000:])]
 for operation,part in parts:
  source=C.create_string_buffer(part);src=C.c_void_p(C.addressof(source));left=C.c_size_t(len(part))
  for attempt in range(100):
   target=C.create_string_buffer(65536);dst=C.c_void_p(C.addressof(target));available=C.c_size_t(len(target))
   assert enc.BrotliEncoderCompressStream(state,operation,C.byref(left),C.byref(src),C.byref(available),C.byref(dst),None)
   output.extend(target.raw[:len(target)-available.value])
   if left.value==0 and not enc.BrotliEncoderHasMoreOutput(state) and (operation!=2 or enc.BrotliEncoderIsFinished(state)):break
  else:raise RuntimeError('encoder did not finish')
 enc.BrotliEncoderDestroyInstance(state)
 record('streaming-postfix%d-direct%d'%(postfix,direct),rawname,bytes(output))
raws['unsorted-three-symbol']=bytes([65,1,2]);(root/'unsorted-three-symbol.raw').write_bytes(raws['unsorted-three-symbol'])
record('unsorted-three-symbol','unsorted-three-symbol',bytes.fromhex('420000006450804060108006'))
(root/'decoder.json').write_text(json.dumps(dict(version=enc.BrotliEncoderVersion(),cases=records),indent=2)+'\n')
print('Independently encoded and decoded',len(records),'fixtures')

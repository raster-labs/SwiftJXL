import ctypes, ctypes.util, json, hashlib, platform
from pathlib import Path
libpath=ctypes.util.find_library('brotlidec') or '/opt/homebrew/opt/brotli/lib/libbrotlidec.dylib'
lib=ctypes.CDLL(libpath)
lib.BrotliDecoderDecompress.argtypes=[ctypes.c_size_t,ctypes.c_void_p,ctypes.POINTER(ctypes.c_size_t),ctypes.c_void_p]
lib.BrotliDecoderDecompress.restype=ctypes.c_int
lib.BrotliDecoderVersion.restype=ctypes.c_uint
class Bits:
 def __init__(self): self.bits=[]
 def put(self,n,v): self.bits.extend((v>>i)&1 for i in range(n))
 def align(self): self.put((-len(self.bits))%8,0)
 def payload(self,data):
  self.align()
  for x in data:self.put(8,x)
 def data(self):
  self.align();return bytes(sum(self.bits[i+j]<<j for j in range(8)) for i in range(0,len(self.bits),8))
def window(b,n):
 if n==16:b.put(1,0)
 elif n>=18:b.put(4,1+2*(n-17))
 else:b.put(7,1+(0 if n==17 else n-8)*16)
def metadata(b,payload,last=False):
 b.put(1,last)
 if last:b.put(1,0)
 b.put(2,3);b.put(1,0)
 n=0 if not payload else max(1,((len(payload)-1).bit_length()+7)//8)
 b.put(2,n)
 if n:b.put(8*n,len(payload)-1)
 b.payload(payload)
def raw(b,payload):
 b.put(1,0);n=max(4,((len(payload)-1).bit_length()+3)//4)
 b.put(2,n-4);b.put(4*n,len(payload)-1);b.put(1,1);b.payload(payload)
def end(b):b.put(2,3)
def check(stream,expected):
 capacity=ctypes.c_size_t(max(1,len(expected)))
 out=ctypes.create_string_buffer(capacity.value)
 status=lib.BrotliDecoderDecompress(len(stream),stream,ctypes.byref(capacity),out)
 assert status==1 and out.raw[:capacity.value]==expected,(status,capacity.value,len(expected))
 return hashlib.sha256(stream).hexdigest()
entries=[]
for n in range(10,25):
 b=Bits();window(b,n);end(b);data=b.data();check(data,b'')
 entries.append(dict(name='window-'+str(n),stream=data.hex(),window=n,output='',kinds=['empty'],lengths=[0]))
for n in [0,1,256,257]:
 for last in [False,True]:
  b=Bits();window(b,16);metadata(b,bytes([165])*n,last)
  payload=b'' if last else b'pixel-metadata-preserved'
  if not last:raw(b,payload);end(b)
  data=b.data();check(data,payload)
  entries.append(dict(name='metadata-%d-%s'%(n,last),stream=data.hex(),window=16,output=payload.hex(),kinds=['metadata']+([] if last else ['uncompressed','empty']),lengths=[n]+([] if last else [len(payload),0])))
boundaries=[]
for n in [0,1,65536,65537,1048576,1048577]:
 payload=bytes([165])*n
 if n:
  # Generate only the small header using Bits; append the admitted raw bytes.
  b=Bits();window(b,16);b.put(1,0);nibbles=max(4,((n-1).bit_length()+3)//4)
  b.put(2,nibbles-4);b.put(4*nibbles,n-1);b.put(1,1);prefix=b.data();suffix=bytes([3])
 else:prefix=bytes([6]);suffix=b''
 data=prefix+payload+suffix
 boundaries.append(dict(count=n,prefix=prefix.hex(),suffix=suffix.hex(),sha256=check(data,payload)))
record=dict(referenceLibrary=libpath,referenceVersion=lib.BrotliDecoderVersion(),platform=platform.platform(),streams=entries,encoderBoundaries=boundaries)
p=Path('Tests/SwiftJXLCoreTests/Fixtures/Brotli');p.mkdir(exist_ok=True)
(p/'framing.json').write_text(json.dumps(record,indent=2)+'\n')
print('Independent libbrotli accepted %d framed streams and %d encoder boundary streams'%(len(entries),len(boundaries)))

from pathlib import Path
import ctypes as C,hashlib,json
root=Path('Tests/SwiftJXLCoreTests/Fixtures/Brotli');m=json.loads((root/'decoder.json').read_text())
lib=C.CDLL('/opt/homebrew/opt/brotli/lib/libbrotlidec.dylib')
lib.BrotliDecoderDecompress.argtypes=[C.c_size_t,C.c_void_p,C.POINTER(C.c_size_t),C.c_void_p];lib.BrotliDecoderDecompress.restype=C.c_int
class Bits:
 def __init__(self): self.b=[]
 def put(self,n,v): self.b.extend((v>>i)&1 for i in range(n))
 def simple(self,width,values):
  self.put(2,1);self.put(2,len(values)-1)
  for v in values:self.put(width,v)
 def block(self):
  self.put(4,1);self.simple(2,[1]);self.simple(5,[0]);self.put(2,0)
 def data(self):
  self.put((-len(self.b))%8,0)
  return bytes(sum(self.b[i+j]<<j for j in range(8)) for i in range(0,len(self.b),8))
def record(name,data,raw):
 cap=C.c_size_t(len(raw));out=C.create_string_buffer(cap.value)
 status=lib.BrotliDecoderDecompress(len(data),data,C.byref(cap),out)
 assert status==1 and out.raw[:cap.value]==raw,(name,status,out.raw.hex(),data.hex())
 (root/(name+'.br')).write_bytes(data);(root/(name+'.raw')).write_bytes(raw)
 m['cases']=[v for v in m['cases'] if v['name']!=name]
 m['cases'].append(dict(name=name,raw=name,encodedSHA256=hashlib.sha256(data).hexdigest(),rawSHA256=hashlib.sha256(raw).hexdigest(),bytes=len(raw)))
for mtf in [0,1]:
 b=Bits();b.put(1,0);b.put(1,1);b.put(1,0);b.put(2,0);b.put(16,8)
 for _ in range(3):b.block()
 b.put(2,0);b.put(4,1) # postfix0, direct1
 b.put(2,1);b.put(2,3) # literal context modes MSB6 and signed
 b.put(4,1);b.put(1,1);b.put(4,5) # NTREESL2, RLE6
 if mtf:
  b.simple(3,[6,5,7]);b.put(1,0);b.put(6,0);b.put(2,3);b.put(2,1);b.put(5,31)
 else:
  b.simple(3,[6,7]);b.put(1,0);b.put(6,0)
  for _ in range(64):b.put(1,1)
 b.put(1,mtf)
 b.put(4,1);b.put(1,1);b.put(4,1) # NTREESD2, RLE2
 b.simple(2,[2,3]);b.put(1,0);b.put(2,0)
 for _ in range(4):b.put(1,1)
 b.put(1,0)
 for v in [65,66]:b.simple(8,[v])
 for _ in range(2):b.simple(10,[136])
 for _ in range(2):b.simple(7,[16]) # distance alphabet 65
 for _ in range(2):b.put(2,0);b.put(2,0);b.put(2,0) # C,L,D switches
 record('all-block-types-mtf%d'%mtf,b.data(),b'AAABBBAAA')
# A stored prefix establishes history, then sixteen explicit short-distance codes.
b=Bits();b.put(1,0);b.put(1,0);b.put(2,0);b.put(16,31);b.put(1,1)
b.put((-len(b.b))%8,0)
for value in range(32):b.put(8,value)
b.put(1,1);b.put(1,0);b.put(2,0);b.put(16,31)
b.put(3,0);b.put(2,0);b.put(4,0);b.put(2,0);b.put(2,0)
b.simple(8,[0]);b.simple(10,[128])
# Complex distance prefix: sixteen symbols of length four, trailing zeros implicit.
b.put(2,0)
order=[1,2,3,4,0,5,17,6,16,7,8,9,10,11,12,13,14,15]
for symbol in order:
 if symbol==4:b.put(4,7) # static length-code value 1
 else:b.put(2,0)
output=bytearray(range(32));recent=[4,11,15,16]
for code in range(16):
 b.put(4,int(format(code,'04b')[::-1],2))
 if code<4:distance=recent[code]
 else:
  index=0 if code<10 else 1;variant=(code-4)%6
  distance=recent[index]+(variant//2+1)*(-1 if variant%2==0 else 1)
 if code!=0:recent=[distance]+recent[:3]
 for _ in range(2):output.append(output[-distance])
record('all-short-distances',b.data(),bytes(output))
(root/'decoder.json').write_text(json.dumps(m,indent=2)+'\n')
print('Added independently validated block-switch/context-map fixtures')

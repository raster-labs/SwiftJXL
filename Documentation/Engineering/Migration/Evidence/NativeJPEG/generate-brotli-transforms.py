import ctypes as C,hashlib,json,re,base64
from pathlib import Path
lib=C.CDLL('/opt/homebrew/opt/brotli/lib/libbrotlicommon.dylib')
class Dictionary(C.Structure):
 _fields_=[('bits',C.c_uint8*32),('offsets',C.c_uint32*32),('size',C.c_size_t),('data',C.c_void_p)]
lib.BrotliGetDictionary.restype=C.POINTER(Dictionary)
lib.BrotliGetTransforms.restype=C.c_void_p
lib.BrotliTransformDictionaryWord.argtypes=[C.c_void_p,C.c_void_p,C.c_int,C.c_void_p,C.c_int];lib.BrotliTransformDictionaryWord.restype=C.c_int
dictionary=lib.BrotliGetDictionary().contents; transforms=lib.BrotliGetTransforms();blob=C.string_at(dictionary.data,dictionary.size)
s=Path('Sources/SwiftJXLCore/Brotli/BrotliStaticDictionary.swift').read_text().split('private static let dataBase64: [String] = [',1)[1].split('    ]',1)[0]
embedded=base64.b64decode(''.join(re.findall(r'"([A-Za-z0-9+/=]+)"',s)))
assert embedded==blob and len(blob)==122784
vectors=[]
for length in range(4,25):
 for word in [0,(1<<dictionary.bits[length])-1]:
  offset=dictionary.offsets[length]+word*length
  for transform in range(121):
   out=C.create_string_buffer(128)
   n=lib.BrotliTransformDictionaryWord(out,dictionary.data+offset,length,transforms,transform)
   assert 0<=n<=128
   vectors.append(dict(length=length,offset=offset,transform=transform,output=out.raw[:n].hex()))
Path('Tests/SwiftJXLCoreTests/Fixtures/Brotli/transforms.json').write_text(json.dumps(dict(dictionarySHA256=hashlib.sha256(blob).hexdigest(),vectors=vectors),separators=(',',':'))+'\n')
print('Verified dictionary blob and',len(vectors),'independent transformed words')

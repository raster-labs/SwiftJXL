#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Regenerate synthetic ICC test fixtures using local LittleCMS (not a runtime dependency)."""
from pathlib import Path
import ctypes as C,hashlib,json,struct
lib=C.CDLL('/opt/homebrew/lib/liblcms2.dylib')
lib.cmsCreate_sRGBProfile.restype=C.c_void_p
lib.cmsD50_xyY.restype=C.c_void_p
lib.cmsBuildGamma.argtypes=[C.c_void_p,C.c_double];lib.cmsBuildGamma.restype=C.c_void_p
lib.cmsCreateGrayProfile.argtypes=[C.c_void_p,C.c_void_p];lib.cmsCreateGrayProfile.restype=C.c_void_p
lib.cmsSaveProfileToMem.argtypes=[C.c_void_p,C.c_void_p,C.POINTER(C.c_uint32)];lib.cmsSaveProfileToMem.restype=C.c_int
lib.cmsCloseProfile.argtypes=[C.c_void_p];lib.cmsFreeToneCurve.argtypes=[C.c_void_p]
lib.cmsGetEncodedCMMversion.restype=C.c_uint32
out=Path('Tests/SwiftJXLCoreTests/Fixtures/JPEGBridge');manifest={'generator':'LittleCMS generated synthetic standard colour profiles; timestamp normalised to 2026-01-01; no external profile files','profile_copyright':'No copyright, use freely (embedded profile text)', 'lcms_version':lib.cmsGetEncodedCMMversion(),'fixtures':[]}
curve=lib.cmsBuildGamma(None,2.2)
for name,profile in [('srgb',lib.cmsCreate_sRGBProfile()),('gray-gamma22',lib.cmsCreateGrayProfile(lib.cmsD50_xyY(),curve))]:
 assert profile
 size=C.c_uint32();assert lib.cmsSaveProfileToMem(profile,None,C.byref(size))
 buf=C.create_string_buffer(size.value);assert lib.cmsSaveProfileToMem(profile,buf,C.byref(size))
 data=bytearray(buf.raw[:size.value]);data[24:36]=struct.pack('>6H',2026,1,1,0,0,0)
 (out/(name+'.icc')).write_bytes(data)
 manifest['fixtures'].append({'file':name+'.icc','bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()})
 lib.cmsCloseProfile(profile)
lib.cmsFreeToneCurve(curve)
(out/'icc-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(manifest)

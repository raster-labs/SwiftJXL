# SPDX-License-Identifier: Apache-2.0
# Separate scalar Float32 sRGB oracle; unchanged max2 / RMS0.5 thresholds.
import hashlib, json, math, pathlib, struct, subprocess, sys
root, oracle = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]).resolve()
results=[]
for path in sorted(root.glob('precision-*.jxl')):
    _,bits,channels=path.stem.split('-'); bits,channels=int(bits),int(channels)
    output=path.with_suffix('.scalar')
    subprocess.run([str(oracle),'decode-float',str(path),str(output)],check=True)
    raw=output.read_bytes(); actual=path.with_suffix('.decoded').read_bytes(); original=path.with_suffix('.input').read_bytes()
    expected=[int(min(1,max(0,x))*((1<<bits)-1)+0.5) for (x,) in struct.iter_unpack('<f',raw)]
    decoded=[x for (x,) in struct.iter_unpack('<H',actual)]
    source=list(original) if bits==8 else [x for (x,) in struct.iter_unpack('<H',original)]
    assert len(expected)==len(decoded)==len(source)==17*9*channels
    errors=[]; alpha=True
    for i,(a,b) in enumerate(zip(decoded,expected)):
        if channels%2==0 and i%channels==channels-1: alpha &= a==b==source[i]
        else: errors.append(abs(a-b))
    peak=max(errors); rms=math.sqrt(sum(x*x for x in errors)/len(errors))
    results.append(dict(name=path.stem,bits=bits,channels=channels,peak=peak,rms=rms,alphaExact=alpha,passed=peak<=2 and rms<=.5 and alpha,sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
report=dict(oracleSHA256=hashlib.sha256(oracle.read_bytes()).hexdigest(),domain='scalar Float32 sRGB clamped nearest integer at declared precision',thresholds=dict(peak=2,rms=.5,alpha='exact'),results=results)
(root/'oracle-results.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(dict(cases=len(results),passed=sum(r['passed'] for r in results),maxPeak=max((r['peak'] for r in results),default=None),maxRMS=max((r['rms'] for r in results),default=None))))
assert len(results)==36 and all(r['passed'] for r in results)

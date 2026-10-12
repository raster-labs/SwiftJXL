import json,subprocess,pathlib,math,struct,sys
root=pathlib.Path(sys.argv[1]); oracle='work/vardct-preflight/pixel-oracle';results=[]
for r in json.load(open(root/'results.json')):
 name=r['name']; target=root/(name+'.oracle');p=subprocess.run([oracle,'decode',str(root/(name+'.jxl')),str(target)],capture_output=True)
 r['oracleDecodeExit']=p.returncode
 if p.returncode==0:
  bits=int(r['bits']);ch=int(r['channels']);typ='H' if bits==16 else 'B'; a=(root/(name+'.decoded')).read_bytes(); b=target.read_bytes(); a=struct.unpack('<'+typ*(len(a)//(bits//8)),a); b=struct.unpack('<'+typ*(len(b)//(bits//8)),b)
  errors=[abs(x-y) for i,(x,y) in enumerate(zip(a,b)) if ch%2 or i%ch!=ch-1];r['maximumColourErrorLSB']=max(errors);r['rmsColourErrorLSB']=math.sqrt(sum(e*e for e in errors)/len(errors));r['alphaExact']=all(x==y for i,(x,y) in enumerate(zip(a,b)) if ch%2==0 and i%ch==ch-1);r['withinPredeclaredDecodeThreshold']=len(a)==len(b) and max(errors)<=2 and r['rmsColourErrorLSB']<=.5 and r['alphaExact']
  w=int(r['width']);h=int(r['height']);r['errorsOver2OutsideLastRowOrColumn']=sum(abs(x-y)>2 for i,(x,y) in enumerate(zip(a,b)) if (i//ch)%w<w-1 and (i//ch)//w<h-1)
 results.append(r);print(name,'max',r.get('maximumColourErrorLSB'),'rms',round(r.get('rmsColourErrorLSB',0),3),'interior>2',r.get('errorsOver2OutsideLastRowOrColumn'))
(root/'oracle-results.json').write_text(json.dumps(results,indent=2)+'\n')

import pathlib,shlex,subprocess
p=pathlib.Path(__file__).resolve().parent;s=p/'libjxl-a7a9c787341cf703dede03c2009fa460cae5e5df';b=p/'libjxl-scalar-build';args=shlex.split((b/'lib/CMakeFiles/jxl.dir/link.txt').read_text());link=[str(b/'lib'/a) if not a.startswith('/') else a for a in args if a.endswith(('.o','.dylib','.a')) and a!='libjxl.0.12.0.dylib' and not a.startswith('@')]
cmd=['xcrun','clang++','-std=c++17','-O2','-DHWY_COMPILE_ONLY_SCALAR','-DJXL_HIGH_PRECISION=1','-I'+str(s),'-I'+str(b/'lib/include'),'-I'+str(s/'lib/include'),'-I/opt/homebrew/include',str(p/'inverse-gaborish-oracle.cc'),*link,'-Wl,-rpath,'+str(b/'lib'),'-o',str(p/'inverse-gaborish-oracle')]
r=subprocess.run(cmd);raise SystemExit(r.returncode)

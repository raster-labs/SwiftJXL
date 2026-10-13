from pathlib import Path
import hashlib,json,os,subprocess

w=Path(__file__).resolve().parent
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
records=[]
for name in ['baseline','current','candidate']:
    build=json.loads((w/name/'build.json').read_text())
    command=build['linkCommand'].copy()
    command[command.index(str(w/name/'probe.swift'))]=str(w/'preflight.swift')
    command[-1]=str(w/name/'preflight')
    compiled=subprocess.run(command,env=env,capture_output=True,text=True,timeout=120)
    record={'name':name,'command':command,'compileExit':compiled.returncode,'compileOutput':compiled.stdout+compiled.stderr,'probeHash':hashlib.sha256((w/'preflight.swift').read_bytes()).hexdigest()}
    assert compiled.returncode==0,record
    run=subprocess.run([command[-1]],env=env,capture_output=True,text=True,timeout=120)
    record.update(runCommand=[command[-1]],exit=run.returncode,output=run.stdout+run.stderr)
    records.append(record)
    (w/'preflight.json').write_text(json.dumps(records,indent=2)+'\n')
    assert run.returncode==0,record
    print(name,run.stdout.strip(),flush=True)

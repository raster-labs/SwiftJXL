#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Black-box CLI and staged binary/manual installation regression checks."""
import argparse, hashlib, json, os, re, shutil, subprocess, sys, tempfile
from pathlib import Path

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True,help='New evidence directory')
    args=parser.parse_args();binary=args.binary.resolve();out=args.output.resolve()
    if out.exists():parser.error('Use a fresh output directory')
    out.mkdir(parents=True)
    repo=Path(__file__).resolve().parent.parent
    tool=binary.name;version=(repo/'VERSION').read_text().strip();manual=repo/'ManPages'/(tool+'.1')
    if not manual.is_file():parser.error('Binary name must match this repository manual')
    report={'binary':str(binary),'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),
            'installer_sha256':hashlib.sha256((repo/'Scripts/install-cli.sh').read_bytes()).hexdigest(),
            'test_runner_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            'version':version,'manual_sha256':hashlib.sha256(manual.read_bytes()).hexdigest(),'commands':[],'status':'running'}
    def save(): (out/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    def run(argv,expected=0,**kwargs):
        r=subprocess.run([str(x) for x in argv],capture_output=True,text=True,timeout=30,**kwargs)
        report['commands'].append({'argv':[str(x) for x in argv],'exit_code':r.returncode,'expected_exit_code':expected,
                                   'stdout':r.stdout,'stderr':r.stderr})
        save();assert r.returncode==expected,(argv,r.returncode,r.stderr);return r
    def cli(*values,expected=0):return run([binary,*values],expected)
    def document(r):
        d=json.loads(r.stdout);assert d['version']==version and d['minimumAppleOS']=='26.0'
        assert d['canEncode'] is True and d['canDecode'] is True and d['canInspect'] is True and d['canValidate'] is True and d['formats']==['jpeg','jpeg-xl','nrrd','pnm','pnm-srgb'] and d['canTranscode'] is True and d['interchangeMeaningfulBits']==16
        assert d['interchangeFormats']==['nrrd','pnm','pnm-srgb'] and d['pnmMeaningfulBits']==list(range(8,17))
        return d
    try:
        root=cli('--help');assert 'USAGE:' in root.stdout and 'transcode' in root.stdout and not root.stderr
        for form in [[],['-h'],['help']]:assert cli(*form).stdout==root.stdout
        command=cli('capabilities','--help').stdout
        assert cli('help','capabilities').stdout==command and cli('capabilities','-h').stdout==command
        assert '--json' in command and 'EXIT STATUS' in command
        for form in [['--version'],['version'],['--version','--quiet']]:assert cli(*form).stdout==tool+' '+version+'\n'
        baseline=document(cli('capabilities','--json'))
        for level in range(1,6):
            for form in [['-'+'v'*level],['-v']*level,['--verbose',str(level)],['--verbose='+str(level)],
                         ['-verbose:',str(level)],['-verbose:'+str(level)],['--verbose','+'*level],['--verbose='+'+'*level]]:
                r=cli('capabilities','--json',*form);assert document(r)==baseline
                assert len(r.stderr.splitlines())==level,(form,r.stderr)
                assert all(f'[{i}]' in r.stderr for i in range(1,level+1))
        for form in [['--verbose'],['-verbose']]:assert len(cli(*form,'capabilities','--json').stderr.splitlines())==1
        assert len(cli('capabilities','-v','--verbose','2','-v').stderr.splitlines())==3
        assert len(cli('capabilities','-vv','-vvv').stderr.splitlines())==5
        quiet=cli('capabilities','--json','--quiet');assert not quiet.stderr and document(quiet)==baseline
        assert cli('--help','--quiet').stdout==root.stdout
        for invalid in ['0','6','10','99999999999999999999999999999','abc','++++++','+2','١','']:
            r=cli('capabilities','--verbose='+invalid,expected=2);assert not r.stdout and r.stderr
        for form in [['--verbose=5','-v'],['-vvvvvv'],['-v','--quiet'],['--quiet','--verbose=1'],['--quiet','--verbose=0'],
                     ['--unknown'],['bogus'],['help','bogus'],['capabilities','extra'],['--verbose:'],['--json'],
                     ['--input','some-path'],['capabilities','--output','x'],['capabilities','--version'],['--input']]:
            r=cli(*form,expected=2);assert not r.stdout and r.stderr
        with tempfile.TemporaryDirectory(prefix='cli stage spaces ',dir=out) as temp:
            temp=Path(temp);payload=temp/'private image λ.raw';payload.write_bytes(b'unchanged')
            verbs=[]
            if tool == 'swiftj2k-cli':verbs.append('transcode')
            elif tool == 'swiftjxl-cli':
                assert 'original JPEG' in cli('transcode','--help').stdout
                cli('transcode',expected=2)
            else:cli('transcode',expected=2)
            for verb in verbs:
                assert 'UNAVAILABLE:' in cli(verb,'--help').stdout
                r=cli(verb,'--input','-','--output',str(payload),'-vvvvv',expected=4)
                assert not r.stdout and str(payload) not in r.stderr and payload.read_bytes()==b'unchanged'
                new=temp/'must not exist';cli(verb,'--input',str(payload),'--output',str(new),expected=4);assert not new.exists()
            readfd,writefd=os.pipe();os.close(readfd)
            try:
                r=subprocess.run([str(binary),'--help'],stdout=writefd,stderr=subprocess.PIPE,text=True,timeout=10)
            finally:os.close(writefd)
            report['commands'].append({'argv':[str(binary),'--help'],'condition':'stdout pipe with no readers',
                                       'exit_code':r.returncode,'expected_exit_code':6,'stderr':r.stderr});save()
            assert r.returncode==6 and 'I/O failure' in r.stderr
            # Installation and repeat update must carry the matching manual even if one is stale.
            stage=temp/'stage with spaces';prefix='/opt/suite tools';installed=stage/'opt/suite tools'
            command=[repo/'Scripts/install-cli.sh','--binary',binary,'--prefix',prefix,'--destdir',stage]
            run(command);assert (installed/'bin'/tool).stat().st_mode & 0o777==0o755
            page=installed/'share/man/man1'/(tool+'.1');assert page.read_bytes()==manual.read_bytes()
            page.write_text('obsolete manual\n');run(command);assert page.read_bytes()==manual.read_bytes()
            assert page.stat().st_mode & 0o777==0o644
            run([installed/'bin'/tool,'--version'])
            man=shutil.which('man');mandoc=shutil.which('mandoc')
            if not man or not mandoc:raise RuntimeError('man and mandoc are required for manual qualification')
            location=run([man,'-M',installed/'share/man','-w',tool]);assert str(page) in location.stdout
            lint=run([mandoc,'-T','lint',page]);assert not lint.stdout and not lint.stderr,(lint.stdout,lint.stderr)
            rendered=run([mandoc,'-T','ascii',page]);(out/'manual-rendered.txt').write_text(rendered.stdout)
            plain=re.sub(r'.\x08', '', rendered.stdout)
            (out/'manual-plain.txt').write_text(plain)
            assert 'DIAGNOSTIC LEVELS' in plain and tool in plain
            (out/'manual.1').write_bytes(manual.read_bytes())
            run([repo/'Scripts/install-cli.sh','--prefix','relative','--binary',binary],2)
            run([repo/'Scripts/install-cli.sh','--binary'],2)
            wrong=temp/'wrong version';wrong.write_text('#!/bin/sh\nprintf "wrong 0\\n"\n');wrong.chmod(0o755)
            run([repo/'Scripts/install-cli.sh','--binary',wrong,'--prefix',prefix,'--destdir',stage],2)
            assert page.read_bytes()==manual.read_bytes()
            environment=dict(os.environ,DESTDIR=str(stage))
            run([repo/'Scripts/install-cli.sh','--binary',binary,'--prefix',prefix],env=environment)


            # Reject a stale source manual before changing an installed binary/manual pair.
            fixture=temp/'stale source';(fixture/'Scripts').mkdir(parents=True);(fixture/'ManPages').mkdir()
            shutil.copy2(repo/'Scripts/install-cli.sh',fixture/'Scripts/install-cli.sh')
            (fixture/'VERSION').write_text(version+'\n')
            (fixture/'ManPages'/(tool+'.1')).write_text('.TH '+tool.upper()+' 1 "September 19, 2026" "0.0.0"\n')
            run([fixture/'Scripts/install-cli.sh','--binary',binary,'--prefix',prefix,'--destdir',stage],2)
            assert page.read_bytes()==manual.read_bytes()
            # A symlink destination is refused instead of following it outside the installation.
            (installed/'bin'/tool).unlink();(installed/'bin'/tool).symlink_to(payload)
            run(command,6);assert payload.read_bytes()==b'unchanged'
        report['status']='passed';report['checks']=len(report['commands']);save()
        print(f'{tool}: {len(report["commands"])} process checks passed');return 0
    except Exception as error:
        report['status']='failed';report['failure']=str(error);save();raise
if __name__=='__main__':sys.exit(main())

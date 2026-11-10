"""Bounded read-only process witness on a fresh public GitHub-hosted VM.

No application inputs, credentials, environment dumps or full command lines.
"""
from pathlib import Path
import hashlib,json,os,stat

def file_identity(path):
    path=Path(path);before=path.stat()
    if not stat.S_ISREG(before.st_mode) or before.st_size>128*1024**2:
        return dict(path=str(path),hashUnavailable=True)
    digest=hashlib.sha256()
    with path.open('rb') as stream:
        while block:=stream.read(65536):digest.update(block)
    after=path.stat()
    assert (before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns)==(after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns)
    return dict(path=str(path),bytes=before.st_size,sha256=digest.hexdigest())

def identity(pid):
    root=Path('/proc')/str(pid);before=(root/'stat').read_text().rsplit(')',1)[1].split()
    executable=os.readlink(root/'exe')
    value=dict(pid=pid,parentPid=int(before[1]),startTicks=int(before[19]),executable=file_identity(executable),
        comm=(root/'comm').read_text().strip(),cgroups=(root/'cgroup').read_text().splitlines())
    status=(root/'status').read_text().splitlines()
    value['uidGidGroups']=[line for line in status if line.startswith(('Uid:','Gid:','Groups:'))]
    # Only an existing absolute interpreter entrypoint is eligible for output.
    # Arbitrary options, application parameters and other argv contents are omitted.
    if Path(executable).name.lower().startswith(('python','node','dotnet')):
        arguments=(root/'cmdline').read_bytes()[:8192].split(b'\0')
        for argument in arguments[1:]:
            if not argument:break
            text=argument.decode('utf8','replace')
            if text.startswith('-'):continue
            candidate=Path(text)
            if candidate.is_absolute() and candidate.is_file():value['entrypoint']=file_identity(candidate)
            break
    after=(root/'stat').read_text().rsplit(')',1)[1].split()
    assert before[19]==after[19] and int(before[1])==int(after[1]),'Process generation changed'
    return value

def main():
    assert os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted' and os.environ.get('RUNNER_OS')=='Linux'
    heavy={'java','javac','node','nodejs','npm','mvn','maven','gradle','runc','cc1','cc1plus','mariadbd','mysqld','postgres','postmaster','redis-server','make','cmake','ninja','gcc','g++','cc','c++','clang','clang++','rustc','cargo','go','dotnet','csc'}
    selected=[];unavailable=[]
    for item in sorted(Path('/proc').iterdir(),key=lambda p:int(p.name) if p.name.isdigit() else 0):
        if not item.name.isdigit() or int(item.name)<=1:continue
        try:
            executable=os.readlink(item/'exe');name=Path(executable).name.lower()
            if name not in heavy and not name.startswith('python'):continue
            row=identity(int(item.name));chain=[];parent=row['parentPid'];seen={row['pid']}
            while parent>1 and len(chain)<16:
                assert parent not in seen;seen.add(parent)
                ancestor=identity(parent);chain.append(ancestor);parent=ancestor['parentPid']
            row['parents']=chain;selected.append(row)
        except (FileNotFoundError,ProcessLookupError):unavailable.append(int(item.name))
    print(json.dumps(dict(schema='leadya-public-runner-process-witness/v1',bootId=Path('/proc/sys/kernel/random/boot_id').read_text().strip(),samplerPid=os.getpid(),processes=selected,disappearedDuringSnapshot=unavailable,applicationInputsRead=False,environmentValuesIncluded=False,fullCommandLinesIncluded=False)),flush=True)

if __name__=='__main__':main()

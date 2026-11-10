"""Native resource evidence for a dedicated GitHub-hosted Ubuntu VM only.

Calls the authenticated original policy unchanged. This is never a Windows
ledger receipt and must not be used to admit work on a shared/self-hosted VM.
"""
from pathlib import Path
import datetime,hashlib,json,os,re,shutil,subprocess,time

def need(value,code):
    if not value:raise ValueError(code)

def identity(pid):
    need(type(pid) is int and pid>1,'BAD_PID')
    root=Path('/proc')/str(pid)
    fields=(root/'stat').read_text().rsplit(')',1)[1].split()
    return dict(pid=pid,startTicks=int(fields[19]),executable=os.readlink(root/'exe'),
        bootId=Path('/proc/sys/kernel/random/boot_id').read_text().strip())

def alive(value):
    try:return identity(value['pid'])==value
    except (FileNotFoundError,ProcessLookupError):return False

def cpu():
    values=list(map(int,Path('/proc/stat').read_text().splitlines()[0].split()[1:9]))
    need(len(values)==8 and all(value>=0 for value in values),'BAD_CPU_COUNTER')
    return sum(values),values[3]+values[4]

def measure(paths):
    memory={name:int(value.split()[0])*1024 for name,value in
        (line.split(':',1) for line in Path('/proc/meminfo').read_text().splitlines())}
    first=cpu();time.sleep(1);second=cpu();total=second[0]-first[0]
    need(total>0 and 0<=memory['MemAvailable']<=memory['MemTotal'],'BAD_RESOURCE_COUNTER')
    disks=[dict(path=str(path),device=path.stat().st_dev,free_gib=shutil.disk_usage(path).free/1024**3) for path in paths]
    return dict(checked_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        boot_id=Path('/proc/sys/kernel/random/boot_id').read_text().strip(),platform='linux',
        cpu_percent=100*(1-(second[1]-first[1])/total),memory_percent=100*(1-memory['MemAvailable']/memory['MemTotal']),
        free_gib=memory['MemAvailable']/1024**3,disk_free_gib=min(row['free_gib'] for row in disks),
        disk_device=paths[0].stat().st_dev,checkout=str(paths[0]),filesystems=disks)

def census(owner):
    need(owner==identity(os.getpid()) and alive(owner),'OWNER_IS_NOT_ACTUAL_SAMPLER')
    running=subprocess.check_output(['docker','--host','unix:///var/run/docker.sock','container','ls','--no-trunc','--quiet'],timeout=20).decode().split()
    need(all(re.fullmatch('[a-f0-9]{64}',value) for value in running),'INCOMPLETE_CONTAINER_CENSUS')
    need(not running,'PREEXISTING_RUNNING_CONTAINERS')
    candidates=[]
    heavy={'java','javac','node','nodejs','npm','mvn','maven','gradle','runc','cc1','cc1plus',
        'mariadbd','mysqld','postgres','postmaster','redis-server','make','cmake','ninja',
        'gcc','g++','cc','c++','clang','clang++','rustc','cargo','go','dotnet','csc'}
    for entry in Path('/proc').iterdir():
        if not entry.name.isdigit() or int(entry.name)<=1:continue
        try:
            value=identity(int(entry.name));name=Path(value['executable']).name.lower()
            if value==owner:continue
            if name in heavy or name.startswith('python'):
                candidates.append(value)
        except (FileNotFoundError,ProcessLookupError):continue
    need(owner==identity(os.getpid()) and alive(owner) and all(alive(value) for value in candidates),'PROCESS_GENERATION_CHANGED')
    return dict(activeHeavyPhases=len(candidates),processes=candidates,baselineExceptions=[],preexistingRunningContainers=running)

def assess(bootstrap,paths,owner):
    need(os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted'
         and os.environ.get('RUNNER_OS')=='Linux' and os.environ.get('CI_DB_EPHEMERAL_VM')=='ubuntu-24.04',
         'DEDICATED_UBUNTU_JOB_REQUIRED')
    need(owner==identity(os.getpid()) and alive(owner),'OWNER_IS_NOT_ACTUAL_SAMPLER')
    prefix=['git','-c','protocol.allow=never','-c','safe.directory='+str(bootstrap),'-C',str(bootstrap)]
    def git(*args):return subprocess.check_output(prefix+list(args),timeout=20)
    need(git('rev-parse','HEAD','HEAD^{tree}').decode().split()==[
        '709c62ba7c1dc27588b1608ef1fc3fed5ec2c232','55e52f37023f971a89ae32fb876a369fe379da15'],
        'ORIGINAL_BOOTSTRAP_CHANGED')
    name='.agents/skills/leadya-project-manager/scripts/host_gate.py'
    expected=git('rev-parse','HEAD:'+name).decode().strip()
    need(re.fullmatch('[a-f0-9]{40}',expected),'BAD_ORIGINAL_GATE_ID')
    raw=git('cat-file','blob',expected)
    need(hashlib.sha1(b'blob '+str(len(raw)).encode()+b'\0'+raw).hexdigest()==expected,'ORIGINAL_GATE_CHANGED')
    namespace={'__name__':'original_dedicated_linux_assessor','__file__':str(bootstrap/name)}
    exec(compile(raw,str(bootstrap/name),'exec'),namespace)
    phases=census(owner);sample=measure(paths)
    need(alive(owner),'OWNER_ENDED')
    timestamp=datetime.datetime.fromisoformat(sample['checked_at'])
    need(0<=(datetime.datetime.now(datetime.timezone.utc)-timestamp).total_seconds()<=15,'STALE_SAMPLE')
    budget=dict(memory_gib=4,disk_gib=6)
    namespace['assess'](sample,budget=budget,active=phases['activeHeavyPhases'])
    return dict(schema='leadya-dedicated-linux-admission/v1',assessment='PASS',
        originalGateBlob=expected,measurement=sample,census=phases,budget=budget,
        owner=owner,windowsLedgerReceipt=False,sharedHostAdmission=False)

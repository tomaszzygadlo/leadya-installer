"""Native resource evidence for a dedicated GitHub-hosted Ubuntu VM only.

Calls the authenticated original policy unchanged. This is never a Windows
ledger receipt and must not be used to admit work on a shared/self-hosted VM.
"""
from pathlib import Path
import datetime,hashlib,json,os,re,shutil,stat,subprocess,time

# Actual witness: diagnostic run 42886461626, not a guessed startup PID list.
# Roles: packages.ubuntu.com/en/noble/networkd-dispatcher and Azure/WALinuxAgent.
PLATFORM_PYTHON_SHA='e50d468e8b0adfb05733f5b87b3cff34829c4a8c1aea50c865aa8bdfe4bb150f'
PLATFORM_SERVICES={
    '/usr/bin/networkd-dispatcher':('networkd-dispatcher','0::/system.slice/networkd-dispatcher.service',
        'aad2823762b60d03df6762ef18eb747a30d20ff7882116f96f4adf745800d697'),
    '/usr/sbin/waagent':('azure-linux-agent-daemon','0::/azure.slice/walinuxagent.service',
        '05b4f17398765b0978231cc6bcaebda8dd90ba1db442d1db9b8cb88ffb6897e5')}

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

def dedicated_context():
    return (os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted'
        and os.environ.get('RUNNER_OS')=='Linux' and os.environ.get('CI_DB_EPHEMERAL_VM')=='ubuntu-24.04')

def classify_platform(snapshot):
    entry=snapshot.get('entrypoint',{});known=PLATFORM_SERVICES.get(entry.get('path'))
    pid=snapshot.get('process',{}).get('pid')
    if type(pid) is not int or pid<=1:return None
    if (not known or snapshot.get('executable')!='/usr/bin/python3.12'
        or snapshot.get('executableSha256')!=PLATFORM_PYTHON_SHA or snapshot.get('parentPid')!=1
        or snapshot.get('uids')!=[0,0,0,0] or snapshot.get('gids')!=[0,0,0,0]
        or snapshot.get('cgroups')!=[known[1]] or entry.get('sha256')!=known[2]
        or snapshot.get('unit')!=known[1].rsplit('/',1)[1]
        or snapshot.get('unitMainPid')!=snapshot.get('process',{}).get('pid')):return None
    return known[0]

def platform_file_hash(path):
    before=path.lstat()
    need(stat.S_ISREG(before.st_mode) and before.st_uid==0 and not before.st_mode&0o022
        and before.st_size<=10*1024**2,'UNTRUSTED_PLATFORM_FILE')
    with path.open('rb') as stream:raw=stream.read(10*1024**2+1)
    need(len(raw)==before.st_size and len(raw)<=10*1024**2,'PLATFORM_FILE_SIZE_CHANGED')
    digest=hashlib.sha256(raw).hexdigest();after=path.lstat()
    need((before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns)==
        (after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns),'PLATFORM_FILE_CHANGED')
    return digest

def platform_snapshot(value):
    if not dedicated_context() or value['executable']!='/usr/bin/python3.12':return None
    try:
        root=Path('/proc')/str(value['pid']);fields=(root/'stat').read_text().rsplit(')',1)[1].split()
        if int(fields[1])!=1:return None
        with (root/'cmdline').open('rb') as stream:raw=stream.read(16385)
        if len(raw)>16384:return None
        args=raw.rstrip(b'\0').split(b'\0');index=1
        if not args or str(Path(os.fsdecode(args[0])).resolve(strict=True))!=value['executable']:return None
        while index<len(args) and args[index] in (b'-u',b'-B'):index+=1
        if index>=len(args):return None
        entry=os.fsdecode(args[index])
        if entry not in PLATFORM_SERVICES:return None
        unit=PLATFORM_SERVICES[entry][1].rsplit('/',1)[1]
        main_pid=int(subprocess.check_output(['systemctl','show',unit,'--property=MainPID','--value'],timeout=10).decode().strip())
        if main_pid!=value['pid']:return None
        status={line.split(':',1)[0]:line.split(':',1)[1].split() for line in (root/'status').read_text().splitlines() if ':' in line}
        snapshot=dict(process=value,parentPid=int(fields[1]),executable=value['executable'],
            executableSha256=platform_file_hash(Path(value['executable'])),uids=list(map(int,status['Uid'])),
            gids=list(map(int,status['Gid'])),cgroups=(root/'cgroup').read_text().splitlines(),
            unit=unit,unitMainPid=main_pid,entrypoint=dict(path=entry,sha256=platform_file_hash(Path(entry))))
        role=classify_platform(snapshot)
        if role is None or identity(value['pid'])!=value:return None
        return dict(role=role,**snapshot)
    except (OSError,ValueError,KeyError,subprocess.SubprocessError):return None

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

def census(owner,witness=None):
    witness={} if witness is None else witness
    candidates=[];platform=[]
    witness.update(activeHeavyPhases=0,processes=candidates,baselineExceptions=platform,preexistingRunningContainers=[])
    need(owner==identity(os.getpid()) and alive(owner),'OWNER_IS_NOT_ACTUAL_SAMPLER')
    running=subprocess.check_output(['docker','--host','unix:///var/run/docker.sock','container','ls','--no-trunc','--quiet'],timeout=20).decode().split()
    witness['preexistingRunningContainers']=running
    need(all(re.fullmatch('[a-f0-9]{64}',value) for value in running),'INCOMPLETE_CONTAINER_CENSUS')
    need(not running,'PREEXISTING_RUNNING_CONTAINERS')
    heavy={'java','javac','node','nodejs','npm','mvn','maven','gradle','runc','cc1','cc1plus',
        'mariadbd','mysqld','postgres','postmaster','redis-server','make','cmake','ninja',
        'gcc','g++','cc','c++','clang','clang++','rustc','cargo','go','dotnet','csc'}
    for entry in Path('/proc').iterdir():
        if not entry.name.isdigit() or int(entry.name)<=1:continue
        try:
            value=identity(int(entry.name));name=Path(value['executable']).name.lower()
            if value==owner:continue
            if name in heavy or name.startswith('python'):
                known=platform_snapshot(value)
                if known is not None:
                    platform.append(known);continue
                candidates.append(value)
                witness['activeHeavyPhases']=len(candidates)
        except (FileNotFoundError,ProcessLookupError):continue
    need(owner==identity(os.getpid()) and alive(owner) and all(alive(value) for value in
        candidates+[row['process'] for row in platform]),'PROCESS_GENERATION_CHANGED')
    return witness

def assess(bootstrap,paths,owner,witness=None,persist_preflight=None):
    witness={} if witness is None else witness
    budget=dict(memory_gib=4,disk_gib=6)
    witness.update(schema='leadya-dedicated-linux-admission/v1',assessment='SAMPLING',budget=budget,
        owner=owner,windowsLedgerReceipt=False,sharedHostAdmission=False,policyInvoked=False)
    need(dedicated_context(),'DEDICATED_UBUNTU_JOB_REQUIRED')
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
    witness['originalGateBlob']=expected
    witness['census']={}
    phases=census(owner,witness['census']);sample=measure(paths)
    witness['measurement']=sample
    need(alive(owner),'OWNER_ENDED')
    timestamp=datetime.datetime.fromisoformat(sample['checked_at'])
    need(0<=(datetime.datetime.now(datetime.timezone.utc)-timestamp).total_seconds()<=15,'STALE_SAMPLE')
    witness['assessment']='MEASURED'
    if persist_preflight is not None:persist_preflight(witness)
    witness['policyInvoked']=True
    try:namespace['assess'](sample,budget=budget,active=phases['activeHeavyPhases'])
    except Exception as error:
        witness.update(assessment='REFUSED',errorType=type(error).__name__)
        raise
    witness['assessment']='PASS'
    return witness

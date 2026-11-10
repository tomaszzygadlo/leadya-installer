"""Generic encrypted database qualification on one disposable hosted VM.

Application fixture code and exact cases come only from the authenticated source.
Never use this worker on a shared or self-hosted runner. No application services,
shared CI controllers, production databases, or persistent volumes are accessed.
"""
from pathlib import Path
import argparse,hashlib,json,os,re,secrets,selectors,shlex,shutil,signal,stat,subprocess,sys,time,traceback,types,uuid
import xml.etree.ElementTree as ET
import private_unit_ci as protocol
import private_linux_admission as admission

IMPLEMENTATION_QUALIFIED=True
DOCKER=['docker','--host','unix:///var/run/docker.sock']
IMAGE='mariadb@sha256:ce66c7be32a03aabe7241d0a10993a2db827ef652a35d25727d92a832ac8ef73'
BOOT_COMMIT='709c62ba7c1dc27588b1608ef1fc3fed5ec2c232'
BOOT_TREE='55e52f37023f971a89ae32fb876a369fe379da15'
BOOT_SHA='1e7b512be3f640563cd3a08854793dfa01da3f5213ad13cef6bc6c665e51d0c9'
CASE_PATH='documentation/plans/subscription-credit-settlement/evidence/e1-db-test-spec.json'
_ACTIVE_JOB_ROOT=None

def need(value,code):protocol.need(value,code)
def sha(raw):return hashlib.sha256(raw).hexdigest()
def digest(path):return sha(path.read_bytes())
def utc():return admission.datetime.datetime.now(admission.datetime.timezone.utc).isoformat()

def write_new(path,raw):
    fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'wb') as output:output.write(raw);output.flush();os.fsync(output.fileno())
    descriptor=os.open(path.parent,os.O_RDONLY|os.O_DIRECTORY)
    try:os.fsync(descriptor)
    finally:os.close(descriptor)

def json_new(path,value):write_new(path,(json.dumps(value,indent=2)+'\n').encode())

def status(root,**changes):
    target=root/'result/unit-status.json';private(target)
    value=json.loads(target.read_bytes());value.update(changes)
    temporary=target.parent/('status-'+uuid.uuid4().hex+'.json');json_new(temporary,value)
    os.replace(temporary,target)
    fd=os.open(target.parent,os.O_RDONLY|os.O_DIRECTORY)
    try:os.fsync(fd)
    finally:os.close(fd)

def private(path):
    protocol.ordinary(path);info=path.stat()
    need(stat.S_ISREG(info.st_mode) and info.st_uid==0 and info.st_nlink==1 and not info.st_mode&0o077,'UNSAFE_PRIVATE_FILE')
    return path

def context():
    need(os.geteuid()==0 and os.environ.get('GITHUB_ACTIONS')=='true'
        and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted' and os.environ.get('RUNNER_OS')=='Linux'
        and os.environ.get('CI_DB_EPHEMERAL_VM')=='ubuntu-24.04','DEDICATED_HOSTED_VM_REQUIRED')
    fields={key:os.environ[key] for key in ('GITHUB_SHA','GITHUB_RUN_ID','GITHUB_RUN_ATTEMPT',
        'DEVUNIT_RED_TREE','DEVUNIT_GREEN_TREE','DEVUNIT_ZIP_SHA256','DEVUNIT_INPUT_REF','DEVUNIT_BASE_COMMIT')}
    for key in ('GITHUB_SHA','DEVUNIT_RED_TREE','DEVUNIT_GREEN_TREE','DEVUNIT_INPUT_REF','DEVUNIT_BASE_COMMIT'):
        need(re.fullmatch('[a-f0-9]{40}',fields[key]),'BAD_IMMUTABLE_ID')
    need(re.fullmatch('[a-f0-9]{64}',fields['DEVUNIT_ZIP_SHA256']),'BAD_ZIP_ID')
    need(all(re.fullmatch('[1-9][0-9]*',fields[key]) for key in ('GITHUB_RUN_ID','GITHUB_RUN_ATTEMPT')),'BAD_RUN_ID')
    return fields

def control(arguments,timeout=20,check=True):
    result=subprocess.run(arguments,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout,check=False)
    need(len(result.stdout)+len(result.stderr)<=2*1024**2,'CONTROL_OUTPUT_LIMIT')
    if check:need(result.returncode==0,'CONTROL_FAILED')
    return result

def state(name):
    raw=control(['systemctl','show',name,'--property=Id,LoadState,ActiveState,SubState,ControlGroup,InvocationID,Result,ExecMainCode,ExecMainStatus,Transient,ExecStart']).stdout.decode()
    return dict(line.split('=',1) for line in raw.splitlines() if '=' in line)

def owner_check(spec):need(admission.alive(spec['ownerProcess']),'OWNER_ENDED')

def safe_test_gid(runner_gid,docker_gid,fallback_gid):
    need(all(type(value) is int and value>=0 for value in (runner_gid,docker_gid,fallback_gid)),'INVALID_GROUP_ID')
    selected=fallback_gid if runner_gid in (0,docker_gid) else runner_gid
    need(selected>0 and selected!=docker_gid,'UNSAFE_TEST_GROUP')
    return selected

def bounded(arguments,cwd,log,environment,owner=None,seconds=900,run_as=None):
    total=0;deadline=time.monotonic()+seconds
    if run_as is not None:
        uid,gid=run_as
        need(type(uid) is int and uid>0 and type(gid) is int and gid>0,'INVALID_TEST_IDENTITY')
        arguments=['/usr/bin/setpriv','--reuid='+str(uid),'--regid='+str(gid),'--clear-groups','--no-new-privs','--',*arguments]
    child=subprocess.Popen(arguments,cwd=cwd,env=environment,stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,stderr=subprocess.STDOUT,start_new_session=True)
    try:
        fd=os.open(log,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
        with os.fdopen(fd,'wb') as output,selectors.DefaultSelector() as selector:
            selector.register(child.stdout,selectors.EVENT_READ)
            while selector.get_map():
                need(time.monotonic()<deadline,'COMMAND_TIMEOUT')
                if owner:owner_check(owner)
                for key,_ in selector.select(.2):
                    block=os.read(key.fileobj.fileno(),65536)
                    if not block:selector.unregister(key.fileobj);continue
                    total+=len(block);need(total<=32*1024**2,'COMMAND_LOG_LIMIT')
                    output.write(block)
            code=child.wait(timeout=max(.01,deadline-time.monotonic()))
            output.flush();os.fsync(output.fileno());return code
    finally:
        if child.poll() is None:
            try:os.killpg(child.pid,signal.SIGKILL)
            except ProcessLookupError:pass
            child.wait(timeout=10)
        child.stdout.close()

def load_job(root):
    need(root.parent==Path('/var/tmp') and re.fullmatch('root-ci-[a-f0-9]{24}',root.name),'FOREIGN_JOB_ROOT')
    protocol.ordinary(root);need(root.stat().st_uid==0 and stat.S_IMODE(root.stat().st_mode)==0o700,'UNSAFE_JOB_ROOT')
    job=json.loads(private(root/'job.json').read_bytes())
    need(job['nonce']==root.name.removeprefix('root-ci-'),'JOB_NAMESPACE_CHANGED')
    for name,expected in job['toolSha256'].items():need(digest(private(root/name))==expected,'FROZEN_TOOL_CHANGED')
    return job

def prepare(input_directory,checkout):
    global _ACTIVE_JOB_ROOT
    need(IMPLEMENTATION_QUALIFIED,'DRAFT_NOT_QUALIFIED');fields=context();os.umask(0o077)
    nonce=uuid.uuid4().hex[:24];root=Path('/var/tmp')/('root-ci-'+nonce);root.mkdir(mode=0o700)
    result=root/'result';result.mkdir(mode=0o700)
    _ACTIVE_JOB_ROOT=root
    uid=int(os.environ['SUDO_UID']);runner_gid=int(os.environ['SUDO_GID']);need(uid>0 and runner_gid>=0,'RUNNER_IDENTITY_REQUIRED')
    docker_gid=Path('/var/run/docker.sock').stat().st_gid
    fallback_gid=runner_gid
    if runner_gid in (0,docker_gid):
        import grp
        fallback_gid=grp.getgrnam('nogroup').gr_gid
    gid=safe_test_gid(runner_gid,docker_gid,fallback_gid)
    workspace=Path(os.environ['RUNNER_TEMP'])/('db-private-workspace-'+nonce)
    protocol.ordinary(workspace.parent);workspace.mkdir(mode=0o700)
    tools={}
    for name in ('run_private_db_units.py','private_linux_admission.py','private_unit_ci.py','private_unit_crypto.ps1','release_source_ci.py'):
        path=checkout/name;protocol.ordinary(path);tools[name]=path.read_bytes()
    job=dict(nonce=nonce,identity=fields,source=str(workspace/'source'),control=str(root/'input/control'),
        bootstrap=str(root/'bootstrap/source'),result=str(result),workspace=str(workspace),testUid=uid,testGid=gid,runnerGid=runner_gid,
        toolSha256={name:sha(raw) for name,raw in tools.items()})
    json_new(root/'job.json',job)
    # Publish the safe location early so failed preparations can still be sealed.
    with Path(os.environ['GITHUB_ENV']).open('a') as environment:environment.write('DBJOB_ROOT='+str(root)+'\n')
    json_new(result/'identity.json',dict(workflow_commit=fields['GITHUB_SHA'],run_id=fields['GITHUB_RUN_ID'],
        run_attempt=fields['GITHUB_RUN_ATTEMPT'],runner_os='Linux',runner_arch=os.environ.get('RUNNER_ARCH'),
        red_tree=fields['DEVUNIT_RED_TREE'],prospective_green_tree=fields['DEVUNIT_GREEN_TREE'],source_zip_sha256=fields['DEVUNIT_ZIP_SHA256']))
    json_new(result/'unit-status.json',dict(status='PREPARATION_PENDING',runtime_tests='NOT_RUN'))
    for name,raw in tools.items():write_new(root/name,raw)
    common=['pwsh','-NoLogo','-NoProfile','-NonInteractive','-File',str(root/'private_unit_crypto.ps1'),
        '-InputDirectory',str(input_directory),'-RedTree',fields['DEVUNIT_RED_TREE'],
        '-GreenTree',fields['DEVUNIT_GREEN_TREE'],'-ZipSha256',fields['DEVUNIT_ZIP_SHA256']]
    for action,name in (('bootstrap','bootstrap.tar.xz'),('decrypt','source.zip')):
        code=bounded(common+['-Action',action,'-OutputPath',str(root/name)],root,result/(action+'.log'),dict(os.environ),seconds=60)
        need(code==0,'CRYPTO_PREPARATION_FAILED')
    clean={key:value for key,value in os.environ.items() if key not in ('DEVUNIT_BOOTSTRAP_KEY','DEVUNIT_SOURCE_KEY','LEADYA_RESULT_KEY')}
    code=bounded([sys.executable,str(root/'release_source_ci.py'),'materialize','--archive',str(root/'bootstrap.tar.xz'),
        '--archive-sha256',BOOT_SHA,'--commit',BOOT_COMMIT,'--tree',BOOT_TREE,'--destination',str(root/'bootstrap')],
        root,result/'bootstrap-materialize.log',clean,seconds=120)
    need(code==0,'ORIGINAL_BOOTSTRAP_REFUSED')
    provenance=protocol.materialize(root/'source.zip',root/'input',fields['DEVUNIT_RED_TREE'],fields['DEVUNIT_GREEN_TREE'],fields['DEVUNIT_ZIP_SHA256'])
    protocol.apply_green(root/'input/source',root/'input/control',fields['DEVUNIT_RED_TREE'],fields['DEVUNIT_GREEN_TREE'])
    shutil.move(str(root/'input/source'),str(workspace/'source'))
    for name in ('home','m2','fixture'):(workspace/name).mkdir(mode=0o700)
    for folder,dirs,files in os.walk(workspace,followlinks=False):
        for name in dirs+files:
            path=Path(folder)/name;protocol.ordinary(path);os.chown(path,uid,gid)
    os.chown(workspace,uid,gid)
    json_new(result/'input-provenance.json',provenance)
    print(json.dumps(dict(prepared=True,sourceTree=fields['DEVUNIT_GREEN_TREE'])),flush=True)

def source_rows(root,job):
    green=protocol.load_json(Path(job['control'])/'green-manifest.json')
    return protocol.manifest(green,job['identity']['DEVUNIT_GREEN_TREE'])

def checked_case_spec(root,job,rows):
    source=Path(job['source']);need(CASE_PATH in rows,'MISSING_PRIVATE_CASE_SPEC')
    raw=(source/CASE_PATH).read_bytes();need(sha(raw)==rows[CASE_PATH]['sha256'],'CASE_SPEC_CHANGED')
    cases=json.loads(raw);need(cases['schemaVersion']==1 and len(cases['suites'])==2,'BAD_CASE_SPEC')
    need(cases['module']=='SpringAppBase' and cases['expectedClassCount']==2
        and cases['expectedTotalTests']==sum(row['testCount'] for row in cases['suites'])
        and cases['execution']['forkCount']==1 and cases['execution']['reuseForks'] is True
        and cases['execution']['parallelClasses'] is False,'UNSUPPORTED_EXECUTION_CONTRACT')
    helper=cases['fixtureHelper'];need(helper['path'] in rows and rows[helper['path']]['sha256']==helper['sha256'],'HELPER_NOT_SOURCE_BOUND')
    for suite in cases['suites']:
        need(protocol.CLASS.fullmatch(suite['className']) and suite['sourcePath']==cases['module']+'/src/test/java/'+suite['className'].replace('.','/')+'.java'
            and all(protocol.METHOD.fullmatch(name) for name in suite['methods']),'BAD_CASE_SOURCE_MAPPING')
        need(suite['sourcePath'] in rows and rows[suite['sourcePath']]['sha256']==suite['canonicalSha256'],'CASE_SOURCE_CHANGED')
        need(suite['testCount']==len(suite['methods'])>0 and len(set(suite['methods']))==len(suite['methods']),'BAD_CLOSED_CASE_SET')
    need(len(set(row['className'] for row in cases['suites']))==2,'DUPLICATE_SUITE')
    need(len(cases['migrationPaths'])==2 and all(path in rows for path in cases['migrationPaths']),'MIGRATIONS_NOT_SOURCE_BOUND')
    return cases

def start_slice(nonce):
    name='root-ci-'+nonce+'.slice';service='root-ci-'+nonce+'.service'
    existing=control(['systemctl','list-units','--all','--plain','--no-legend','--full','--no-pager',name,service]).stdout
    definitions=control(['systemctl','list-unit-files','--no-legend','--full','--no-pager']).stdout.decode().splitlines()
    need(definitions and not existing.strip() and not {name,service}&{line.split()[0] for line in definitions if line.strip()},'UNIT_COLLISION')
    control(['busctl','call','org.freedesktop.systemd1','/org/freedesktop/systemd1','org.freedesktop.systemd1.Manager',
        'StartTransientUnit','ssa(sv)a(sa(sv))',name,'fail','4','Description','s','Private bounded database qualification',
        'MemoryMax','t',str(4*1024**3),'CPUQuotaPerSecUSec','t','2000000','TasksMax','t','512','0'])
    value=state(name);group=value['ControlGroup']
    need(value['ActiveState']=='active' and group.endswith('/'+name),'SLICE_NOT_ACTIVE')
    path=Path('/sys/fs/cgroup')/group.lstrip('/')
    need((path/'memory.max').read_text().strip()==str(4*1024**3) and (path/'pids.max').read_text().strip()=='512','LIMITS_NOT_APPLIED')
    maximum,period=(path/'cpu.max').read_text().split();need(int(maximum)==2*int(period),'CPU_LIMIT_NOT_APPLIED')
    return name,service,group

def inspect_db(root,spec):
    name='/root-ci-'+spec['nonce']+'-db';journal_path=root/'container-create-db.json'
    result=control(DOCKER+['inspect',name[1:]],check=False)
    if result.returncode:
        census=[json.loads(line) for line in control(DOCKER+['container','ls','--all','--no-trunc','--format','{{json .}}']).stdout.decode().splitlines()]
        need(all(re.fullmatch('[a-f0-9]{64}',row.get('ID','')) for row in census),'INCOMPLETE_CONTAINER_CENSUS')
        need(name[1:] not in {row['Names'] for row in census},'CONTAINER_INSPECTION_UNKNOWN')
        if journal_path.exists():
            journal=json.loads(private(journal_path).read_bytes());need(journal['containerId'] not in {row['ID'] for row in census},'PINNED_CONTAINER_RENAMED')
        return None
    need(journal_path.is_file(),'UNJOURNALED_CONTAINER_REQUIRES_RECONCILIATION')
    journal=json.loads(private(journal_path).read_bytes());value=json.loads(result.stdout)[0]
    need(value['Id']==journal['containerId'] and value['Name']==name and value['Image']==journal['imageId']
        and value['HostConfig']['CgroupParent']==spec['slice']
        and value['Config']['Labels'].get('leadya.ci.nonce')==spec['nonce']
        and value['Config']['Labels'].get('leadya.ci.commit')==spec['commit'],'FOREIGN_CONTAINER')
    return value

def cleanup(root,spec):
    child=inspect_db(root,spec)
    if child is not None and child['State']['Running']:control(DOCKER+['stop','--time','5',child['Id']],timeout=15)
    child=inspect_db(root,spec);need(child is None or not child['State']['Running'],'DB_CHILD_STILL_RUNNING')
    target=root/'result'/('cleanup-'+uuid.uuid4().hex+'.json')
    json_new(target,dict(nonce=spec['nonce'],containerId=None if child is None else child['Id'],closed=True,at=utc()))

def load_spec(root,expected):
    raw=private(root/'run-spec.json').read_bytes();need(sha(raw)==expected,'RUN_SPEC_CHANGED')
    spec=json.loads(raw);need(spec['nonce']==root.name.removeprefix('root-ci-')
        and spec['slice']=='root-ci-'+spec['nonce']+'.slice','FOREIGN_RUN_SPEC')
    need(digest(private(root/'job.json'))==spec['jobSha256'],'JOB_BINDING_CHANGED')
    return spec

def close_empty_intent(root,job):
    intent=json.loads(private(root/'slice-intent.json').read_bytes())
    need(intent['nonce']==job['nonce'] and intent['jobSha256']==digest(root/'job.json')
        and not admission.alive(intent['ownerProcess']),'FOREIGN_OR_LIVE_SLICE_INTENT')
    slice_name='root-ci-'+job['nonce']+'.slice';service='root-ci-'+job['nonce']+'.service'
    listed=control(['systemctl','list-units','--all','--plain','--no-legend','--full','--no-pager',slice_name,service]).stdout.decode().splitlines()
    names={line.split()[0] for line in listed if line.strip()}
    need(names<={slice_name} and not (root/'container-create-db-intent.json').exists()
        and not (root/'container-create-db.json').exists(),'UNEXPECTED_WORKLOAD_BEFORE_RUN_SPEC')
    inventory=[json.loads(line) for line in control(DOCKER+['container','ls','--all','--no-trunc','--format','{{json .}}']).stdout.decode().splitlines()]
    need(all(re.fullmatch('[a-f0-9]{64}',row.get('ID','')) for row in inventory)
        and 'root-ci-'+job['nonce']+'-db' not in {row['Names'] for row in inventory},'UNJOURNALED_DB_BEFORE_RUN_SPEC')
    if slice_name in names:
        actual=state(slice_name)
        need(actual.get('Id')==slice_name and actual.get('Transient')=='yes','FOREIGN_PREWORK_SLICE')
        group=actual.get('ControlGroup','')
        if group:
            need(group.startswith('/') and group.endswith('/'+slice_name),'FOREIGN_PREWORK_GROUP')
            path=Path('/sys/fs/cgroup')/group.lstrip('/')
            events=dict(line.split() for line in (path/'cgroup.events').read_text().splitlines())
            need(events['populated']=='0' and (path/'memory.max').read_text().strip()==str(4*1024**3)
                and (path/'pids.max').read_text().strip()=='512','PREWORK_GROUP_NOT_EMPTY_OR_OWNED')
        control(['systemctl','stop',slice_name],timeout=30)
    json_new(root/'result/prework-closure.json',dict(nonce=job['nonce'],heavyWorkloadStarted=False,closed=True,at=utc()))

def close_resources(root,spec,rows,job):
    current=state(spec['service'])
    if current.get('LoadState')!='not-found':
        need(current.get('Id')==spec['service'] and current.get('Transient')=='yes'
            and current.get('ControlGroup') in ('',spec['group']+'/'+spec['service'])
            and str(root/'run_private_db_units.py') in current.get('ExecStart','')
            and digest(root/'run-spec.json') in current.get('ExecStart',''),'FOREIGN_UNIT_BEFORE_CLOSURE')
        control(['systemctl','stop',spec['service']],timeout=140,check=False)
    cleanup(root,spec)
    control(['systemctl','stop',spec['slice']],timeout=30)
    cgroup=Path('/sys/fs/cgroup')/spec['group'].lstrip('/')
    if cgroup.exists():
        events=dict(line.split() for line in (cgroup/'cgroup.events').read_text().splitlines())
        need(events['populated']=='0','OWNED_GROUP_STILL_POPULATED')
    else:
        actual=state(spec['slice'])
        need(actual.get('ActiveState') in ('inactive','failed') or actual.get('LoadState')=='not-found','OWNED_GROUP_UNKNOWN')
    child=inspect_db(root,spec);need(child is None or not child['State']['Running'],'OWNED_DB_NOT_CLOSED')
    if child is not None:control(DOCKER+['rm',child['Id']],timeout=20)
    protocol.verify_files(Path(job['source']),rows,generated=True)
    json_new(root/'result'/('closure-'+uuid.uuid4().hex+'.json'),dict(nonce=spec['nonce'],wholeGroupEmpty=True,
        exactDbClosed=True,sourceRechecked=True,at=utc()))

def recover(root):
    job=load_job(root);need(job['identity']==context(),'RECOVERY_CONTEXT_CHANGED')
    if not (root/'run-spec.json').exists() or not (root/'run-spec.sha256').exists():
        if (root/'slice-intent.json').exists():close_empty_intent(root,job)
        else:json_new(root/'result/no-workload-resource.json',dict(heavyWorkloadStarted=False))
        return
    spec=load_spec(root,private(root/'run-spec.sha256').read_text().strip())
    need(not admission.alive(spec['ownerProcess']),'ORIGINAL_EXECUTOR_STILL_ALIVE')
    close_resources(root,spec,source_rows(root,job),job)

def evaluate_reports(root,job,cases,started,java_home=None):
    reports=Path(job['source'])/'SpringAppBase/target/surefire-reports';destination=root/'result/db-reports';destination.mkdir(mode=0o700)
    files=sorted(reports.glob('TEST-*.xml')) if reports.is_dir() else []
    total=0
    for file in files:
        protocol.ordinary(file);before=file.stat();need(before.st_size<=8*1024**2,'XML_SIZE_LIMIT')
        raw=file.read_bytes();after=file.stat();total+=len(raw)
        need((before.st_ino,before.st_size,before.st_mtime_ns)==(after.st_ino,after.st_size,after.st_mtime_ns)
            and total<=32*1024**2,'XML_CHANGED_OR_TOO_LARGE')
        write_new(destination/file.name,raw)
    need(len(files)==len(cases['suites']),'WRONG_SUITE_COUNT')
    expected={row['className']:row for row in cases['suites']};seen=set();summary=[]
    for file in files:
        raw=(destination/file.name).read_bytes();need(b'<!DOCTYPE' not in raw and b'<!ENTITY' not in raw,'XML_DECLARATION_REFUSED')
        suite=ET.fromstring(raw);name=suite.attrib['name'];need(suite.tag=='testsuite' and name in expected and name not in seen,'WRONG_SUITE')
        seen.add(name);wanted=expected[name];items=suite.findall('testcase');names=[case.attrib['name'] for case in items]
        need(file.stat().st_mtime>=started,'STALE_XML')
        need(int(suite.attrib['tests'])==len(items)==wanted['testCount'] and len(set(names))==len(names)
            and set(names)==set(wanted['methods']),'WRONG_CASE_SET')
        need(all(int(suite.attrib.get(key,'0'))==0 for key in ('failures','errors','skipped')),'FAILED_DB_SUITE')
        need(all(case.get('classname')==name and not any(case.find(tag) is not None for tag in ('failure','error','skipped')) for case in items),'FAILED_DB_CASE')
        if java_home is not None:
            properties={item.get('name'):item.get('value') for item in suite.findall('properties/property')}
            need(properties.get('java.specification.version')=='17'
                and Path(properties.get('java.home','')).resolve()==Path(java_home).resolve(),'WRONG_TEST_JVM')
        summary.append(dict(className=name,tests=len(items),failures=0,errors=0,skips=0,xmlSha256=sha(raw)))
    return summary

def wait_ready(root,spec,environment):
    deadline=time.monotonic()+90
    while time.monotonic()<deadline:
        owner_check(spec);child=inspect_db(root,spec)
        need(child is not None and child['State']['Running'] and child['RestartCount']==0,'DB_STOPPED_OR_RESTARTED')
        arguments=DOCKER+['exec','-i','--env','MYSQL_PWD',child['Id'],'mariadb','--protocol=socket',
            '--user=root','--connect-timeout=1','--batch','--skip-column-names']
        process=subprocess.Popen(arguments,env=environment,stdin=subprocess.PIPE,stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,start_new_session=True)
        try:
            output,_=process.communicate(b'SELECT 1;\n',timeout=3)
            if process.returncode==0 and output.strip()==b'1':return
        except subprocess.TimeoutExpired:
            os.killpg(process.pid,signal.SIGKILL);process.communicate(timeout=5)
        time.sleep(.5)
    raise ValueError('DB_STARTUP_TIMEOUT')

def fixture(root,spec,job,cases,environment):
    source=Path(job['source']);helper=cases['fixtureHelper'];protocol.ordinary(source/helper['path']);raw=(source/helper['path']).read_bytes()
    need(sha(raw)==helper['sha256'],'FIXTURE_HELPER_CHANGED')
    helper_path=root/'fixture_init.py';write_new(helper_path,raw)
    module=types.ModuleType('authenticated_private_fixture');module.__file__=str(helper_path)
    exec(compile(raw,str(helper_path),'exec'),module.__dict__)
    need(re.fullmatch('[a-f0-9-]{36}',module.OPERATOR) and re.fullmatch('[a-f0-9-]{36}',module.OWNER),'INVALID_FIXTURE_OWNER')
    need(not (root/'container-create-db.json').exists(),'EXISTING_CREATE_JOURNAL')
    need(inspect_db(root,spec) is None,'EXISTING_CONTAINER_NAME')
    need(bounded(DOCKER+['pull','--quiet',IMAGE],root,root/'result/docker-pull.log',environment,spec,seconds=600)==0,'PINNED_IMAGE_PULL_FAILED')
    image=json.loads(control(DOCKER+['image','inspect',IMAGE]).stdout)
    need(len(image)==1 and IMAGE in image[0]['RepoDigests'] and re.fullmatch('sha256:[a-f0-9]{64}',image[0]['Id']),'IMAGE_IDENTITY_REFUSED')
    password=secrets.token_hex(32);write_new(root/'db-root.env',('MARIADB_ROOT_PASSWORD='+password+'\n').encode())
    name='root-ci-'+spec['nonce']+'-db'
    json_new(root/'container-create-db-intent.json',dict(nonce=spec['nonce'],imageRef=IMAGE,imageId=image[0]['Id'],at=utc()))
    write_new(root/'result/container-create-db-intent.json',private(root/'container-create-db-intent.json').read_bytes())
    args=DOCKER+['create','--name',name,'--cgroup-parent',spec['slice'],
        '--label','leadya.ci.nonce='+spec['nonce'],'--label','leadya.ci.commit='+spec['commit'],
        '--label','leadya.ci.owner='+module.OPERATOR,'--label','leadya.fixture.owner='+module.OWNER,
        '--label','leadya.fixture.task='+module.TASK,'--restart=no','--memory=512m','--memory-swap=512m',
        '--cpus=0.5','--pids-limit=128','--network=bridge','--publish','127.0.0.1::3306',
        '--tmpfs','/var/lib/mysql:rw,noexec,nosuid,size=512m','--env-file',str(root/'db-root.env'),IMAGE]
    owner_check(spec);cid=control(args,timeout=30).stdout.decode().strip();need(re.fullmatch('[a-f0-9]{64}',cid),'BAD_CREATE_CID')
    journal=dict(schema='leadya-owned-container-create/v1',nonce=spec['nonce'],owner=module.OPERATOR,
        commit=spec['commit'],tree=spec['tree'],role='db',containerId=cid,name='/'+name,
        parentSlice=spec['slice'],imageRef=IMAGE,imageId=image[0]['Id'],createdAt=utc())
    json_new(root/'container-create-db.json',journal)
    write_new(root/'result/container-create-db.json',private(root/'container-create-db.json').read_bytes())
    need(not inspect_db(root,spec)['State']['Running'],'DB_STARTED_BEFORE_CUSTODY')
    owner_check(spec);control(DOCKER+['start',cid],timeout=30)
    ready_environment=dict(environment,MYSQL_PWD=password);wait_ready(root,spec,ready_environment)
    runtime=dict(nonce=spec['nonce'],owner=module.OPERATOR,commit=spec['commit'],tree=spec['tree'],
        slice=spec['slice'],containerRoles=['db'],dbContainerId=cid,
        validUntil=(admission.datetime.datetime.now(admission.datetime.timezone.utc)+admission.datetime.timedelta(minutes=50)).isoformat())
    json_new(root/'db-fixture-runtime.json',runtime)
    write_new(root/'result/fixture-custody-spec.json',private(root/'db-fixture-runtime.json').read_bytes())
    arguments=[sys.executable,str(helper_path),'--spec',str(root/'db-fixture-runtime.json'),
        '--journal',str(root/'container-create-db.json'),'--journal-sha256',digest(root/'container-create-db.json'),
        '--root-env',str(root/'db-root.env'),'--output-dir',str(root/'fixture-output'),
        '--migration',str(source/cases['migrationPaths'][0])]
    need(bounded(arguments,root,root/'result/fixture-helper.log',environment,spec,seconds=120)==0,'FIXTURE_INIT_FAILED')
    write_new(root/'result/fixture-receipt.json',private(root/'fixture-output/receipt.json').read_bytes())
    values={}
    for line in private(root/'fixture-output/fixture.env').read_text().splitlines():
        if line:
            key,value=line.split('=',1);need(key not in values,'DUPLICATE_FIXTURE_ENV');values[key]=value
    need(set(values)=={'LEADYA_E1_FIXTURE_RECEIPT','LEADYA_E1_TEST_USER','LEADYA_E1_TEST_PASSWORD','LEADYA_E1_MIGRATION_FILE'},'UNEXPECTED_FIXTURE_ENV')
    need(values['LEADYA_E1_FIXTURE_RECEIPT']==str(root/'fixture-output/receipt.json')
        and values['LEADYA_E1_MIGRATION_FILE']==str(source/cases['migrationPaths'][0]),'FIXTURE_PATH_CHANGED')
    readable=Path(job['workspace'])/'fixture/receipt.json'
    write_new(readable,private(root/'fixture-output/receipt.json').read_bytes())
    os.chown(readable,job['testUid'],job['testGid'])
    values['LEADYA_E1_FIXTURE_RECEIPT']=str(readable)
    return values,journal

def inner(root,spec):
    job=load_job(root);rows=source_rows(root,job);cases=checked_case_spec(root,job,rows)
    protocol.verify_files(Path(job['source']),rows)
    owner_check(spec);status(root,status='RUNNING',stage='compile',qualification_kind='real-mariadb-only')
    home=Path(job['workspace'])/'home';repository=Path(job['workspace'])/'m2'
    test_identity=(job['testUid'],job['testGid'])
    java=Path(spec['javaHome']);need((java/'bin/java').is_file(),'JDK17_UNAVAILABLE')
    control_home=root/'control-home';control_home.mkdir(mode=0o700)
    environment=dict(PATH=str(java/'bin')+':/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
        JAVA_HOME=str(java),HOME=str(control_home),LANG='C.UTF-8',DOCKER_HOST='unix:///var/run/docker.sock',
        MAVEN_OPTS='-Xmx1536m -XX:MaxMetaspaceSize=512m -Duser.home='+str(home))
    maven_environment=dict(environment,HOME=str(home))
    result=root/'result';source=Path(job['source'])
    need(bounded([str(java/'bin/java'),'-version'],root,result/'java-version.log',environment,spec,seconds=20)==0,'JDK_VERSION_FAILED')
    need(re.search(r'version "17\.',(result/'java-version.log').read_text()),'JDK17_REQUIRED')
    need(bounded(['mvn','-version'],root,result/'maven-version.log',environment,spec,seconds=20)==0,'MAVEN_VERSION_FAILED')
    witness_code='''import json,os,socket,sys
from pathlib import Path
probe=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);accessible=False
try:probe.connect('/var/run/docker.sock');accessible=True
except PermissionError:pass
finally:probe.close()
writable=False
try:
 fd=os.open(Path(sys.argv[1])/'job.json',os.O_WRONLY);os.close(fd);writable=True
except PermissionError:pass
status=dict(line.split(':',1) for line in Path('/proc/self/status').read_text().splitlines() if ':' in line)
print(json.dumps(dict(uid=os.geteuid(),gid=os.getegid(),groups=os.getgroups(),noNewPrivs=status['NoNewPrivs'].strip(),
 dockerAccessible=accessible,controlMetadataWritable=writable,cgroup=Path('/proc/self/cgroup').read_text().strip().split('::',1)[1])))
'''
    need(bounded([sys.executable,'-c',witness_code,str(root)],Path(job['workspace']),result/'privilege-witness.log',
        maven_environment,spec,seconds=20,run_as=test_identity)==0,'PRIVILEGE_WITNESS_FAILED')
    witness=json.loads((result/'privilege-witness.log').read_bytes())
    need(witness['uid']==job['testUid'] and witness['gid']==job['testGid'] and witness['groups']==[]
        and witness['noNewPrivs']=='1' and not witness['dockerAccessible'] and not witness['controlMetadataWritable']
        and witness['cgroup']==spec['group']+'/'+spec['service'],'TEST_PROCESS_ISOLATION_REFUSED')
    options=['mvn','-B','-ntp','-Dstyle.color=never','-Dmaven.antrun.skip=true','-Dmaven.repo.local='+str(repository)]
    for vendor in protocol.VENDORS:
        need(bounded(options+['-f',vendor+'/pom.xml','clean','install','-DskipTests'],source,
            result/('vendor-'+vendor+'.log'),maven_environment,spec,run_as=test_identity)==0,'VENDOR_COMPILE_FAILED')
    need(bounded(options+['-pl','SpringAppBase','-am','clean','install','-DskipTests'],source,
        result/'compile.log',maven_environment,spec,run_as=test_identity)==0,'DB_TEST_COMPILE_FAILED')
    protocol.verify_files(source,rows,generated=True)
    values,journal=fixture(root,spec,job,cases,environment);maven_environment.update(values)
    status(root,stage='real-db-tests')
    command=options+['-pl','SpringAppBase','-am','test','-Dtest='+','.join(row['className'] for row in cases['suites']),
        '-Dsurefire.failIfNoSpecifiedTests=false','-DfailIfNoTests=false','-DforkCount=1','-DreuseForks=true',
        '-Djunit.jupiter.execution.parallel.enabled=false','-Djunit.jupiter.execution.parallel.mode.default=same_thread',
        '-Djunit.jupiter.execution.parallel.mode.classes.default=same_thread','-Dparallel=none','-DthreadCount=1',
        '-DargLine=-Xmx768m -Duser.home='+str(home)]
    started=time.time();summary=None;code=None
    try:code=bounded(command,source,result/'db-tests.log',maven_environment,spec,seconds=900,run_as=test_identity)
    finally:
        try:summary=evaluate_reports(root,job,cases,started,spec['javaHome'])
        except Exception as error:json_new(result/'db-report-refusal.json',dict(errorType=type(error).__name__))
    need(code==0 and summary is not None,'DB_TESTS_DID_NOT_FULLY_PASS')
    protocol.verify_files(source,rows,generated=True)
    child=inspect_db(root,spec);receipt=json.loads(private(root/'fixture-output/receipt.json').read_bytes())
    need(child is not None and child['Id']==journal['containerId'] and child['State']['Running'] and child['RestartCount']==0,'DB_IDENTITY_CHANGED')
    need(receipt['sourceCommit']==spec['commit'] and receipt['sourceTree']==spec['tree']
        and receipt['containerId']==journal['containerId'] and receipt['createJournalSha256']==digest(root/'container-create-db.json')
        and receipt['engineVersion'].startswith('10.11.'),'FIXTURE_RECEIPT_CHANGED')
    json_new(result/'body-result.json',dict(status='PASS',sourceBaseCommit=spec['commit'],prospectiveGreenTree=spec['tree'],
        sourceZipSha256=job['identity']['DEVUNIT_ZIP_SHA256'],suites=summary,engineVersion=receipt['engineVersion'],
        containerId=journal['containerId'],fixtureReceiptSha256=digest(root/'fixture-output/receipt.json'),
        startedAt=started,finishedAt=utc()))

def execute(root):
    need(IMPLEMENTATION_QUALIFIED,'DRAFT_NOT_QUALIFIED');job=load_job(root);need(job['identity']==context(),'EXECUTION_CONTEXT_CHANGED')
    rows=source_rows(root,job);checked_case_spec(root,job,rows);protocol.verify_files(Path(job['source']),rows)
    need(Path('/proc/1/comm').read_text().strip()=='systemd' and Path('/sys/fs/cgroup/cgroup.controllers').is_file(),'SYSTEMD_CGROUP_V2_REQUIRED')
    info=json.loads(control(DOCKER+['info','--format','{{json .}}']).stdout)
    need(info['CgroupDriver']=='systemd' and str(info['CgroupVersion'])=='2','DOCKER_SYSTEMD_V2_REQUIRED')
    owner=admission.identity(os.getpid());repository=Path(job['workspace'])/'m2'
    preview={}
    binding=dict(nonce=job['nonce'],workflowCommit=job['identity']['GITHUB_SHA'],
        runId=job['identity']['GITHUB_RUN_ID'],sourceTree=job['identity']['DEVUNIT_GREEN_TREE'])
    def persist_preflight(snapshot):json_new(root/'result/linux-admission-preflight.json',dict(binding,**snapshot))
    try:evidence=admission.assess(Path(job['bootstrap']),[Path(job['source']),Path(info['DockerRootDir']),repository],owner,preview,persist_preflight)
    except Exception as error:
        preview.update(assessment='REFUSED',errorType=type(error).__name__)
        raise
    finally:
        json_new(root/'result/linux-admission-outcome.json',dict(binding,**preview))
    json_new(root/'result/linux-admission.json',dict(nonce=job['nonce'],workflowCommit=job['identity']['GITHUB_SHA'],
        runId=job['identity']['GITHUB_RUN_ID'],sourceTree=job['identity']['DEVUNIT_GREEN_TREE'],**evidence))
    json_new(root/'slice-intent.json',dict(nonce=job['nonce'],jobSha256=digest(root/'job.json'),
        ownerProcess=owner,slice='root-ci-'+job['nonce']+'.slice',service='root-ci-'+job['nonce']+'.service',at=utc()))
    slice_name,service,group=start_slice(job['nonce'])
    spec=dict(nonce=job['nonce'],slice=slice_name,service=service,group=group,ownerProcess=owner,
        commit=job['identity']['DEVUNIT_BASE_COMMIT'],tree=job['identity']['DEVUNIT_GREEN_TREE'],javaHome=os.environ['JAVA_HOME_17_X64'],
        jobSha256=digest(root/'job.json'))
    json_new(root/'run-spec.json',spec);spec_sha=digest(root/'run-spec.json')
    write_new(root/'run-spec.sha256',(spec_sha+'\n').encode())
    write_new(root/'result/run-spec.json',private(root/'run-spec.json').read_bytes())
    worker=root/'run_private_db_units.py';arguments=[sys.executable,str(worker),'inner','--job-root',str(root),'--spec-sha256',spec_sha]
    cleanup_arguments=[sys.executable,str(worker),'cleanup','--job-root',str(root),'--spec-sha256',spec_sha]
    need(all(re.fullmatch('[A-Za-z0-9_./:-]+',value) for value in cleanup_arguments),'UNSAFE_UNIT_ARGUMENT')
    passed=False;terminal={};closed=False
    try:
        control(['systemd-run','--quiet','--unit='+service,'--slice='+slice_name,'--property=Type=exec',
            '--property=RuntimeMaxSec=1800','--property=TimeoutStopSec=120','--property=KillMode=control-group',
            '--property=ExecStopPost='+' '.join(cleanup_arguments),
            '--property=StandardOutput=append:'+str(root/'result/driver.log'),'--property=StandardError=inherit']+arguments)
        deadline=time.monotonic()+1980
        while True:
            need(admission.alive(owner),'OWNER_ENDED');terminal=state(service)
            if terminal.get('ActiveState') in ('inactive','failed'):break
            need(time.monotonic()<deadline,'OWNED_UNIT_TIMEOUT');time.sleep(.5)
        body=json.loads(private(root/'result/body-result.json').read_bytes()) if (root/'result/body-result.json').exists() else {}
        passed=(terminal.get('Result')=='success' and terminal.get('ExecMainStatus')=='0' and body.get('status')=='PASS'
            and body.get('prospectiveGreenTree')==spec['tree'] and body.get('sourceBaseCommit')==spec['commit'])
    finally:
        close_resources(root,spec,rows,job);closed=True
    json_new(root/'result/final-verdict.json',dict(status='PASS' if passed and closed else 'FAILED',
        testsPassed=passed,closure=closed,sourceTree=spec['tree'],at=utc()))
    status(root,status='PASS' if passed and closed else 'FAILED',stage='closed',closure=closed,
        runtime_tests='PASS' if passed else 'FAILED')
    need(passed and closed,'QUALIFICATION_DID_NOT_PASS')

def seal(root):
    job=load_job(root);need(job['identity']==context(),'SEAL_CONTEXT_CHANGED')
    arguments=['pwsh','-NoLogo','-NoProfile','-NonInteractive','-File',str(root/'private_unit_crypto.ps1'),
        '-Action','seal','-InputDirectory',job['result'],'-OutputPath',str(root/'sealed'),
        '-RedTree',job['identity']['DEVUNIT_RED_TREE'],'-GreenTree',job['identity']['DEVUNIT_GREEN_TREE'],
        '-ZipSha256',job['identity']['DEVUNIT_ZIP_SHA256']]
    need(bounded(arguments,root,root/'seal.log',dict(os.environ),seconds=60)==0,'RESULT_SEAL_FAILED')
    # Only ciphertext and its public authenticated envelope become runner-readable.
    uid=int(os.environ['SUDO_UID']);gid=int(os.environ['SUDO_GID'])
    need(uid==job['testUid'] and gid==job['runnerGid'],'ARTIFACT_RUNNER_IDENTITY_CHANGED')
    destination=Path(os.environ['RUNNER_TEMP'])/'db-private-sealed';protocol.ordinary(destination.parent)
    destination.mkdir(mode=0o700)
    for name in ('result.cipher','result-envelope.json'):
        path=destination/name;write_new(path,(root/'sealed'/name).read_bytes());os.chown(path,uid,gid)
    os.chown(destination,uid,gid)

def main():
    global _ACTIVE_JOB_ROOT
    parser=argparse.ArgumentParser();parser.add_argument('mode',choices=('prepare','execute','inner','cleanup','recover','seal'))
    parser.add_argument('--job-root');parser.add_argument('--spec-sha256');parser.add_argument('--input-directory');parser.add_argument('--checkout')
    args=parser.parse_args();os.umask(0o077)
    need(IMPLEMENTATION_QUALIFIED,'DRAFT_NOT_QUALIFIED')
    if args.mode=='prepare':prepare(Path(args.input_directory).resolve(),Path(args.checkout).resolve());return
    root=Path(args.job_root);job=load_job(root)
    _ACTIVE_JOB_ROOT=root
    if args.mode in ('inner','cleanup'):
        spec=load_spec(root,args.spec_sha256)
        actual=Path('/proc/self/cgroup').read_text().strip().split('::',1)[1]
        need(actual==spec['group']+'/'+spec['service'],'OUTSIDE_OWN_SERVICE')
        (inner if args.mode=='inner' else cleanup)(root,spec)
    elif args.mode=='execute':execute(root)
    elif args.mode=='recover':recover(root)
    else:seal(root)

if __name__=='__main__':
    def interrupted(signum,frame):raise InterruptedError('OWNED_JOB_INTERRUPTED')
    signal.signal(signal.SIGTERM,interrupted)
    try:main()
    except BaseException as error:
        # Application details stay in private evidence; never in public job logs.
        if _ACTIVE_JOB_ROOT is not None:
            try:
                write_new(_ACTIVE_JOB_ROOT/'result'/('worker-error-'+uuid.uuid4().hex+'.log'),traceback.format_exc().encode()[:65536])
                status(_ACTIVE_JOB_ROOT,status='FAILED',errorType=type(error).__name__)
            except Exception:pass
        print(json.dumps(dict(status='FAILED',errorType=type(error).__name__)),flush=True)
        raise SystemExit(1)

"""Pure actual-owner and pre-existing-work guards; no Linux or Docker calls."""
from pathlib import Path
import copy,datetime,hashlib,os,subprocess,types,unittest
from unittest.mock import patch
path=Path(__file__).with_name('private_linux_admission.py');a=types.ModuleType('linux_admission_under_test');a.__file__=str(path)
exec(compile(path.read_bytes(),str(path),'exec'),a.__dict__)

class CensusGuards(unittest.TestCase):
    def setUp(self):self.owner=dict(pid=os.getpid(),startTicks=123,executable='/usr/bin/python3',bootId='test-boot')
    def test_foreign_live_owner_cannot_be_exempted(self):
        with patch.object(a,'identity',return_value=self.owner),patch.object(a,'alive',return_value=True),patch.object(a.subprocess,'check_output') as docker:
            self.assertRaises(ValueError,a.census,dict(self.owner,pid=self.owner['pid']+1));docker.assert_not_called()
    def test_existing_running_container_is_refused(self):
        with patch.object(a,'identity',return_value=self.owner),patch.object(a,'alive',return_value=True),patch.object(a.subprocess,'check_output',return_value=(b'a'*64+b'\n')):
            self.assertRaises(ValueError,a.census,self.owner)
    def test_incomplete_container_identity_is_refused(self):
        with patch.object(a,'identity',return_value=self.owner),patch.object(a,'alive',return_value=True),patch.object(a.subprocess,'check_output',return_value=b'short\n'):
            self.assertRaises(ValueError,a.census,self.owner)
    def test_changed_sampler_generation_is_refused(self):
        with patch.object(a,'identity',side_effect=[self.owner,dict(self.owner,startTicks=124)]),patch.object(a,'alive',return_value=True),patch.object(a.subprocess,'check_output',return_value=b''),patch.object(a,'Path',return_value=types.SimpleNamespace(iterdir=lambda:[])):
            self.assertRaises(ValueError,a.census,self.owner)
    def test_database_and_compiler_processes_are_counted(self):
        original=Path
        for executable in ('mariadbd','mysqld','postgres','clang++','rustc','java'):
            with self.subTest(executable=executable):
                child=dict(pid=42,startTicks=300,executable='/usr/bin/'+executable,bootId='test-boot')
                def identity(pid):return self.owner if pid==os.getpid() else child
                def fake_path(value):return types.SimpleNamespace(iterdir=lambda:[types.SimpleNamespace(name='42')]) if str(value)=='/proc' else original(value)
                with patch.object(a,'identity',side_effect=identity),patch.object(a,'alive',return_value=True),patch.object(a.subprocess,'check_output',return_value=b''),patch.object(a,'Path',side_effect=fake_path):
                    value=a.census(self.owner);self.assertEqual(value['activeHeavyPhases'],1);self.assertEqual(value['baselineExceptions'],[])
    def test_non_hosted_context_is_refused_before_git(self):
        with patch.dict(os.environ,{},clear=True),patch.object(a.subprocess,'check_output') as command:
            self.assertRaises(ValueError,a.assess,Path('unused'),[],self.owner);command.assert_not_called()

    def test_container_refusal_preserves_partial_census(self):
        witness={}
        with patch.object(a,'identity',return_value=self.owner),patch.object(a,'alive',return_value=True),patch.object(a.subprocess,'check_output',return_value=(b'a'*64+b'\n')):
            self.assertRaises(ValueError,a.census,self.owner,witness)
        self.assertEqual(witness['preexistingRunningContainers'],['a'*64]);self.assertEqual(witness['activeHeavyPhases'],0)

    def test_original_policy_refusal_preserves_preflight_before_call(self):
        raw=b'class Deferred(Exception):pass\ndef assess(sample,budget,active):\n raise Deferred("fixture refusal")\n'
        blob=hashlib.sha1(b'blob '+str(len(raw)).encode()+b'\0'+raw).hexdigest()
        sample=dict(checked_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),free_gib=14.5)
        witness={};saved=[]
        environment=dict(GITHUB_ACTIONS='true',RUNNER_ENVIRONMENT='github-hosted',RUNNER_OS='Linux',CI_DB_EPHEMERAL_VM='ubuntu-24.04')
        replies=[b'709c62ba7c1dc27588b1608ef1fc3fed5ec2c232\n55e52f37023f971a89ae32fb876a369fe379da15\n',blob.encode()+b'\n',raw]
        def census(owner,record):record.update(activeHeavyPhases=3,processes=[{'pid':42}]);return record
        with patch.dict(os.environ,environment,clear=True),patch.object(a,'identity',return_value=self.owner),patch.object(a,'alive',return_value=True), \
             patch.object(a.subprocess,'check_output',side_effect=replies),patch.object(a,'census',side_effect=census),patch.object(a,'measure',return_value=sample):
            with self.assertRaisesRegex(Exception,'fixture refusal'):
                a.assess(Path('fixture'),[],self.owner,witness,lambda value:saved.append(copy.deepcopy(value)))
        self.assertEqual(len(saved),1);self.assertEqual(saved[0]['assessment'],'MEASURED');self.assertFalse(saved[0]['policyInvoked'])
        self.assertEqual(saved[0]['measurement'],sample);self.assertEqual(saved[0]['census']['activeHeavyPhases'],3)
        self.assertEqual(witness['assessment'],'REFUSED');self.assertTrue(witness['policyInvoked']);self.assertEqual(witness['errorType'],'Deferred')

class PlatformRoleGuards(unittest.TestCase):
    def fixture(self,path='/usr/bin/networkd-dispatcher'):
        role,cgroup,digest=a.PLATFORM_SERVICES[path]
        return dict(process=dict(pid=824),parentPid=1,executable='/usr/bin/python3.12',executableSha256=a.PLATFORM_PYTHON_SHA,
            uids=[0]*4,gids=[0]*4,cgroups=[cgroup],unit=cgroup.rsplit('/',1)[1],unitMainPid=824,entrypoint=dict(path=path,sha256=digest))
    def test_both_exact_witnessed_service_roles_are_recognized(self):
        for path,(role,_,_) in a.PLATFORM_SERVICES.items():
            with self.subTest(path=path):self.assertEqual(a.classify_platform(self.fixture(path)),role)
    def test_changed_or_unknown_service_identity_is_not_exempted(self):
        for field,value in [('parentPid',860),('uids',[1001]*4),('gids',[1001]*4),('executable','/usr/bin/python3.13'),
            ('executableSha256','0'*64),('cgroups',['0::/user.slice/job']),('unit','other.service'),('unitMainPid',999),('process',{})]:
            with self.subTest(field=field):
                data=self.fixture();data[field]=value;self.assertIsNone(a.classify_platform(data))
        for field,value in [('path','/tmp/unknown.py'),('sha256','0'*64)]:
            with self.subTest(entry=field):
                data=self.fixture();data['entrypoint'][field]=value;self.assertIsNone(a.classify_platform(data))
    def test_agent_child_is_still_countable_unknown(self):
        data=self.fixture('/usr/sbin/waagent');data['parentPid']=860
        self.assertIsNone(a.classify_platform(data))
    def test_shared_or_nonhosted_context_cannot_read_platform_exceptions(self):
        with patch.dict(os.environ,{},clear=True),patch.object(a,'Path') as path:
            self.assertIsNone(a.platform_snapshot(dict(executable='/usr/bin/python3.12')));path.assert_not_called()

if __name__=='__main__':unittest.main()

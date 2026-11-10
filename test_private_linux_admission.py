"""Pure actual-owner and pre-existing-work guards; no Linux or Docker calls."""
from pathlib import Path
import os,subprocess,types,unittest
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

if __name__=='__main__':unittest.main()

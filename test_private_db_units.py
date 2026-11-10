"""Pure closed-case/custody tests. No Docker, JVM, SQL, systemd, or network."""
from pathlib import Path
import hashlib,json,os,subprocess,sys,tempfile,time,types,unittest
from unittest.mock import patch

root=Path(__file__).parent
protocol_path=root/'private_unit_ci.py'
p=types.ModuleType('private_unit_ci');p.__file__=str(protocol_path)
exec(compile(protocol_path.read_bytes(),str(protocol_path),'exec'),p.__dict__);sys.modules['private_unit_ci']=p
admission_path=root/'private_linux_admission.py';a=types.ModuleType('private_linux_admission');a.__file__=str(admission_path)
exec(compile(admission_path.read_bytes(),str(admission_path),'exec'),a.__dict__);sys.modules['private_linux_admission']=a
worker_path=root/'run_private_db_units.py';w=types.ModuleType('private_db_worker_under_test');w.__file__=str(worker_path)
exec(compile(worker_path.read_bytes(),str(worker_path),'exec'),w.__dict__)

class ReportGuards(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name);self.source=self.root/'source'
        (self.root/'result').mkdir();self.reports=self.source/'SpringAppBase/target/surefire-reports';self.reports.mkdir(parents=True)
        self.job=dict(source=str(self.source));self.cases=dict(suites=[dict(className='example.First',testCount=1,methods=['alpha']),dict(className='example.Second',testCount=1,methods=['beta'])])
        def write(path,raw):
            with path.open('xb') as output:output.write(raw)
        self.writer=patch.object(w,'write_new',write);self.writer.start()
        self.make('example.First','alpha');self.make('example.Second','beta')
    def tearDown(self):self.writer.stop();self.tmp.cleanup()
    def make(self,name,method,attrs='',child='',class_name=None,properties=''):
        raw='<testsuite name="'+name+'" tests="1" failures="0" errors="0" skipped="0" '+attrs+'>'+properties+'<testcase classname="'+(class_name or name)+'" name="'+method+'">'+child+'</testcase></testsuite>'
        (self.reports/('TEST-'+name+'.xml')).write_text(raw)
    def evaluate(self,java=None):return w.evaluate_reports(self.root,self.job,self.cases,time.time()-1,java)
    def test_exact_two_closed_cases_pass(self):self.assertEqual(sum(row['tests'] for row in self.evaluate()),2)
    def test_missing_suite_refuses(self):next(self.reports.iterdir()).unlink();self.assertRaises(ValueError,self.evaluate)
    def test_unexpected_suite_refuses(self):self.make('example.Third','gamma');self.assertRaises(ValueError,self.evaluate)
    def test_missing_method_refuses(self):self.make('example.First','changed');self.assertRaises(ValueError,self.evaluate)
    def test_wrong_case_class_refuses(self):self.make('example.First','alpha',class_name='example.Foreign');self.assertRaises(ValueError,self.evaluate)
    def test_hidden_failure_refuses_even_with_zero_aggregate(self):self.make('example.First','alpha',child='<failure message="hidden"/>');self.assertRaises(ValueError,self.evaluate)
    def test_hidden_error_refuses_even_with_zero_aggregate(self):self.make('example.First','alpha',child='<error message="hidden"/>');self.assertRaises(ValueError,self.evaluate)
    def test_hidden_skip_refuses_even_with_zero_aggregate(self):self.make('example.First','alpha',child='<skipped/>');self.assertRaises(ValueError,self.evaluate)
    def test_raw_xml_survives_refusal(self):
        self.make('example.First','wrong');self.assertRaises(ValueError,self.evaluate)
        self.assertEqual(len(list((self.root/'result/db-reports').glob('*.xml'))),2)
    def test_stale_xml_refuses(self):
        for path in self.reports.iterdir():os.utime(path,(time.time()-100,time.time()-100))
        self.assertRaises(ValueError,self.evaluate)
    def test_wrong_jvm_refuses(self):self.assertRaises(ValueError,self.evaluate,self.root/'jdk17')
    def test_exact_jdk17_properties_are_required(self):
        java=self.root/'jdk17';properties='<properties><property name="java.specification.version" value="17"/><property name="java.home" value="'+str(java)+'"/></properties>'
        self.make('example.First','alpha',properties=properties);self.make('example.Second','beta',properties=properties)
        self.assertEqual(len(self.evaluate(java)),2)
    def test_duplicate_method_refuses(self):
        self.cases['suites'][0]['testCount']=2;self.cases['suites'][0]['methods']=['alpha','beta']
        path=self.reports/'TEST-example.First.xml';path.write_text('<testsuite name="example.First" tests="2"><testcase classname="example.First" name="alpha"/><testcase classname="example.First" name="alpha"/></testsuite>')
        self.assertRaises(ValueError,self.evaluate)
    def test_entity_declaration_refuses_and_is_preserved(self):
        path=self.reports/'TEST-example.First.xml';path.write_text('<!DOCTYPE testsuite [<!ENTITY x "alpha">]><testsuite name="example.First" tests="1"><testcase classname="example.First" name="&x;"/></testsuite>')
        self.assertRaises(ValueError,self.evaluate);self.assertTrue((self.root/'result/db-reports'/path.name).exists())

class TestGroupGuards(unittest.TestCase):
    def test_safe_primary_group_is_kept(self):self.assertEqual(w.safe_test_gid(1001,121,65534),1001)
    def test_docker_primary_group_uses_nogroup(self):self.assertEqual(w.safe_test_gid(121,121,65534),65534)
    def test_root_fallback_is_refused(self):self.assertRaises(ValueError,w.safe_test_gid,121,121,0)
    def test_docker_fallback_is_refused(self):self.assertRaises(ValueError,w.safe_test_gid,121,121,121)
    def test_root_primary_group_uses_nogroup(self):self.assertEqual(w.safe_test_gid(0,121,65534),65534)

class CaseContractGuards(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.source=Path(self.tmp.name);self.path=self.source/w.CASE_PATH;self.path.parent.mkdir(parents=True)
        self.job=dict(source=str(self.source));self.rows={};suites=[]
        for name,method in [('First','alpha'),('Second','beta')]:
            path='SpringAppBase/src/test/java/example/'+name+'.java';self.rows[path]=dict(sha256='2'*64)
            suites.append(dict(className='example.'+name,sourcePath=path,canonicalSha256='2'*64,testCount=1,methods=[method]))
        self.cases=dict(schemaVersion=1,module='SpringAppBase',expectedClassCount=2,expectedTotalTests=2,
            execution=dict(forkCount=1,reuseForks=True,parallelClasses=False),suites=suites,
            fixtureHelper=dict(path='fixture/helper.py',sha256='1'*64),migrationPaths=['migrations/one.sql','migrations/two.sql'])
        for path in ('fixture/helper.py','migrations/one.sql','migrations/two.sql'):self.rows[path]=dict(sha256='1'*64)
    def tearDown(self):self.tmp.cleanup()
    def check(self):
        raw=json.dumps(self.cases).encode();self.path.write_bytes(raw);self.rows[w.CASE_PATH]=dict(sha256=hashlib.sha256(raw).hexdigest())
        return w.checked_case_spec(self.source,self.job,self.rows)
    def test_exact_sequential_contract_passes(self):self.assertEqual(self.check()['expectedTotalTests'],2)
    def test_reuse_false_is_refused(self):self.cases['execution']['reuseForks']=False;self.assertRaises(ValueError,self.check)
    def test_parallel_is_refused(self):self.cases['execution']['parallelClasses']=True;self.assertRaises(ValueError,self.check)
    def test_changed_source_is_refused(self):self.cases['suites'][0]['canonicalSha256']='3'*64;self.assertRaises(ValueError,self.check)
    def test_wrong_source_class_mapping_is_refused(self):self.cases['suites'][0]['className']='example.Other';self.assertRaises(ValueError,self.check)
    def test_duplicate_closed_method_is_refused(self):self.cases['suites'][0].update(testCount=2,methods=['alpha','alpha']);self.cases['expectedTotalTests']=3;self.assertRaises(ValueError,self.check)
    def test_total_mismatch_is_refused(self):self.cases['expectedTotalTests']=55;self.assertRaises(ValueError,self.check)

class LifecycleGuards(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name);(self.root/'result').mkdir()
        self.job=dict(nonce='a'*24,identity={'test':'identity'})
        self.patchers=[patch.object(w,'private',lambda path:path),patch.object(w,'json_new',lambda path,value:path.write_text(json.dumps(value))),
            patch.object(w,'digest',lambda path:'b'*64),patch.object(w.admission,'alive',return_value=False)]
        for item in self.patchers:item.start()
        (self.root/'slice-intent.json').write_text(json.dumps(dict(nonce=self.job['nonce'],jobSha256='b'*64,ownerProcess={'pid':123})))
    def tearDown(self):
        for item in reversed(self.patchers):item.stop()
        self.tmp.cleanup()
    def test_live_owner_prevents_empty_slice_recovery(self):
        with patch.object(w.admission,'alive',return_value=True),patch.object(w,'control') as control:
            self.assertRaises(ValueError,w.close_empty_intent,self.root,self.job);control.assert_not_called()
    def test_unexpected_service_prevents_mutation(self):
        with patch.object(w,'control',return_value=subprocess.CompletedProcess([],0,b'root-ci-'+b'a'*24+b'.service loaded active running\n',b'')) as control:
            self.assertRaises(ValueError,w.close_empty_intent,self.root,self.job)
            self.assertEqual(control.call_count,1)
    def test_no_resource_intent_closes_without_stop(self):
        with patch.object(w,'control',return_value=subprocess.CompletedProcess([],0,b'',b'')) as control:
            w.close_empty_intent(self.root,self.job)
            self.assertTrue((self.root/'result/prework-closure.json').exists())
            self.assertFalse(any('stop' in call.args[0] for call in control.call_args_list))
    def test_hash_file_gap_uses_empty_intent_path(self):
        (self.root/'run-spec.json').write_text('partial')
        with patch.object(w,'load_job',return_value=self.job),patch.object(w,'context',return_value=self.job['identity']),patch.object(w,'close_empty_intent') as close:
            w.recover(self.root);close.assert_called_once_with(self.root,self.job)
    def test_unreviewed_prepare_cannot_touch_context_or_files(self):
        with patch.object(w,'IMPLEMENTATION_QUALIFIED',False),patch.object(w,'context') as context:
            self.assertRaises(ValueError,w.prepare,self.root,self.root);context.assert_not_called()
    def kernel_recovery(self,populated='0',memory=str(4*1024**3)):
        slice_name='root-ci-'+self.job['nonce']+'.slice';calls=[]
        class KernelFile:
            def __init__(self,name):self.name=name
            def read_text(self):return {'cgroup.events':'populated '+populated+'\n','memory.max':memory,'pids.max':'512'}[self.name]
        class KernelGroup:
            def __truediv__(self,name):return KernelFile(name)
        class KernelRoot:
            def __truediv__(self,name):return KernelGroup()
        def control(args,**kwargs):
            calls.append(args)
            output=(slice_name+' loaded active active\n').encode() if args[:2]==['systemctl','list-units'] else b''
            return subprocess.CompletedProcess(args,0,output,b'')
        with patch.object(w,'control',side_effect=control),patch.object(w,'state',return_value=dict(Id=slice_name,Transient='yes',ControlGroup='/root.slice/root-ci.slice/'+slice_name)),patch.object(w,'Path',return_value=KernelRoot()):
            try:w.close_empty_intent(self.root,self.job)
            except Exception:
                self.assertFalse(any('stop' in call for call in calls));raise
        return calls
    def test_created_empty_bounded_slice_is_recovered(self):self.assertTrue(any('stop' in call for call in self.kernel_recovery()))
    def test_populated_prework_slice_is_not_stopped(self):self.assertRaises(ValueError,self.kernel_recovery,'1')
    def test_foreign_budget_prework_slice_is_not_stopped(self):self.assertRaises(ValueError,self.kernel_recovery,'0','123')

class FixtureCustodyGuards(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name);(self.root/'result').mkdir()
        source=self.root/'source';(source/'fixture').mkdir(parents=True);(source/'migrations').mkdir()
        workspace=self.root/'workspace';(workspace/'fixture').mkdir(parents=True)
        raw=b"OPERATOR='aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa'\nOWNER='eeeeeeee-eeee-4eee-eeee-eeeeeeeeeeee'\nTASK='TEST-disposable-fixture'\n"
        (source/'fixture/helper.py').write_bytes(raw);(source/'migrations/one.sql').write_bytes(b'-- test only')
        self.job=dict(source=str(source),workspace=str(workspace),testUid=1234,testGid=1234)
        self.cases=dict(fixtureHelper=dict(path='fixture/helper.py',sha256=hashlib.sha256(raw).hexdigest()),migrationPaths=['migrations/one.sql','migrations/two.sql'])
        self.spec=dict(nonce='a'*24,slice='root-ci-'+('a'*24)+'.slice',commit='b'*40,tree='c'*40)
        self.events=[];self.bad_cid=False;self.fail_journal=False;self.fail_helper=False
        def write(path,raw):
            if self.fail_journal and path==self.root/'container-create-db.json':raise OSError('simulated journal persistence failure')
            with path.open('xb') as stream:stream.write(raw)
            self.events.append(('persist',str(path.relative_to(self.root))))
        self.patchers=[patch.object(w,'write_new',side_effect=write),patch.object(w,'private',lambda path:path),
            patch.object(w,'owner_check'),patch.object(w,'wait_ready'),patch.object(w,'bounded',side_effect=self.bounded),
            patch.object(w,'control',side_effect=self.control),patch.object(w,'inspect_db',side_effect=self.inspect),
            patch.object(w.os,'chown',create=True)]
        for item in self.patchers:item.start()
    def tearDown(self):
        for item in reversed(self.patchers):item.stop()
        self.tmp.cleanup()
    def inspect(self,root,spec):return dict(State=dict(Running=False)) if (root/'container-create-db.json').exists() else None
    def control(self,args,**kwargs):
        if 'image' in args:return subprocess.CompletedProcess(args,0,json.dumps([dict(Id='sha256:'+'9'*64,RepoDigests=[w.IMAGE])]).encode(),b'')
        if 'create' in args:return subprocess.CompletedProcess(args,0,b'short' if self.bad_cid else b'd'*64,b'')
        if 'start' in args:
            self.assertTrue((self.root/'container-create-db.json').exists())
            self.assertTrue((self.root/'result/container-create-db.json').exists())
            self.events.append(('start',args[-1]));return subprocess.CompletedProcess(args,0,b'',b'')
        raise AssertionError('Unexpected control call')
    def bounded(self,args,*positional,**kwargs):
        if 'pull' in args:return 0
        self.assertEqual(args[0],sys.executable);self.events.append(('helper','called'))
        if self.fail_helper:return 1
        output=self.root/'fixture-output';output.mkdir()
        receipt=json.dumps(dict(containerId='d'*64,sourceCommit=self.spec['commit'],sourceTree=self.spec['tree'],engineVersion='10.11.fixture-only')).encode()
        (output/'receipt.json').write_bytes(receipt)
        (output/'fixture.env').write_text('\n'.join([
            'LEADYA_E1_FIXTURE_RECEIPT='+str(output/'receipt.json'),
            'LEADYA_E1_TEST_USER=TEST-only','LEADYA_E1_TEST_PASSWORD=fixture-only-not-a-service-secret',
            'LEADYA_E1_MIGRATION_FILE='+str(Path(self.job['source'])/self.cases['migrationPaths'][0])])+'\n')
        return 0
    def run_fixture(self):return w.fixture(self.root,self.spec,self.job,self.cases,{})
    def test_exact_cid_journal_is_durable_before_start(self):
        self.run_fixture()
        self.assertLess(self.events.index(('persist','container-create-db.json')),next(i for i,event in enumerate(self.events) if event[0]=='start'))
    def test_journal_failure_never_starts(self):
        self.fail_journal=True;self.assertRaises(OSError,self.run_fixture)
        self.assertFalse(any(event[0]=='start' for event in self.events))
    def test_invalid_create_cid_never_starts(self):
        self.bad_cid=True;self.assertRaises(ValueError,self.run_fixture)
        self.assertFalse(any(event[0]=='start' for event in self.events))
    def test_failed_helper_keeps_exact_create_and_runtime_evidence(self):
        self.fail_helper=True;self.assertRaises(ValueError,self.run_fixture)
        self.assertTrue((self.root/'result/container-create-db.json').exists())
        self.assertTrue((self.root/'result/fixture-custody-spec.json').exists())
        self.assertFalse((self.root/'result/fixture-receipt.json').exists())
    def test_full_original_receipt_and_journal_are_preserved(self):
        values,_=self.run_fixture()
        self.assertEqual((self.root/'fixture-output/receipt.json').read_bytes(),(self.root/'result/fixture-receipt.json').read_bytes())
        self.assertEqual((self.root/'container-create-db.json').read_bytes(),(self.root/'result/container-create-db.json').read_bytes())
        self.assertEqual(values['LEADYA_E1_FIXTURE_RECEIPT'],str(Path(self.job['workspace'])/'fixture/receipt.json'))

if __name__=='__main__':unittest.main()

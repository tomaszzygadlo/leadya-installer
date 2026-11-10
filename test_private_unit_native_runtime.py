"""Archive and XML guards only. Synthetic zip, no native executable invocation."""
from pathlib import Path
import tempfile
import unittest
import zipfile
from unittest.mock import patch
import private_unit_native_runtime as n
import run_private_units as r


class NativeRuntimeGuards(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='shipping-jre-guard-')
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name).resolve()

    def archive(self, names):
        archive=self.root/'runtime.zip'
        with zipfile.ZipFile(archive,'w') as output:
            for name in names:output.writestr(name,b'synthetic fixture: not executable')
        return archive

    def test_only_source_bound_top_level_is_extracted_to_new_directory(self):
        archive=self.archive([n.PREFIX+'bin/java.exe',n.PREFIX+'release'])
        java=n.extract(archive,self.root/'jre')
        self.assertEqual(b'synthetic fixture: not executable',java.read_bytes())
        with self.assertRaisesRegex(ValueError,'NATIVE_RUNTIME_DESTINATION_EXISTS'):
            n.extract(archive,self.root/'jre')

    def test_foreign_traversal_and_case_aliases_are_refused(self):
        for index,names in enumerate([['foreign/bin/java.exe'],[n.PREFIX+'../outside'],
                                     [n.PREFIX+'bin/java.exe',n.PREFIX+'bin/JAVA.exe']]):
            with self.subTest(names=names),self.assertRaises(ValueError):
                n.extract(self.archive(names),self.root/('jre'+str(index)))
        self.assertFalse((self.root/'outside').exists())

    def test_real_shipping_sized_module_is_streamed_within_the_bounded_archive(self):
        # The real pinned JRE lib/modules is82,880,553bytes; the former64MiB
        # per-member limit would refuse it before any application tests.
        archive=self.root/'shipping-sized.zip'
        with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_DEFLATED) as output:
            with output.open(n.PREFIX+'lib/modules','w') as stream:
                for _ in range(1280):stream.write(b'0'*65536)
        n.extract(archive,self.root/'large-jre')
        self.assertEqual(80*1024**2,(self.root/'large-jre/lib/modules').stat().st_size)

    def test_oversized_declared_member_is_refused_before_its_body_is_opened(self):
        archive=self.archive([n.PREFIX+'lib/modules'])
        original=zipfile.ZipFile
        def metadata(*args,**kwargs):
            incoming=original(*args,**kwargs)
            incoming.filelist[0].file_size=n.MAX_MEMBER+1
            return incoming
        with patch.object(n.zipfile,'ZipFile',side_effect=metadata), \
             self.assertRaisesRegex(ValueError,'NATIVE_RUNTIME_EXPANSION'):
            n.extract(archive,self.root/'too-large')
        self.assertFalse((self.root/'too-large/lib/modules').exists())

    def test_native_maven_option_and_actual_xml_jre_must_match(self):
        java=self.root/'jre/bin/java.exe'
        self.assertIn('-Djvm='+str(java),r.module_test_options('CheckingProgram',java))
        self.assertEqual([],r.module_test_options('SpringAppBase',java))
        reports=self.root/'reports'
        reports.mkdir()
        logback=self.root/'unit-logback.xml'
        from xml.sax.saxutils import escape
        for index,home in enumerate([str(self.root/'wrong-jdk'),str(java.parent.parent)]):
            (reports/'TEST-native.xml').write_text('<testsuite><properties>'
                '<property name="logback.configurationFile" value="'+escape(str(logback),{'"':'&quot;'})+'"/>'
                '<property name="java.version" value="17.0.9"/>'
                '<property name="leadya.test.smallHeap" value="true"/>'
                '<property name="java.home" value="'+escape(home,{'"':'&quot;'})+'"/>'
                '</properties><testcase classname="native.Case" name="fixture"/></testsuite>')
            if index==0:
                with self.assertRaisesRegex(ValueError,'NATIVE_REPORT_NOT_FROM_SHIPPING_JRE'):
                    r.preserved_evaluation(reports,self.root/'wrong',lambda *_: True,
                                           logging_configuration=logback,expected_java=java)
            else:
                self.assertTrue(r.preserved_evaluation(reports,self.root/'right',lambda *_: True,
                                logging_configuration=logback,expected_java=java))


if __name__=='__main__':unittest.main()

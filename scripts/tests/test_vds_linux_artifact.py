import importlib.util,json,os,re,struct,subprocess,sys,tempfile,textwrap,unittest,zipfile
from pathlib import Path
spec=importlib.util.spec_from_file_location('artifact',Path(__file__).parents[1]/'vds_linux_artifact.py')
a=importlib.util.module_from_spec(spec);spec.loader.exec_module(a)
class LinuxArtifactTests(unittest.TestCase):
    source='a'*40
    version='1.9.19-vds.2'
    def test_pinned_submodule_status_preserves_the_first_entry_prefix(self):
        line=' '+('b'*40)+' skip (1.9.19)'
        self.assertEqual(a.pinned_submodules(line+'\n'),[line])
        self.assertEqual(a.pinned_submodules(''),[])
        for prefix in ['-', '+', 'U', '']:
            with self.subTest(prefix=prefix):
                with self.assertRaisesRegex(RuntimeError,'Submodule checkout differs'):
                    a.pinned_submodules(prefix+('b'*40)+' skip\n')
    def fixture(self,base,arch):
        folder=base/arch;folder.mkdir();binary=bytearray(64);binary[:4]=b'\x7fELF';binary[5]=1;binary[18:20]=struct.pack('<H',a.ARCHES[arch]);binary=bytes(binary)
        launcher=b'#!/bin/bash\nexec "$@"\n'
        info={'artifacts':{'skip':{'version':self.version,'variants':[{'path':f'{arch}-swift-linux-musl/skip','supportedTriples':[f'{arch}-unknown-linux-gnu']}]}}}
        bundle=folder/'skip-linux.zip'
        with zipfile.ZipFile(bundle,'w') as z:
            z.writestr('skip.artifactbundle/info.json',json.dumps(info));z.writestr('skip.artifactbundle/bin/skip',launcher);z.writestr(f'skip.artifactbundle/{arch}-swift-linux-musl/skip',binary)
        record={'arch':arch,'source_sha':self.source,'version':self.version,'full_tests_passed':True,'static_binary_smoke_passed':True,'bundle_sha256':a.sha(bundle.read_bytes()),'binary_sha256':a.sha(binary),'launcher_sha256':a.sha(launcher),'lock_sha256':'lock','submodules':[' '+('b'*40)+' skip'],'workflow_sha':'workflow','run_id':'run','run_attempt':'1'}
        (folder/'receipt.json').write_text(json.dumps(record));return folder
    def inputs(self,base):
        for arch in a.ARCHES:self.fixture(base,arch)
    def test_combines_verified_native_bytes_and_executable_modes(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);self.inputs(p);out=p/'out';receipt=a.combine(p,out,self.source,self.version)
            self.assertEqual(receipt['bundle_sha256'],a.sha((out/'skip-linux.zip').read_bytes()))
            with zipfile.ZipFile(out/'skip-linux.zip') as z:
                self.assertEqual(len(json.loads(z.read('skip.artifactbundle/info.json'))['artifacts']['skip']['variants']),2)
                for arch in a.ARCHES:self.assertEqual(z.getinfo(f'skip.artifactbundle/{arch}-swift-linux-musl/skip').external_attr>>16 & 0o777,0o755)
    def test_refuses_one_arch_or_reused_output(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);self.fixture(p,'x86_64')
            with self.assertRaisesRegex(RuntimeError,'Both native'):a.combine(p,p/'out',self.source,self.version)
            (p/'out').mkdir()
            with self.assertRaisesRegex(RuntimeError,'already exists'):a.combine(p,p/'out',self.source,self.version)
    def test_refuses_source_receipt_drift_and_failed_checks(self):
        for field,value,error in [('source_sha','c'*40,'source/version'),('lock_sha256','changed','producer lock'),('submodules',[' '+('d'*40)+' skip'],'producer submodules'),('full_tests_passed',False,'Unverified'),('static_binary_smoke_passed',False,'Unverified')]:
            with self.subTest(field=field),tempfile.TemporaryDirectory() as d:
                p=Path(d);self.inputs(p);f=p/'aarch64/receipt.json';r=json.loads(f.read_text());r[field]=value;f.write_text(json.dumps(r))
                with self.assertRaisesRegex(RuntimeError,error):a.combine(p,p/'out',self.source,self.version)
    def test_refuses_corrupted_native_bytes(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);self.inputs(p);f=p/'aarch64/skip-linux.zip';f.write_bytes(f.read_bytes()+b'changed')
            with self.assertRaisesRegex(RuntimeError,'checksum mismatch'):a.combine(p,p/'out',self.source,self.version)
    def test_refuses_wrong_elf_architecture(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);f=self.fixture(p,'x86_64')/'skip-linux.zip'
            with self.assertRaisesRegex(RuntimeError,'Unexpected native variant'):a.check_bundle(f,'aarch64',self.version)
class LinuxWorkflowInputTests(unittest.TestCase):
    def validate(self,source,version,event='workflow_dispatch',push_sha='',push_ref=''):
        workflow=(Path(__file__).parents[2]/'.github/workflows/vds-linux-build.yml').read_text()
        script=workflow.split("          python3 - <<'PY'\n",1)[1].split('          PY',1)[0]
        with tempfile.TemporaryDirectory() as directory:
            output=Path(directory)/'output'
            result=subprocess.run([sys.executable,'-c',textwrap.dedent(script)],
                env=dict(os.environ,SOURCE_SHA=source,SOURCE_VERSION=version,EVENT_NAME=event,
                    PUSH_SOURCE_SHA=push_sha,PUSH_REF=push_ref,GITHUB_OUTPUT=str(output)),
                capture_output=True,text=True)
            return result,output.read_text() if output.exists() else ''
    def test_actual_dispatch_validator_accepts_exact_source_identity(self):
        result,output=self.validate('a'*40,'1.9.19-vds.2')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(output,'source_sha='+('a'*40)+'\nversion=1.9.19-vds.2\n')
    def test_actual_dispatch_validator_refuses_refs_truncation_and_output_injection(self):
        for source,version in [('main','1.9.19-vds.2'),('a'*39,'1.9.19-vds.2'),
                ('a'*40+'\nextra=bad','1.9.19-vds.2'),('a'*40,'1.9.19'),
                ('a'*40,'1.9.19-vds.2\nextra=bad'),('a'*40,'$(touch /tmp/never-run)')]:
            with self.subTest(source=source,version=version):
                result,output=self.validate(source,version)
                self.assertNotEqual(result.returncode,0)
                self.assertEqual(output,'')
    def test_push_uses_only_the_owned_qa_commit_and_fixed_candidate_version(self):
        result,output=self.validate('ignored-dispatch-source','ignored-dispatch-version',event='push',
            push_sha='b'*40,push_ref='refs/heads/qa/fiea26-skipstone-latest')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(output,'source_sha='+('b'*40)+'\nversion=1.9.19-vds.2\n')
    def test_push_ref_and_sha_cannot_fall_back_to_dispatch_inputs(self):
        for ref,source in [('refs/heads/main','b'*40),('refs/tags/1.9.19-vds.2','b'*40),
                ('refs/heads/qa/fiea26-skipstone-latest','branch-name')]:
            with self.subTest(ref=ref,source=source):
                result,output=self.validate('a'*40,'1.9.19-vds.2',event='push',push_sha=source,push_ref=ref)
                self.assertNotEqual(result.returncode,0)
                self.assertEqual(output,'')
    def test_unexpected_events_are_rejected_even_with_valid_dispatch_inputs(self):
        result,output=self.validate('a'*40,'1.9.19-vds.2',event='pull_request')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(output,'')
    def test_workflow_push_trigger_has_exactly_the_owned_qa_branch(self):
        workflow=(Path(__file__).parents[2]/'.github/workflows/vds-linux-build.yml').read_text()
        events=workflow.split('on:\n',1)[1].split('\npermissions:',1)[0]
        push=re.search(r'(?m)^  push:\n    branches:\n      - ([^\n]+)\n(?=  workflow_dispatch:)',events)
        self.assertIsNotNone(push)
        self.assertEqual(push.group(1),'qa/fiea26-skipstone-latest')
        self.assertNotIn('pull_request:',events)
        self.assertNotIn('tags:',events)
    def test_source_version_guard_never_stamps_a_mismatched_checkout(self):
        workflow=(Path(__file__).parents[2]/'.github/workflows/vds-linux-build.yml').read_text()
        script=workflow.split("          python3 - <<'PY'\n")[2].split('          PY',1)[0]
        for version,expected in [('1.9.19-vds.1',1),('1.9.19-vds.2',0)]:
            with self.subTest(version=version),tempfile.TemporaryDirectory() as directory:
                source=Path(directory)/'Sources/SkipSyntax/Version.swift'
                source.parent.mkdir(parents=True)
                contents='public let skipVersion = "'+version+'"\n'
                source.write_text(contents)
                result=subprocess.run([sys.executable,'-c',textwrap.dedent(script)],cwd=directory,
                    env=dict(os.environ,SKIP_VERSION='1.9.19-vds.2'),capture_output=True,text=True)
                self.assertEqual(result.returncode,expected,result.stderr)
                self.assertEqual(source.read_text(),contents)
if __name__=='__main__':unittest.main()

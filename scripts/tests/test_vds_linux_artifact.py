import importlib.util,json,os,re,struct,subprocess,sys,tempfile,textwrap,unittest,zipfile
from pathlib import Path
from unittest import mock
spec=importlib.util.spec_from_file_location('artifact',Path(__file__).parents[1]/'vds_linux_artifact.py')
a=importlib.util.module_from_spec(spec);spec.loader.exec_module(a)
class LinuxArtifactTests(unittest.TestCase):
    source='a'*40
    version='1.9.19-vds.2'
    license_bytes=(Path(__file__).parents[2]/'LICENSE.txt').read_bytes()
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
            z.writestr('skip.artifactbundle/LICENSE.txt',self.license_bytes);z.writestr('skip.artifactbundle/SOURCE.txt',a.source_record(self.source,self.version))
        record={'arch':arch,'source_sha':self.source,'version':self.version,'full_tests_passed':True,'static_binary_smoke_passed':True,'bundle_sha256':a.sha(bundle.read_bytes()),'binary_sha256':a.sha(binary),'launcher_sha256':a.sha(launcher),'license_sha256':a.sha(self.license_bytes),'source_record_sha256':a.sha(a.source_record(self.source,self.version)),'lock_sha256':'lock','submodules':[' '+('b'*40)+' skip'],'workflow_sha':'workflow','run_id':'run','run_attempt':'1'}
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
                for name in ['LICENSE.txt','SOURCE.txt']:self.assertEqual(z.getinfo('skip.artifactbundle/'+name).external_attr>>16 & 0o777,0o644)
                self.assertEqual(z.read('skip.artifactbundle/LICENSE.txt'),self.license_bytes)
                self.assertEqual(z.read('skip.artifactbundle/SOURCE.txt'),a.source_record(self.source,self.version))
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
            with self.assertRaisesRegex(RuntimeError,'Unexpected native variant'):a.check_bundle(f,'aarch64',self.version,self.source)

    def rewrite(self,path,change):
        with zipfile.ZipFile(path) as z:entries={n:z.read(n) for n in z.namelist()}
        change(entries)
        with zipfile.ZipFile(path,'w') as z:
            for n,b in entries.items():z.writestr(n,b)

    def test_refuses_missing_or_changed_license_and_source_even_with_recomputed_receipt(self):
        for name,content in [('LICENSE.txt',None),('LICENSE.txt',b'wrong license'),('SOURCE.txt',None),('SOURCE.txt',a.source_record('b'*40,self.version)),('SOURCE.txt',a.source_record(self.source,'1.9.19-vds.1'))]:
            with self.subTest(name=name,content=content),tempfile.TemporaryDirectory() as d:
                p=Path(d);self.inputs(p);f=p/'aarch64/skip-linux.zip'
                def change(entries):
                    key='skip.artifactbundle/'+name
                    if content is None:entries.pop(key)
                    else:entries[key]=content
                self.rewrite(f,change)
                r=p/'aarch64/receipt.json';record=json.loads(r.read_text());record['bundle_sha256']=a.sha(f.read_bytes())
                if content is not None:record['license_sha256' if name=='LICENSE.txt' else 'source_record_sha256']=a.sha(content)
                r.write_text(json.dumps(record))
                with self.assertRaisesRegex(RuntimeError,'artifact files|LICENSE|SOURCE'):a.combine(p,p/'out',self.source,self.version)

    def test_refuses_unknown_archive_member(self):
        with tempfile.TemporaryDirectory() as d:
            f=self.fixture(Path(d),'x86_64')/'skip-linux.zip'
            with zipfile.ZipFile(f,'a') as z:z.writestr('skip.artifactbundle/unreviewed.txt',b'not allowed')
            with self.assertRaisesRegex(RuntimeError,'unexpected artifact files'):a.check_bundle(f,'x86_64',self.version,self.source)

    def test_refuses_duplicate_or_symlink_metadata(self):
        for kind in ['duplicate','symlink']:
            with self.subTest(kind=kind),tempfile.TemporaryDirectory() as d:
                f=self.fixture(Path(d),'x86_64')/'skip-linux.zip'
                if kind=='duplicate':
                    with self.assertWarns(UserWarning):
                        with zipfile.ZipFile(f,'a') as z:z.writestr('skip.artifactbundle/SOURCE.txt',a.source_record(self.source,self.version))
                    error='Duplicate'
                else:
                    with zipfile.ZipFile(f) as z:entries={n:z.read(n) for n in z.namelist()}
                    with zipfile.ZipFile(f,'w') as z:
                        for n,b in entries.items():
                            info=zipfile.ZipInfo(n)
                            if n.endswith('SOURCE.txt'):info.external_attr=0o120777<<16
                            z.writestr(info,b)
                    error='symlinks'
                with self.assertRaisesRegex(RuntimeError,error):a.check_bundle(f,'x86_64',self.version,self.source)

    def test_macos_archive_requires_same_exact_metadata_and_unchanged_variant(self):
        with tempfile.TemporaryDirectory() as d:
            f=Path(d)/'skip-macos.zip';info={'artifacts':{'skip':{'version':self.version,'variants':[{'path':'macos/skip','supportedTriples':['x86_64-apple-macosx','arm64-apple-macosx']}]}}}
            with zipfile.ZipFile(f,'w') as z:
                for n,b in {'info.json':json.dumps(info).encode(),'macos/skip':b'fixture Mach-O, not executed','bin/skip':b'launcher','LICENSE.txt':self.license_bytes,'SOURCE.txt':a.source_record(self.source,self.version)}.items():z.writestr('skip.artifactbundle/'+n,b)
            a.check_archive(f,['macos'],self.version,self.source,'macos')
            self.rewrite(f,lambda e:e.update({'skip.artifactbundle/SOURCE.txt':b'wrong'}))
            with self.assertRaisesRegex(RuntimeError,'SOURCE'):a.check_archive(f,['macos'],self.version,self.source,'macos')

    def test_source_record_is_deterministic_and_refuses_noncommit_or_unversioned_source(self):
        expected=a.source_record(self.source,self.version)
        self.assertEqual(expected,a.source_record(self.source,self.version))
        for value in [self.source,self.version,a.SOURCE_REPOSITORY+'/tree/'+self.source,a.UPSTREAM_REPOSITORY,'AGPL-3.0-only']:self.assertIn(value.encode(),expected)
        self.assertTrue(expected.endswith(b'\n'));self.assertNotIn(b'\r',expected)
        with self.assertRaisesRegex(RuntimeError,'full source'):a.source_record('main',self.version)
        with self.assertRaisesRegex(RuntimeError,'VDS source version'):a.source_record(self.source,'1.9.19')

    def clean_fixture(self,root,status=''):
        version_text='public let skipVersion = "'+self.version+'"\n'
        path=root/'Sources/SkipSyntax/Version.swift';path.parent.mkdir(parents=True,exist_ok=True);path.write_text(version_text)
        (root/'LICENSE.txt').write_bytes(self.license_bytes)
        def command(cmd,cwd=None):
            if cmd==['git','rev-parse','--show-toplevel']:return str(root)+'\n'
            if cmd==['git','rev-parse','HEAD']:return self.source+'\n'
            if cmd[:3]==['git','status','--porcelain']:return status
            if cmd==['git','submodule','status','--recursive']:return ''
            if cmd==['git','show',self.source+':Sources/SkipSyntax/Version.swift']:return version_text
            if cmd==['git','show',self.source+':LICENSE.txt']:return self.license_bytes.decode()
            raise AssertionError(cmd)
        return command

    def test_stamp_uses_actual_clean_commit_and_exact_license_bytes(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);command=self.clean_fixture(root);out=root/'.build/skip.artifactbundle';out.mkdir(parents=True)
            with mock.patch.object(a,'run',side_effect=command):a.stamp(root,out,self.source,self.version)
            self.assertEqual((out/'LICENSE.txt').read_bytes(),self.license_bytes)
            self.assertEqual((out/'SOURCE.txt').read_bytes(),a.source_record(self.source,self.version))
            for name in ['LICENSE.txt','SOURCE.txt']:self.assertEqual((out/name).stat().st_mode & 0o777,0o644)

    def test_dirty_source_and_future_source_identity_refused_before_stamping(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);command=self.clean_fixture(root,status=' M scripts/vds_linux_artifact.py\n');out=root/'.build/skip.artifactbundle';out.mkdir(parents=True)
            with mock.patch.object(a,'run',side_effect=command):
                with self.assertRaisesRegex(RuntimeError,'clean and committed'):a.stamp(root,out,self.source,self.version)
            command=self.clean_fixture(root)
            with mock.patch.object(a,'run',side_effect=command):
                with self.assertRaisesRegex(RuntimeError,'moved during build'):a.stamp(root,out,'b'*40,self.version)
            self.assertFalse((out/'SOURCE.txt').exists())

    def test_mismatched_source_version_or_changed_license_refused(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);command=self.clean_fixture(root)
            with mock.patch.object(a,'run',side_effect=command):
                with self.assertRaisesRegex(RuntimeError,'Embedded source version'):a.clean_source(root,'1.9.19-vds.1')
            (root/'LICENSE.txt').write_bytes(b'not the source license')
            with self.assertRaisesRegex(RuntimeError,'unchanged AGPL'):a.metadata_files(root,self.source,self.version)
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

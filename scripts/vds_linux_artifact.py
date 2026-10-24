#!/usr/bin/env python3
"""Verify native VDS Linux bundles and combine only identical-source receipts."""
from pathlib import Path
import argparse, hashlib, json, os, re, stat, struct, subprocess, tempfile, zipfile

ARCHES = {'x86_64': 62, 'aarch64': 183}
LICENSE_SHA256 = 'a3bad629f67f442b23b5224419e49edafc32e6b9c876b89464f7aafe6091ccde'
SOURCE_REPOSITORY = 'https://github.com/vindhyadatascience/skipstone'
UPSTREAM_REPOSITORY = 'https://github.com/skiptools/skipstone'
def sha(data): return hashlib.sha256(data).hexdigest()
def load(path): return json.loads(Path(path).read_text())
def run(command, cwd=None):
    return subprocess.check_output(list(map(str, command)), cwd=cwd, text=True, stderr=subprocess.STDOUT)
def require(value, message):
    if not value: raise RuntimeError(message)
def pinned_submodules(status):
    # A leading space is git's proof that the worktree matches the recorded
    # gitlink. strip() would erase that proof from the first valid entry.
    lines = status.splitlines()
    require(all(line.startswith(' ') for line in lines), 'Submodule checkout differs from pinned source')
    return lines

def source_record(source, version):
    require(re.fullmatch(r'[0-9a-f]{40}', source), 'Expected full source SHA')
    require(re.fullmatch(r'\d+\.\d+\.\d+-vds\.\d+', version), 'Expected VDS source version')
    return (f'Skipstone {version}\nSource commit: {source}\n'
        f'Corresponding source: {SOURCE_REPOSITORY}/tree/{source}\n'
        f'Source repository: {SOURCE_REPOSITORY}.git\n'
        f'Upstream repository: {UPSTREAM_REPOSITORY}.git\n'
        'License: AGPL-3.0-only (LICENSE.txt)\n').encode('utf-8')

def metadata_files(root, source, version):
    license_bytes = (Path(root)/'LICENSE.txt').read_bytes()
    require(sha(license_bytes) == LICENSE_SHA256, 'Compiler LICENSE.txt differs from unchanged AGPL license')
    return license_bytes, source_record(source, version)

def clean_source(root, version):
    root = Path(root).resolve()
    require(Path(run(['git','rev-parse','--show-toplevel'], root).strip()).resolve() == root, 'Expected compiler repository root')
    source = run(['git','rev-parse','HEAD'], root).strip()
    source_record(source, version)
    require(not run(['git','status','--porcelain','--untracked-files=normal','--ignore-submodules=none'], root).strip(), 'Build source must be clean and committed')
    pinned_submodules(run(['git','submodule','status','--recursive'], root))
    text = (root/'Sources/SkipSyntax/Version.swift').read_text()
    require(re.findall(r'public let skipVersion = "([^"]+)"', text) == [version], 'Embedded source version mismatch')
    require(run(['git','show',source+':Sources/SkipSyntax/Version.swift'],root) == text, 'Version differs from committed source')
    license_bytes, _ = metadata_files(root, source, version)
    require(run(['git','show',source+':LICENSE.txt'],root).encode('utf-8') == license_bytes, 'License differs from committed source')
    return source

def stamp(root, output, source, version):
    require(clean_source(root, version) == source, 'Source checkout moved during build')
    output = Path(output)
    require(output.is_dir() and output.resolve().is_relative_to((Path(root)/'.build').resolve()), 'Expected existing derived artifactbundle directory')
    for name, data in zip(['LICENSE.txt','SOURCE.txt'], metadata_files(root, source, version)):
        target = output/name
        require(not target.is_symlink(), 'Metadata output must not be a symlink')
        target.write_bytes(data); target.chmod(0o644)

def check_archive(path, arches, version, source, platform='linux'):
    require(arches and len(arches) == len(set(arches)), 'Expected unique artifact architectures')
    if platform == 'linux':
        require(set(arches).issubset(ARCHES), 'Unknown Linux architecture')
        variants = [{'path': f'{arch}-swift-linux-musl/skip', 'supportedTriples': [f'{arch}-unknown-linux-gnu']} for arch in sorted(arches)]
    else:
        require(platform == 'macos' and arches == ['macos'], 'Unexpected macOS artifact')
        variants = [{'path': 'macos/skip', 'supportedTriples': ['x86_64-apple-macosx','arm64-apple-macosx']}]
    with zipfile.ZipFile(path) as archive:
        require(len(archive.namelist()) == len(set(archive.namelist())), 'Duplicate archive entries')
        info = json.loads(archive.read('skip.artifactbundle/info.json'))
        artifact = info['artifacts']['skip']
        require(artifact['version'] == version, 'Bundle/source version mismatch')
        require(sorted(artifact['variants'], key=lambda v:v['path']) == variants, 'Unexpected native variant')
        expected = {'skip.artifactbundle/'+p for p in ['info.json','bin/skip','LICENSE.txt','SOURCE.txt'] + [v['path'] for v in variants]}
        directories = {p[:i+1] for p in expected for i,c in enumerate(p) if c == '/'}
        require({p.filename for p in archive.infolist() if not p.is_dir()} == expected, 'Missing/unexpected artifact files (including license/source metadata)')
        require(all(not p.is_dir() or p.filename in directories for p in archive.infolist()), 'Unexpected artifact directory')
        require(all(not stat.S_ISLNK(p.external_attr >> 16) for p in archive.infolist()), 'Artifact entries must not be symlinks')
        license_bytes = archive.read('skip.artifactbundle/LICENSE.txt')
        record_bytes = archive.read('skip.artifactbundle/SOURCE.txt')
        require(sha(license_bytes) == LICENSE_SHA256, 'Artifact LICENSE.txt mismatch')
        require(record_bytes == source_record(source, version), 'Artifact SOURCE.txt identity mismatch')
        binaries = {}
        for arch, variant in zip(sorted(arches), variants):
            binary = archive.read('skip.artifactbundle/' + variant['path'])
            if platform == 'linux':
                require(len(binary) >= 20 and binary[:4] == b'\x7fELF' and binary[5] == 1, 'Expected little-endian ELF')
                require(struct.unpack('<H', binary[18:20])[0] == ARCHES[arch], 'Wrong ELF architecture')
            binaries[arch] = binary
        launcher = archive.read('skip.artifactbundle/bin/skip')
        return binaries, launcher, license_bytes, record_bytes

def check_bundle(path, arch, version, source):
    binaries, launcher, license_bytes, record_bytes = check_archive(path, [arch], version, source)
    return binaries[arch], launcher, license_bytes, record_bytes

def receipt(args):
    root = Path.cwd(); source = run(['git','rev-parse','HEAD']).strip()
    require(source == args.source, 'Source checkout moved')
    require(clean_source(root, args.version) == source, 'Build source changed')
    version_source = Path('Sources/SkipSyntax/Version.swift').read_text()
    matches = re.findall(r'public let skipVersion = "([^"]+)"', version_source)
    require(matches == [args.version], 'Embedded source version mismatch')
    bundle = Path('.build/artifactbundle-linux/skip-linux.zip')
    binary, launcher, license_bytes, record_bytes = check_bundle(bundle, args.arch, args.version, source)
    executable = Path(f'.build/artifactbundle-linux/skip.artifactbundle/{args.arch}-swift-linux-musl/skip').resolve()
    require(sha(executable.read_bytes()) == sha(binary), 'Packaged executable differs from tested executable')
    actual = json.loads(run([executable,'version','-j']))
    require(actual.get('version') == args.version, 'Executable version mismatch')
    args.output.mkdir(parents=True, exist_ok=False)
    # Exercise the actual static executable through the production CLI, not only
    # the dynamically linked host library used by the full Swift test suite.
    probe = '''public struct InitOnly { public let value: Int; public init(value: Int) { self.value = value } }
public func appended(_ value: String) -> String { var text = value; text.append("!"); return text }
public func erased(_ value: Int?) -> AnyHashable { return value }
public func same(_ lhs: Double?, _ rhs: Double?) -> Bool { return lhs == rhs }
public func grouped() { let groups: [Int: [Int]] = Dictionary<Int, [Int]>(grouping: [1, 2], by: { value in value % 2 }) }
'''
    with tempfile.TemporaryDirectory(prefix='vds-static-smoke-') as directory:
        base = Path(directory); project = base/'Sources/ArtifactProbe'; skip = project/'Skip'; skip.mkdir(parents=True)
        (base/'Package.swift').write_text('// swift-tools-version: 6.0\n')
        (project/'Probe.swift').write_text(probe); (skip/'skip.yml').write_text('skip:\n  mode: transpiled\n')
        module = base/'output/ArtifactProbe'
        log = run([executable,'skipstone','--project',project,'--skip-folder',skip,'--sourcehash',module/'.ArtifactProbe.sourcehash','--output-folder',module/'src/main','--module-root',module,'--module','ArtifactProbe:'+str(project)], cwd=base)
        (args.output/'static-smoke.log').write_text(log)
        kotlin_files = sorted(module.rglob('*.kt')); require(kotlin_files, 'Static executable emitted no Kotlin')
        kotlin = '\n'.join(path.read_text() for path in kotlin_files)
        required = ['text = `skip append old` + `skip append suffix`', 'anyHashableOptional(value, type = "Int")', 'swiftEquatableEquals(lhs, rhs)', 'dictionaryGrouping(grouping =']
        for needle in required: require(needle in kotlin, 'Static executable missed compiler repair: '+needle)
        require('val value: Int' in kotlin and 'var value: Int' not in kotlin, 'Init-only let lost immutable storage')
        (args.output/'static-smoke.swift').write_text(probe)
        (args.output/'static-smoke.kt').write_text(kotlin)
        smoke_sha = sha(kotlin.encode())
    (args.output/'skip-linux.zip').write_bytes(bundle.read_bytes())
    submodules = pinned_submodules(run(['git','submodule','status','--recursive']))
    result = {'schema':1,'source_sha':source,'version':args.version,'arch':args.arch,
        'bundle_sha256':sha(bundle.read_bytes()),'binary_sha256':sha(binary),'launcher_sha256':sha(launcher),
        'license_sha256':sha(license_bytes),'source_record_sha256':sha(record_bytes),
        'lock_sha256':sha(Path('Package.resolved').read_bytes()),'submodules':submodules,
        'swift_version':run(['swiftly','run','swift','--version']).strip(),
        'swiftly_version':run(['swiftly','--version']).strip(),
        'static_sdk_archive_sha256':sha(Path(os.environ['RUNNER_TEMP'],'swift-static-linux-sdk.tar.gz').read_bytes()),
        'run_id':os.environ['GITHUB_RUN_ID'],'run_attempt':os.environ['GITHUB_RUN_ATTEMPT'],
        'workflow_sha':os.environ['GITHUB_WORKFLOW_SHA'],'workflow_ref':os.environ['GITHUB_WORKFLOW_REF'],
        'full_test_selection':'SkipSyntaxTests|TestingFriendshipTests','full_tests_passed':True,
        'static_binary_smoke_passed':True,'static_smoke_kotlin_sha256':smoke_sha}
    (args.output/'receipt.json').write_text(json.dumps(result,indent=2,sort_keys=True)+'\n')
    (args.output/'skip-linux.zip.sha256').write_text(result['bundle_sha256']+'  skip-linux.zip\n')

def combine(inputs, output, source, version):
    require(not output.exists(), 'Combined output already exists')
    payloads = {}; receipts = []
    for path in sorted(inputs.glob('*/receipt.json')):
        data = load(path); arch = data['arch']
        require(arch in ARCHES and arch not in payloads, 'Missing/duplicate native architecture')
        require(data['source_sha'] == source and data['version'] == version, 'Inconsistent source/version')
        require(data['full_tests_passed'] is True and data['static_binary_smoke_passed'] is True, 'Unverified native artifact')
        bundle = path.with_name('skip-linux.zip')
        require(sha(bundle.read_bytes()) == data['bundle_sha256'], 'Native artifact checksum mismatch')
        binary, launcher, license_bytes, record_bytes = check_bundle(bundle,arch,version,source)
        require(sha(binary) == data['binary_sha256'] and sha(launcher) == data['launcher_sha256'], 'Native receipt identity mismatch')
        require(sha(license_bytes) == data['license_sha256'] and sha(record_bytes) == data['source_record_sha256'], 'Native license/source receipt mismatch')
        payloads[arch]=(binary,launcher,license_bytes,record_bytes); receipts.append(data)
    require(set(payloads)==set(ARCHES), 'Both native architecture receipts are required')
    for field in ['lock_sha256','submodules','workflow_sha','run_id','run_attempt']:
        require(receipts[0][field]==receipts[1][field], 'Inconsistent producer '+field)
    require(payloads['x86_64'][1] == payloads['aarch64'][1], 'Launchers differ')
    require(payloads['x86_64'][2:] == payloads['aarch64'][2:], 'License/source metadata differs')
    output.mkdir(parents=True)
    bundle = output/'skip-linux.zip'
    info={'schemaVersion':'1.0','artifacts':{'skip':{'type':'executable','version':version,'variants':[{'path':f'{arch}-swift-linux-musl/skip','supportedTriples':[f'{arch}-unknown-linux-gnu']} for arch in sorted(ARCHES)]}}}
    entries={'skip.artifactbundle/bin/skip':payloads['x86_64'][1], 'skip.artifactbundle/info.json':json.dumps(info,indent=2).encode()+b'\n',
        'skip.artifactbundle/LICENSE.txt':payloads['x86_64'][2], 'skip.artifactbundle/SOURCE.txt':payloads['x86_64'][3]}
    entries.update({f'skip.artifactbundle/{arch}-swift-linux-musl/skip':pair[0] for arch,pair in payloads.items()})
    with zipfile.ZipFile(bundle,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as archive:
        for name,data in sorted(entries.items()):
            item=zipfile.ZipInfo(name); item.compress_type=zipfile.ZIP_DEFLATED
            item.external_attr=(stat.S_IFREG | (0o644 if name.endswith(('info.json','LICENSE.txt','SOURCE.txt')) else 0o755)) << 16
            archive.writestr(item,data)
    check_archive(bundle, sorted(ARCHES), version, source)
    digest=sha(bundle.read_bytes())
    (output/'skip-linux.zip.sha256').write_text(digest+'  skip-linux.zip\n')
    combined={'schema':1,'source_sha':source,'version':version,'bundle_sha256':digest,
        'license_sha256':sha(payloads['x86_64'][2]),'source_record_sha256':sha(payloads['x86_64'][3]),'native_receipts':receipts}
    (output/'receipt.json').write_text(json.dumps(combined,indent=2,sort_keys=True)+'\n')
    return combined

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__); parser.add_argument('mode',choices=['receipt','combine','check-source','stamp','verify-macos','verify-linux'])
    parser.add_argument('--source'); parser.add_argument('--version',required=True)
    parser.add_argument('--arch',choices=ARCHES); parser.add_argument('--arches'); parser.add_argument('--bundle',type=Path); parser.add_argument('--inputs',type=Path); parser.add_argument('--output',type=Path)
    args=parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    if args.mode == 'check-source':
        print(clean_source(root,args.version)); raise SystemExit(0)
    require(args.source is not None, 'Source SHA required')
    require(re.fullmatch('[0-9a-f]{40}',args.source),'Expected full source SHA')
    require(re.fullmatch(r'\d+\.\d+\.\d+-vds\.\d+',args.version),'Expected VDS source version')
    if args.mode == 'stamp':
        require(args.output is not None,'Artifactbundle output required'); stamp(root,args.output,args.source,args.version)
    elif args.mode in ['verify-macos','verify-linux']:
        require(args.bundle is not None,'Artifact archive required')
        arches = ['macos'] if args.mode == 'verify-macos' else (args.arches or '').split(',')
        check_archive(args.bundle,arches,args.version,args.source,'macos' if args.mode == 'verify-macos' else 'linux')
    elif args.mode=='receipt':
        require(args.output is not None,'Receipt output required')
        require(args.arch is not None,'Native architecture required'); receipt(args)
    else:
        require(args.output is not None,'Combined output required')
        require(args.inputs is not None,'Native artifact inputs required'); combine(args.inputs,args.output,args.source,args.version)

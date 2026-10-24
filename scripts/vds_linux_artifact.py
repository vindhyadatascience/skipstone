#!/usr/bin/env python3
"""Verify native VDS Linux bundles and combine only identical-source receipts."""
from pathlib import Path
import argparse, hashlib, json, os, re, stat, struct, subprocess, tempfile, zipfile

ARCHES = {'x86_64': 62, 'aarch64': 183}
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
def check_bundle(path, arch, version):
    with zipfile.ZipFile(path) as archive:
        require(len(archive.namelist()) == len(set(archive.namelist())), 'Duplicate archive entries')
        info = json.loads(archive.read('skip.artifactbundle/info.json'))
        artifact = info['artifacts']['skip']
        require(artifact['version'] == version, 'Bundle/source version mismatch')
        binary_path = f'{arch}-swift-linux-musl/skip'
        require(artifact['variants'] == [{'path': binary_path, 'supportedTriples': [f'{arch}-unknown-linux-gnu']}], 'Unexpected native variant')
        binary = archive.read('skip.artifactbundle/' + binary_path)
        require(binary[:4] == b'\x7fELF' and binary[5] == 1, 'Expected little-endian ELF')
        require(struct.unpack('<H', binary[18:20])[0] == ARCHES[arch], 'Wrong ELF architecture')
        launcher = archive.read('skip.artifactbundle/bin/skip')
        return binary, launcher

def receipt(args):
    root = Path.cwd(); source = run(['git','rev-parse','HEAD']).strip()
    require(source == args.source, 'Source checkout moved')
    require(not run(['git','status','--porcelain','--untracked-files=no']).strip(), 'Tracked build source changed')
    version_source = Path('Sources/SkipSyntax/Version.swift').read_text()
    matches = re.findall(r'public let skipVersion = "([^"]+)"', version_source)
    require(matches == [args.version], 'Embedded source version mismatch')
    bundle = Path('.build/artifactbundle-linux/skip-linux.zip')
    binary, launcher = check_bundle(bundle, args.arch, args.version)
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
        binary, launcher = check_bundle(bundle,arch,version)
        require(sha(binary) == data['binary_sha256'] and sha(launcher) == data['launcher_sha256'], 'Native receipt identity mismatch')
        payloads[arch]=(binary,launcher); receipts.append(data)
    require(set(payloads)==set(ARCHES), 'Both native architecture receipts are required')
    for field in ['lock_sha256','submodules','workflow_sha','run_id','run_attempt']:
        require(receipts[0][field]==receipts[1][field], 'Inconsistent producer '+field)
    require(payloads['x86_64'][1] == payloads['aarch64'][1], 'Launchers differ')
    output.mkdir(parents=True)
    bundle = output/'skip-linux.zip'
    info={'schemaVersion':'1.0','artifacts':{'skip':{'type':'executable','version':version,'variants':[{'path':f'{arch}-swift-linux-musl/skip','supportedTriples':[f'{arch}-unknown-linux-gnu']} for arch in sorted(ARCHES)]}}}
    entries={'skip.artifactbundle/bin/skip':payloads['x86_64'][1], 'skip.artifactbundle/info.json':json.dumps(info,indent=2).encode()+b'\n'}
    entries.update({f'skip.artifactbundle/{arch}-swift-linux-musl/skip':pair[0] for arch,pair in payloads.items()})
    with zipfile.ZipFile(bundle,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as archive:
        for name,data in sorted(entries.items()):
            item=zipfile.ZipInfo(name); item.compress_type=zipfile.ZIP_DEFLATED
            item.external_attr=(stat.S_IFREG | (0o644 if name.endswith('info.json') else 0o755)) << 16
            archive.writestr(item,data)
    digest=sha(bundle.read_bytes())
    (output/'skip-linux.zip.sha256').write_text(digest+'  skip-linux.zip\n')
    combined={'schema':1,'source_sha':source,'version':version,'bundle_sha256':digest,'native_receipts':receipts}
    (output/'receipt.json').write_text(json.dumps(combined,indent=2,sort_keys=True)+'\n')
    return combined

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__); parser.add_argument('mode',choices=['receipt','combine'])
    parser.add_argument('--source',required=True); parser.add_argument('--version',required=True)
    parser.add_argument('--arch',choices=ARCHES); parser.add_argument('--inputs',type=Path); parser.add_argument('--output',required=True,type=Path)
    args=parser.parse_args()
    require(re.fullmatch('[0-9a-f]{40}',args.source),'Expected full source SHA')
    require(re.fullmatch(r'\d+\.\d+\.\d+-vds\.\d+',args.version),'Expected VDS source version')
    if args.mode=='receipt':
        require(args.arch is not None,'Native architecture required'); receipt(args)
    else:
        require(args.inputs is not None,'Native artifact inputs required'); combine(args.inputs,args.output,args.source,args.version)

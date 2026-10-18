# VDS build of skipstone

This is Vindhya Data Science's private fork of
[skiptools/skipstone](https://github.com/skiptools/skipstone), the Skip transpiler.
It is licensed under the GNU AGPL v3.0 (see `LICENSE.txt`), unchanged.

**Internal use only.** The fork and the binaries built from it are run on our own
development and CI machines and are not conveyed to anyone outside the organisation.
If a binary built from this fork is ever distributed outside the organisation
(a public release asset, a shared download, a contractor who is not working
exclusively for us), the AGPL requires us to offer the matching source under the
AGPL at the same time. Check before you publish anything built from here.

## Branches and tags

- `vds/<upstream>` (for example `vds/1.9.12`): our patches on top of the upstream
  release tag `<upstream>`.
- `<upstream>-vds.N`: a release of that branch. `-vds.0` is the unpatched upstream
  source plus this file and a committed `Package.resolved`.
- We rebase onto a newer upstream tag only when we deliberately upgrade Skip.
  We never open upstream PRs or issues.

## Toolchain (record of the build that made 1.9.12-vds.0)

| Item | Value |
| --- | --- |
| Host | macOS 27.0.1, Apple silicon |
| Xcode | 27.1 (27A9275), `/Applications/Xcode.app` |
| Swift | Apple Swift 6.4 (swiftlang-6.4.0.34.1) |
| zip | Info-ZIP 3.0 (Apple build) |

`Package.resolved` is committed (upstream ignores it), so the dependency versions
are fixed: swift-syntax 602.0.0, swift-argument-parser 1.8.2,
swift-tools-support-core 0.8.0, universal 5.3.0, ELFKit 0.2.1. Each of these was
released before upstream's 1.9.12 release (2026-09-29). The `skip` submodule is
pinned at skiptools/skip `c9cf31ac` (1.9.8), as upstream has it at this tag.

## Build the macOS binary

```bash
git clone https://github.com/vindhyadatascience/skipstone.git
cd skipstone
git checkout 1.9.12-vds.0            # or the vds tag you want
git submodule update --init          # SkipDriveExternal links into skip/
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift package resolve                # must not change Package.resolved
git diff --exit-code Package.resolved
SKIP_VERSION=1.9.12 bash scripts/build_macos_plugin.sh
shasum -a 256 .build/artifactbundle-macos/skip-macos.zip
```

The output is `.build/artifactbundle-macos/skip-macos.zip`: a universal
(arm64 + x86_64) SwiftPM artifact bundle with the same layout and `info.json` as
upstream's `skip-macos.zip`. `skip version` prints `Skip version 1.9.12`.

The zip is **not byte-identical** to upstream's and its SHA-256 changes from one
build to the next: the linked binary embeds build paths, and the zip stores file
timestamps. What we check instead is that the transpiled output is identical (next
section). Whoever publishes a binary records its SHA-256 in the consumer's
`binaryTarget` checksum, and every machine then downloads that one file.

Linux (`scripts/build_linux_plugin.sh`) needs swiftly plus the static Linux SDK and
has not been built for VDS yet.

## Check a build against stock Skip

In a scratch clone of the app, run FoxKit's `swift build` and
`swift test --filter XCSkipTests` once with stock Skip and once with this binary,
then compare the generated trees under `FoxKit/.build/plugins/outputs`. To point
the app at a local binary, use a copy of skiptools/skip at the matching tag whose
macOS `binaryTarget` is changed to `.binaryTarget(name: "skip", path: "<path to skip-macos.zip>")`,
and attach it with `swift package edit skip --path <that copy>`. Remove the
`.build/plugins/outputs` tree before each run.

1.9.12-vds.0 result (2026-10-18, RNABrowser `origin/feat/foxkit-lift` at d65e859e): both
runs built, and both passed `XCSkipTests` (623 JUnit suites, 5068 tests, 0 failures).
The generated trees (2833 files and symlinks, 1400 `.kt` files across FoxCore,
FoxCoreTests, FoxTestSupport, SkipLib, SkipFoundation and SkipUnit, Gradle `.build` and
`.gradle` state left out) were identical: the manifest SHA-256 was
`0d4d28918015688983300fff2b1d091236e1500d210eeb3314be659008d50ca2` for both. The binary
used was confirmed by hash in `.build/artifacts`. Self-built `skip-macos.zip` SHA-256:
`ed58dae8c32c85c6bb8d39d405cd202cb9343694bb1c6a771357a82a4d330862` (attached to the
private GitHub release `1.9.12-vds.0`).

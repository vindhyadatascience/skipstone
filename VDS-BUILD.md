# VDS build of skipstone

This is Vindhya Data Science's public fork of
[skiptools/skipstone](https://github.com/skiptools/skipstone), the Skip transpiler.
It is licensed under the GNU AGPL v3.0 (see `LICENSE.txt`), unchanged.

Binaries built from this fork are published as `skip-macos.zip` on this repository's
GitHub releases. The release's tag in this repository is the corresponding source (AGPL).

## Branches and tags

- `vds/<upstream>` (for example `vds/1.9.16`): our patches on top of the upstream
  release tag `<upstream>`.
- `<upstream>-vds.N`: a release of that branch. `-vds.0` is the unpatched upstream
  source plus this file and a committed `Package.resolved`. From `-vds.1`,
  `Sources/SkipSyntax/Version.swift` stamps `skipVersion` as `<upstream>-vds.N`, so
  `skip version` identifies a VDS build.
- We rebase onto a newer upstream tag only when we deliberately upgrade Skip.
  We never open upstream PRs or issues.

## Toolchain (record of the builds that made 1.9.12-vds.* and 1.9.16-vds.1)

| Item | Value |
| --- | --- |
| Host | macOS 27.0.1, Apple silicon |
| Xcode | 27.1 (27A9275), `/Applications/Xcode.app` |
| Swift | Apple Swift 6.4 (swiftlang-6.4.0.34.1) |
| zip | Info-ZIP 3.0 (Apple build) |

`Package.resolved` is committed (upstream ignores it), so the dependency versions
are fixed: swift-syntax 602.0.0, swift-argument-parser 1.8.2,
swift-tools-support-core 0.8.0, universal 5.3.0, ELFKit 0.2.1. Each was released
before upstream's 1.9.12 release (2026-09-29); the same pins serve 1.9.16 (2026-10-13).
The `skip` submodule is pinned as upstream has it at each tag: `c9cf31ac` (1.9.8) at 1.9.12, `a71b1480` (1.9.13+1) at 1.9.16.

## Build the macOS binary

```bash
git clone https://github.com/vindhyadatascience/skipstone.git
cd skipstone
git checkout 1.9.16-vds.1            # or the vds tag you want
git submodule update --init          # SkipDriveExternal links into skip/
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift package resolve                # must not change Package.resolved
git diff --exit-code Package.resolved
SKIP_VERSION=1.9.16-vds.1 bash scripts/build_macos_plugin.sh   # info.json version; match the tag
shasum -a 256 .build/artifactbundle-macos/skip-macos.zip
```

The output is `.build/artifactbundle-macos/skip-macos.zip`: a universal
(arm64 + x86_64) SwiftPM artifact bundle with the same layout and `info.json` as
upstream's `skip-macos.zip`. `skip version` prints `Skip version <tag>` (for example `1.9.16-vds.1`).

The zip is **not byte-identical** to upstream's and its SHA-256 changes from one
build to the next: the linked binary embeds build paths, and the zip stores file
timestamps. What we check instead is that the transpiled output is identical (next
section). Whoever publishes a binary records its SHA-256 in the consumer's
`binaryTarget` checksum, and every machine then downloads that one file.

The historical releases above contained only macOS artifacts. Linux releases use
`scripts/build_linux_plugin.sh`, a matching Swift toolchain, and the static Linux SDK.

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
GitHub release `1.9.12-vds.0`).

1.9.12-vds.1 result (2026-10-19, same app commit d65e859e, same toolchain): build and
`XCSkipTests` passed (623 suites, 5068 tests, 0 failures). Of the 2833 generated files and
symlinks, after mapping the scratch worktree path back to the stock run's path, exactly six
differ: the per-module `.<Module>.sourcehash` markers (FoxCore, FoxCoreTests, FoxTestSupport,
SkipFoundation, SkipLib, SkipUnit), whose only change is `"skipstone":"1.9.12-vds.1"` in place of
`"skipstone":"1.9.12"`. With that string swapped back each hashes to the stock value. All 1400
`.kt` files and every other file are identical. `skip-macos.zip` SHA-256:
`4ef539f28223dee2f1e783e114c8d536c9be748fabb3c92a7d94efe7425b099e` (public release `1.9.12-vds.1`).

1.9.16-vds.1 result (2026-10-19, RNABrowser `qa/skip-1916-upgrade` tree at 2b131ef7, which is
`qa/fiea-20-skipstone` merged with `feat/foxkit-lift`; same toolchain): FoxKit
`swift build --build-tests` ran once with the stock 1.9.16 `skip-macos.zip`
(`080c808d6c3b7d0fb64e0ae7c979867e7328bcbe445247cf92f741aed93e5bfe`) and once with this build,
in the same checkout. Of the 2873 generated files and symlinks (1420 `.kt` files), exactly six
differ: the six `.<Module>.sourcehash` markers, whose only change is
`"skipstone":"1.9.16-vds.1"` in place of `"skipstone":"1.9.16"`. With that string swapped back each
hashes to the stock value. The binary each run used was confirmed by hash in `.build/artifacts`
(stock `3b0a4caf…`, ours `8e969f80…`). `skip-macos.zip` SHA-256:
`f37161ffeb236e2fcf9f8fdce8ff15c0081d887d3bbf154cad252ed3de0bfcb5` (public release `1.9.16-vds.1`).


## 1.9.19 VDS port

The 1.9.19 port uses upstream source `dafe21778f0cc4c9d07cae29939a137d47981d01`.
It retains the accepted build recipe and dependency lock, and stamps the binary as
`1.9.19-vds.1`. The pending 1.9.17 rebase contains only earlier versions of those
build records; its history is included without replacing the newer source.
Upstream's Skip submodule remains pinned to `a71b1480`.

Use upstream's `scripts/build_macos_plugin.sh` (including its clean release build
and submodule checks). Verify the exact archive against stock 1.9.19 using the
hardened `skip-fork-sync` controller at `8e2676c1ad25b3e423574be14c078423b64d0269`.
Only the top-level compiler version in valid generated `.sourcehash` markers may
be normalized; Kotlin and other generated bytes must match exactly. Preserve the
built source SHA and archive checksum separately from prebuilt recheck output.
Before publication, exercise the same archive through a local wrapper binary target.
Publish those verified bytes, then update the wrapper revision, CLI, CI and tap
checksums together. Runtime/package verification evidence accompanies the release.


## 1.9.19-vds.2 compiler repairs

This release intentionally changes Kotlin output. It retains the 1.9.19 upstream
base and pinned Skip submodule, and adds tested Swift language and interoperability
repairs: explicit closure signatures, contextual literals and type erasure,
constructor metadata and access, nested generic captures, property-wrapper
memberwise initialization, and explicit testing metadata with Kotlin friendship.

Stored collection mutation and scalar-read accessors are advertised by separate
producer metadata capabilities. Old producers keep the copying path. The scalar
read path returns only `count` or `isEmpty`; ordinary copies, observers, escaped
values and unsupported receivers preserve their existing value semantics.
Immutable View body evaluation likewise requires the matching public SDK
capability and proven immutable inputs. Unknown or mutable inputs retain the
existing evaluation path.

Validate changed behavior with the native compiler tests, actual generated Kotlin
compiled and executed against the matching runtime, and compiled defect controls
that restore the exact source and rerun the positive. Do not normalize generated
Kotlin to make an old/new comparison pass. The historical identical-output checks
above describe their original unpatched producers only.

For macOS, use the build command above with `SKIP_VERSION=1.9.19-vds.2`. For Linux,
use Swift 6.4.0 with its matching static Linux SDK; build and exercise both
`aarch64` and `x86_64` variants. `.github/workflows/vds-linux-build.yml` records the
native build/test procedure without publishing a release. The packaging verifier
`scripts/vds_linux_artifact.py` rejects mismatched source, version, architecture,
submodules, locks and receipts before combining native artifacts. Cross-built
artifacts must be labeled as cross-built and executed with their recorded runner;
they must not be represented as a native test run on that architecture.

Publish source and exact archive checksums together, then update the SwiftPM
wrapper, CLI, CI and tap pins as one graph. Recheck that graph without local
package edits or a compiler override before application integration.

Every macOS and Linux artifact bundle contains the unchanged `LICENSE.txt`
(AGPL-3.0-only) and a deterministic `SOURCE.txt`: the embedded compiler version,
full source commit, public corresponding-source URL and upstream repository.
These files sit beside `info.json`; executable and launcher paths are unchanged.
Both builders require `SKIP_VERSION` to match a clean, committed checkout and
its pinned submodules. They capture that actual commit before building and check
it again when stamping the bundle. Commit the complete candidate first; never
substitute a future commit or stamp an uncommitted worktree as a release source.

The native CI receipt and combined Linux archive retain and verify both files.
Verification requires the exact license bytes and canonical source record for
the reviewed version/commit, rejects missing, duplicate, symlinked and unexpected
archive entries, and preserves metadata as ordinary readable files. Recomputed
archive checksums do not make changed license or source identities acceptable.
The local exported-source Linux procedure derives the same record from its
verified clean-commit snapshot receipt because that snapshot contains no `.git`.
Prepare new receipts and archive checksums after this packaging change; older
bundles without this metadata are deliberately rejected.

## 1.9.19-vds.3 repairs (RNABrowser-fiea.28, .30)

Gated against GeneFox's two JVM suites (FoxCoreTests 5451, LocusTests 2902) and a
whole-app differential transpilation against 1.9.16-vds.1; 1.9.19-vds.2 had not been.

- Memberwise initializers follow Swift 6.4 access: a private/fileprivate defaulted
  property adds an initializer that omits it; private wrapped defaulted properties
  are omitted entirely.
- An unmatched constructor of another module's concrete type yields that type
  (no invented signature); an explicitly specialized `T<X>(...)` keeps `T<X>`.
- Literal parameter context is formal-first again; nested `[[], []]` takes its
  builtin element expectation; `a...b` matches `ClosedRange<Bound>` parameters.
- Optional function typealiases keep `.typealiased(alias, .optional(fn))`.
- Private stored properties get private scoped-modify accessors; memberwise Kotlin
  constructors start from public again, as upstream.
- AnyHashable boxing is off (`KotlinStandardLibraryParity.boxesAnyHashable`): the
  runtime keeps `typealias AnyHashable = Hashable`, because runtime collections hold
  raw keys. Its tests skip while it is off.
- Swift Testing `Comment(...)` messages are passed as their text.

Tags are now SemVer prereleases (`1.9.19-vds.3` here, and `<version>-vds.N` on the
runtime forks): SwiftPM ignores `+build` metadata, so `+vds.N` tags were not distinct
versions to it. Consumers pin every fork by exact revision.

## 1.9.19-vds.4 (RNABrowser-fiea.28)

- Explicitly typed closures emitted as Kotlin lambdas (an `@MainActor`/async closure
  parameter cannot take an anonymous function) wrote their parameter types in Swift
  spelling (`l@{ _: Bool -> ...`); they now use the Kotlin spelling (`Boolean`, `Long`,
  `Array<...>`, ...). Found by GeneFox's Mac Pro gate (DestinationClaimTests).

## 1.9.19-vds.5 (RNABrowser-fiea.28)

- The async/await actor-match warning fires only for the awaited expression itself
  (the target's primary spine: left operand, member base, callee), not for argument
  constructors or right-hand operands nested in it. Those inherited `isInAwait` and
  warned spuriously while the awaited call matched and the Kotlin was unchanged.
- The "unable to match this API call ... View" warning now names the call's argument
  labels. Its usual cause is an argument list out of declaration order, which drops
  `.Compose(composectx)` and makes the View vanish on Android.
- Diagnostics only: generated Kotlin is unchanged from vds.4.

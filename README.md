# TellyForge native corresponding source

This repository hosts corresponding source and rebuild materials for open-source
native components distributed with official TellyForge applications. It contains
no proprietary application source, application binaries, customer data or private
playlists. Release archives preserve the upstream component licences.

## Windows native qualification

The manual `Windows native source qualification` workflow accepts an exact release
tag, including a GitVersion prerelease such as `v1.1.0-alpha.612`, its matching
Windows corresponding-source asset name and a separately reviewed SHA-256. The
asset filename must preserve the complete version, including the prerelease
suffix. Core versions below `1.0.0`, build metadata and tag/path aliases remain
rejected. It downloads only from this repository's public release assets. The ZIP
must match that hash and the explicit 63-file native source allowlist before any
archived build script is run. A new archive layout needs a reviewed allowlist
change; application Dart files, executables, DLLs and private inventories are
rejected. This filename boundary supplements the human source-content review and
checksum; it cannot determine whether text with an allowed filename is appropriate.

The workflow uses an ephemeral standard `windows-2022` GitHub-hosted runner with
read-only repository permission, no account secrets, no publisher key, no
self-hosted fallback and no Store access. Checkout credentials are not persisted.
The runner is free for a public repository under GitHub's current standard-runner
policy. Native work is confined to a new `C:\tfnq` directory; the job does not
disable Windows security or reuse any personal machine's native build trees.

It runs the retained build recipes unchanged: pinned ANGLE, authenticated LLVM,
NASM, Meson and libmpv. These recipes fetch exact public upstream source revisions
and hash-pinned archives/tools; copies of the covered source are also retained in
the ZIP. Both official runtime wrappers must match every reviewed output hash.
The hosted image's Visual Studio patch level can change. An output mismatch or
missing dependency fails the job; the workflow never updates expected hashes to
make a hosted build pass. The recorded image and Visual Studio versions help
diagnose toolchain drift. Standard runner disk space can also be a limit; the job
does not buy larger capacity or delete unrelated image software.

After the unchanged rebuild passes, the workflow adds `personal-modification`
to mpv's version string, incrementally recompiles with two workers, and confirms
that the DLL hash changed and the public libmpv API returns that exact marker.
The normal official release validators continue to reject this modified DLL.
The API probe uses null audio/video outputs, no user configuration and an explicit
library path. Each probe receives a fresh directory containing only its libmpv
output and the newly built `libEGL.dll`, `libGLESv2.dll` and `z.dll`. These files
are checked against the reviewed runtime manifest before and after copying;
only the deliberately modified libmpv uses its newly measured hash. There is no
fallback to installed DLLs or machine caches. The probe loads dependency-first
by absolute path, restricts dependent-library searching to that directory and
Windows System32, and checks every actual loaded native module path. The receipt
records all four file hashes and loaded paths for both probes. It does not play
media, invoke the Direct3D shader compiler, or render a TellyForge window.

Only `windows-native-qualification.json` is uploaded as a workflow artifact.
Native binaries, source trees, build directories and credentials are not uploaded.
The receipt explicitly keeps `fullAppRelinkQualified` and
`storeSubmissionQualified` false even after a native-only pass. The release still
needs the documented complete application test with a compatible modified library,
normal-user synthetic playback and unchanged first-party application files. That
proof cannot be replaced by this probe or by green CI.

## Local validation and publication boundary

Run `./scripts/Test-SourceArchive.ps1` with Windows PowerShell 5.1. These synthetic
fixtures exercise allowed content, hash mismatch, missing/extra files, traversal,
duplicate paths, links, empty entries and expansion limits without downloading or
compiling native software. `./scripts/Test-NativeProbeBundle.ps1` checks dependency
staging, corruption, missing/duplicate records, size mismatches and separation of
official dependencies from a deliberately modified libmpv without executing any
DLL. The orchestration script refuses accidental execution
outside this repository's GitHub-hosted Windows job.

Tag fixtures accept exact stable and prerelease identities while rejecting
malformed SemVer identifiers, case or version mismatches, path traversal and
filenames that discard the prerelease suffix. Tag support does not change the
reviewed archive hash or native-only content requirements.

The workflow must be reviewed before publication or dispatch. Its first native
run remains pending: a source archive for the exact merged application release
must first be exported, reviewed and published with its hash. No successful native
rebuild, relinking or Store acceptance is claimed merely by adding this workflow.

Original repository scripts and documentation are MIT-licensed; see `LICENSE`.
This grant does not replace upstream component licences inside release archives
or grant rights to TellyForge's proprietary application code.

References: [GitHub-hosted runner limits and public-repository pricing](https://docs.github.com/en/actions/reference/runners/github-hosted-runners),
[Windows 2022 hosted image inventory](https://github.com/actions/runner-images/blob/main/images/windows/Windows2022-Readme.md),
[LLVM 22.1.8 release](https://github.com/llvm/llvm-project/releases/tag/llvmorg-22.1.8),
[GitHub attestation verification](https://cli.github.com/manual/gh_attestation_verify),
and [Meson incremental compilation](https://mesonbuild.com/Commands.html#compile).

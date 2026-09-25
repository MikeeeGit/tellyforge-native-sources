# Windows native workflow preparation, 25 September 2026

This records the initial prepublication review. At that point the manual workflow
had not been published or dispatched; no native rebuild or application acceptance
result was asserted. Publication and dependency-probe follow-up are recorded below.

Local validation completed:

- Windows PowerShell 5.1: all 32 synthetic source-boundary fixtures passed.
- All four PowerShell scripts/modules parsed without errors.
- The embedded C# public-libmpv API probe compiled successfully; it did not load
  any native library during this check.
- The orchestration guard rejected a normal local process before creating the
  hosted build directory or downloading anything.
- The workflow YAML parsed, with the standard `windows-2022` label, read-only
  contents permission and four expected steps.
- `git diff --check` passed.

The 63-file allowlist is the reviewed Windows corresponding-source export plus
its native tool integrity helper and tests. The final archive must be exported
from the exact merged application release, reviewed, assigned its SHA-256 and
published before the manual workflow can be run. A checksum and path allowlist
are not substitutes for that source-content review.

The workflow retains official native output hashes and makes only one documented
version-string edit after the official rebuild passes. Its public artifact is a
JSON receipt; it does not upload compiled DLLs, toolchains, application source or
customer material. A native API pass leaves full-application relinking, visible
synthetic playback and Store acceptance explicitly unqualified.

## Publication and explicit native dependency loading

After an independent review and a second successful 32-check fixture run,
[PR 1](https://github.com/MikeeeGit/tellyforge-native-sources/pull/1) was merged at
19:14 UTC into `bedb8c57f0a6f94c7bdec9859b478928d3df611d`. The workflow became
active with zero runs. Dispatch remains pending until the final stable source
archive is reviewed and published.

Inspection of the reviewed runtime's PE imports and pinned mpv source found:

- libmpv's static imports are Windows system libraries. Its ANGLE loader uses
  `LoadLibraryW(L"LIBEGL.DLL")` dynamically.
- `libEGL.dll` imports `libGLESv2.dll`, which imports `z.dll`.
- A null-output version probe does not exercise the ANGLE rendering path.

The follow-up stages these four freshly built DLLs into a separate probe directory,
checks all official dependency hashes and sizes against the source archive's runtime
manifest, and checks the copied hashes again. Only the deliberately modified
libmpv uses its measured changed hash. The API probe loads dependency-first using
absolute paths with DLL-directory/System32-only search, then verifies and records
the actual loaded module paths. No installed-DLL or machine-cache fallback exists.

Follow-up validation:

- All 24 new synthetic native-bundle fixtures and the existing 32 source-boundary
  fixtures passed under Windows PowerShell 5.1.
- All six PowerShell scripts/modules parsed; the updated C# probe compiled.
- Two distinct temporary bundles of the existing hash-verified vendored runtime
  both loaded successfully under Windows PowerShell 5.1. All four actual native
  module paths matched the respective bundle, including the second run after the
  first bundle was released. No installed application files were used.
- The existing approved libmpv returned the version string `mpv ` with an empty
  suffix. The modified-library check compares this observed baseline plus the
  exact modification marker; source identity and official output hashes remain
  independent, mandatory checks.

This local API load proof uses existing reviewed outputs. It does not establish
a fresh hosted rebuild, a changed-library rebuild, rendered playback, Direct3D
shader compilation, complete application relinking or Store acceptance.

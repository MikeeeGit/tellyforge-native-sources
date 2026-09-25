# Windows native workflow preparation, 25 September 2026

The manual workflow is prepared for review. It has not been published or
dispatched, and no native rebuild or application acceptance result is asserted.

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

# Milestone 5 library qualification

The assigned Milestone 5 library work is complete. Physical-device testing and DICOMKit integration remain excluded by the owner. The [machine-readable checklist](release-gates.json) separately enforces assigned-task completion and stable-release readiness. No stable tag, release publication or downstream cutover is authorised.

## Source and implementation

The baseline is `3e00d934bef331cdbc7c4be752857dc9eca8f799`; the pinned JXLSwift predecessor remains `57e81cb9e2411d1efac435b429a306a031744c1e`. The seven common contract documents remain byte-identical at **0.10.0**. `VERSION` remains **2.1.0-dev.2**. Work uses the isolated `codex/milestone5-release-preparation` branch and preserves the unrelated decoder optimisation worktree.

Production source was frozen at `00f03ff288a7c8e0e2b82d2e71ec22622ede71ae`. Its Package.swift/Sources/VERSION inventory digest is `30a591977a593e9487429c5289b62a6ed30216d86d029124f31401c67164b753`. Later reporting and documentation changes do not alter that runtime. Each execution receipt retains its actual revision, source hashes, commands, toolchain and outcome; the final review reconciles those inputs with the delivered tree rather than relabelling old runs.

The necessary implementation change is a package-scoped Linux lock adapter. Standalone Swift 6.2.4 and 6.4.2 experiments reproduced TSan findings from Synchronization.Mutex and retained allocations from Foundation.Process without SwiftJXL. Linux now uses a private NSLock-protected owner for every build; Apple retains Synchronization.Mutex. The [local Sendable proof](../../../Sources/SwiftJXLCore/PackageMutex.swift) preserves synchronous borrows, sending ownership, noncopyable values, typed throws and unlock-on-error. Six [Linux-only regression declarations](../../../Tests/SwiftJXLCoreTests/LinuxQualificationSupportTests.swift) cover concurrent readers/writers, try-lock and throwing exits, owner lifetime, literal process arguments, child timeout/reaping and invalid process inputs. The [shell-free POSIX launcher](../../../Tests/SwiftJXLCoreTests/LinuxOracleProcess.swift) is test support only; the library still has no reference-codec runtime dependency.

The adapter adds a heap box and lock object on Linux. No unchanged allocation-count claim is made. Public API, default resource limits, fidelity, numerical conventions and compressed syntax remain unchanged. The compiled public consumer verifies independently known 12-bit samples, padding, caller allocation identity, destination sealing, exact animation timing and ownership across awaits. Unknown public allocation/peak-workspace counters remain `nil`.

## Qualification results

The following executions passed. Counts distinguish test declarations from parameter executions; they are not added together across platforms as a unique-test total. The final source-bound checklist remains authoritative.

| Execution | Outcome |
| --- | --- |
| Linux ARM64/x86_64, Swift 6.2.4/6.4.2, ASan with LSan and TSan | All eight cells pass; 374 declarations / 2,059 cases per cell, with no failures/skips. Leak detection remains enabled. Final hosted run: `41818641469`. |
| Native macOS 26.0, build 25A354, ARM64 | 368 declarations / 2,053 cases, 432 independent profiles, 45,826 reciprocal vectors and 98 CLI installation/foundation checks pass. The isolated VM's image/layer/tool/source digests are retained; it was shut down afterwards. |
| Native Intel macOS 26.6.1, Swift 6.3.3 | 368 declarations / 2,053 cases, all profiles/vectors and ten CLI groups / 1,059 checks pass. This is Intel execution evidence, not an exact macOS 26.0 or Swift 6.4 claim. |
| iOS 26.0 Simulator, Debug/ASan/TSan | Each configuration passes 362 declarations / 1,960 cases, zero failures/skips, independent numerical references and all three missing/short/corrupt vector controls. Actual products prove sanitizer instrumentation and runtime linkage. |
| tvOS 26.0, watchOS 26.0 and visionOS 26.0 Simulator, Release | Each full applicable suite passes 362 declarations / 1,960 cases, zero failures/skips, references and all three vector controls. |
| Complete macOS ARM64 CLI TSan matrix | All ten groups pass: 1,059 checks. Independent audit rechecks 818 explicit expected-exit records, the instrumented binary, current runtime hashes, all reports and the true scalar/high-precision oracle. |
| Release-validator regressions | 74 focused tests pass across nine commands; exact commands/counts are retained in the regression receipt. |

The Watch correctness tests originally failed six large-fixture cases under the platform's 32 MiB workspace / 64 MiB total default. Commit `24cbd10` adds Watch-only assertions that those defaults reject the known oversized operations, then runs all existing sample, ownership, padding and worker checks under an explicit general profile. Smaller cases still use Watch defaults. No declarations are skipped or removed. A focused 14-declaration / 91-case retry and the full Watch suite pass. Independent preprocessing of the six added conditional blocks proves the non-Watch source bytes exactly match `00f03ff`; other platform receipts retain their actual tested hashes.

The separate Watch supplemental probe passes 15 checks and 91 extended-JPEG cases, including the Watch default profile, an explicitly configured 32 MiB budget, low-memory rejection, cancellation after destination writes and invalidation. The VarDCT12 reference comparison has zero observed peak/RMS error. This is budget enforcement, not a measured 32 MiB RSS claim. Its initial expected JPEG pixel input was incorrectly copied from JBRD reconstruction metadata. The corrected host helper uses an independently decoded, dimension-checked 31×17 greyscale reference, records the djpeg/libjpeg binary hashes and load commands, repeats the output byte-for-byte and preserves the exact sample, allocation-count and caller-identity assertions. The simulator receives reference bytes only. The [simulator qualification index](Evidence/Qualification/apple-simulators/qualification-index.json) binds all six full configurations, supplemental checks and retained failures.

Earlier failed attempts remain archived. Linux's first run exposed the standard-library lock/process behaviour; a later reporter failed to decode interleaved UTF-8 despite complete xUnit output, so that cell was rerun. The final reporter separates and preserves byte streams, uses stdout alone for discovery and requires exact discovered/executed identities. Initial native discovery warnings were independently reconciled against unchanged raw receipts and complete XML. The first CLI matrix had a virtual-environment interpreter-path error and an incorrectly assumed scalar reference binary; the final ten-group run uses the preserved venv path and a verified scalar-only, high-precision libjxl build. Acceptance thresholds were not relaxed.

## Controlled Linux performance check

The [complete measurements](Evidence/Qualification/linux-lock-benchmark/comparison/report.json) compare pre-adapter `c917d6d` with the frozen candidate in native Linux ARM64, Swift 6.4.2 Release, a pinned container, four pinned CPU cores and no network. The probe uses synthetic 512×512 RGB16 images and public Modular/VarDCT encode/decode with one and four workers. Each case has three warm-ups and two counterbalanced ABBA/BAAB rounds of ten timed iterations. Sample checks run outside timing. Baseline and candidate compressed/decoded outputs match byte-for-byte.

One initial case, four-worker Modular encoding, crossed the repeated 5% latency investigation threshold (candidate/baseline ratios 1.0924 and 1.0674). The [longer 30-iteration repeat](Evidence/Qualification/linux-lock-benchmark/comparison-focused-v2/report.json) did not reproduce it (1.0105 and 0.9808). The initial result is retained. No case crossed the repeated RSS threshold. Whole-process RSS is not exact heap/workspace accounting; these measurements support only the tested synthetic workload and do not establish a general speed-up or identical memory allocation.

## Packaging, provenance and security

The clean [exact-version rehearsal](Evidence/Qualification/consumer-versioned/report.json) and [actual HTTPS revision consumer](Evidence/Qualification/consumer-https/report.json) pass Debug and Release against the frozen source. The former creates a disposable private tag only; the latter resolves the full published branch SHA. An eventual stable semantic version still needs a fresh consumer check during a separately authorised release task. The current [licence audit](Evidence/Qualification/provenance.json) covers 120 production files and 995 fixture/support files: 959 retained manifest/validation hashes and 36 pinned baseline Git blobs. Existing notices and fixture licences are unchanged; the [fixture inventory](fixture-inventory.json) links their provenance and hash evidence.

The [security receipt](Evidence/Qualification/security-policy.json) verifies private vulnerability reporting is enabled. [SECURITY.md](../../../SECURITY.md) specifies the actual reporting URL, current development support and the future latest-stable policy; the repository currently has no published stable release. No organisation permissions were changed.

## Current build-associated SBOMs

The [clean canonical build](Evidence/Qualification/sbom/build/report.json) uses frozen source `00f03ff` in a checkout named SwiftJXL with the actual GitHub origin/upstream. The [derived documents and exact edit record](Evidence/Qualification/sbom/qualified/report.json) pass both official JSON Schemas and full official-model SPDX SHACL validation, with inference disabled and warnings disallowed. A missing required creation timestamp is rejected by the same semantic validator. An [independent replay](Evidence/Qualification/sbom/m5-canonical-origin-sbom-independent-audit.json) verifies the 1,275 build-bound inputs, all edits and delivered hashes. Generator originals, failed attempts and their findings remain intact.

The derivation accepts only the observed graph and exact defects. It corrects the SPDX specification-version/property names, omits the malformed product-colon purl, removes the exact orphan malformed gitoid value and its dangling generates relationship, and removes the structurally duplicate CycloneDX component. It rejects unknown references or graph differences. It preserves the emitted root purl verbatim only after verifying origin, clean HEAD/upstream, emitted commit pedigree and the observed GitHub repository alias. Swift purl case sensitivity is not relaxed. New derivation identities, times and agents distinguish these files from original SwiftPM output.

The final derived SHA-256 values are `68ae656806d23c6125b4c76be77f2c1af357ef7459edbd3829ea2033b52e2979` (SPDX) and `a6ec29c575b7c8c47a8d0bfc00e943564aaf75d3372ef0bb547a74c235a5222c` (CycloneDX). These are qualified package graphs, not complete SDK, runtime or embedded-component inventories; the separate source/fixture notice audit remains necessary.

## Reproduction and limits

The raw reports contain exact commands, absolute original output locations, exit codes, tool versions and source/binary hashes. Archived receipts are unchanged; their original local paths are provenance, not portable download links. Per-archive manifests identify the retained files. Large build products, VM images and generated image payloads remain local, with their hashes retained where relevant.

```sh
python3 Scripts/check-release-gates.py --require-assigned-complete
# Exit 0: all 13 assigned gates pass; physical-device testing is excluded only from this assignment.
python3 Scripts/check-release-gates.py --require-ready
# Exit 2: physical-device qualification remains required before stable readiness.
```

The source inventory includes the executed fixtures, CLI fixture generator, oracle sources, test drivers, installer, manual and active release documentation. Changing those inputs invalidates the relevant passing bindings. `publicationAuthorised` remains false even when all assigned gates pass.

The report drivers retain raw stdout/stderr separately, preserve exit outcomes before decoding, compare discovered and executed test identities and reject sanitizer diagnostics, skips, missing or altered evidence. Focused validator regressions are recorded in [validator-regressions.json](Evidence/Qualification/validator-regressions.json). Actual simulator products are checked for sanitizer hooks and runtime linkage; an SDK build alone is never treated as runtime qualification.

Physical Apple hardware and DICOMKit integration remain unexecuted by owner instruction. Simulator and VM results do not qualify physical devices. No medical/regulatory suitability, production deployment or stable-release approval is inferred.

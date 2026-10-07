# SwiftJXL migration — execution record

Started 7 October 2026 at the owner's request to complete the SwiftJXL migration. The first change repairs the verification foundation; it does not claim codec migration or production cutover. JXLSwift remains the supported production dependency until successor qualification and a separately scoped consumer cutover.

## Source and contract

- Successor baseline: `raster-labs/SwiftJXL` at `24ff6b3d1d3bf52214eb2ce3cfa971345a29da5a`; clean checkout, branch `codex/swiftjxl-codec-migration`.
- Selected predecessor: `Raster-Lab/JXLSwift` at `57e81cb9e2411d1efac435b429a306a031744c1e`, the exact commit of `v1.5.0-rc.1`. This includes the contract storage integration absent from the older `760697a` documentation snapshot. The candidate is not a stable release; no predecessor tag or source is changed.
- Common contract distribution: 0.10.0. The seven files and `COMMON_CONTRACT_SHA256.txt` are unchanged. Several constituent documents retain earlier version headings; the suite policy records cumulative precedence.
- Active requirements: Swift tools 6.2 minimum, Swift 6 language mode, Swift 6.4 qualification, Apple deployment floors 26.0, executable `swiftjxl-cli`. Older repository-specific OS 27 and compiler-floor statements are superseded by the common contract.

## Prerequisite failures and corrections

The original [CI run](https://github.com/raster-labs/SwiftJXL/actions/runs/35800215617) had no executed steps because of an account billing lock. Attempt 2 on 7 October executed jobs: macOS, both Swift 6.4 Linux architectures and document hashes passed; both Swift 6.2 Linux jobs and the independent consumer failed. The billing lock is therefore no longer the observed blocker. Codec relocation still requires a fully passing successor workflow.

Swift 6.2 Linux traps in `Synchronization.Mutex.withLockIfAvailable` when a callback attempts to acquire its already-held mutex. `OwnedImageStorage` now admits one operation through an atomic flag before entering the mutex. Reentrant and competing access returns `storageUnavailable`; the flag is released after the mutex on success or throw. The array, borrow scope, allocation identity and sealing path are unchanged. The existing regression reproduced the CI crash; added checks cover reentrant abort/reservation and throwing-borrow recovery. No unchecked Sendable annotation or raw-pointer owner was introduced. The extra atomic operations have not yet received a controlled performance qualification.

The isolated consumer checkout is named `package`, so SwiftPM identifies its dependency as `package`, regardless of its declared product name. CI now uses that identity and runs the public sample/ownership consumer instead of merely importing the module. Local and example consumers declare the actual 6.2/26.0 minima.

Contract CLI-01 requires `swiftjxl-cli` to avoid case-only collisions with `SwiftJXL` on some Swift Build configurations. The product, executable help/version, installer, manual and tests now use that name. A clean baseline build did pass on this local Swift 6.4 host; that result is not evidence that the documented collision affects every compiler. CLI platform reporting is corrected to 26.0. macOS CI now executes the CLI/manual installation checks.

## Predecessor inventory and reconciliation

[The inventory](predecessor-inventory.json) records every tracked source/test path, SHA-256, byte size and textual line count at the selected predecessor commit. No implementation, test or fixture from that inventory is copied by this preflight.

| Product or material | Observed files / lines | Disposition |
| --- | --- | --- |
| JXLSwift core | 122 / 45,117 | Adapt algorithms behind the existing SwiftJXL common surface in milestones 2–4 |
| JXLSwiftContract | 7 / 1,059 | Fold useful codec seams into SwiftJXL; retain the successor's canonical descriptors, ownership and options, with no parallel public contract module |
| JXLTool | 13 / 2,983 | Adapt qualified verbs to `swiftjxl-cli`; defer the advanced commands listed in IMPLEMENTATION.md |
| JXLPerfC | 2 / 71 | Test/development-only optional primitives; audit equivalence and provenance before any import; not a core runtime dependency |
| JXLSwiftTests | 7 / 28,322 | Audit and retain useful regressions and independent-oracle assertions in the relevant milestone |
| Contract tests | 1 / 273 | Adapt caller-storage, byte-identity and lifetime regressions to the successor surface |

In-house predecessor material is MIT at the pinned commit; owner-authorised Apache-2.0 relocation follows POL-07 and records each actual destination path when it moves. `Tests/Fixtures/conformance/CREDITS.md` identifies two third-party JPEG XL conformance vectors as BSD-3-Clause. Preserve and independently verify their notices/upstream provenance before redistribution; a root licence is not sufficient. Their bytes are inventoried, not imported here.

The predecessor contract adapter is evidence, not a drop-in complete implementation: it needs review of meaningful precision, metadata preservation, deadline/workspace enforcement, error mapping and executor/cancellation policy against the successor contract. The public reconstruction path separately needs byte-exact JPEG validation and unsupported-profile rejection.

## Executed local checks

Host: Apple arm64, Xcode 27.0 / Apple Swift 6.4 `swiftlang-6.4.0.34.1`; this host does not establish native Linux, Intel, minimum-OS or physical-device qualification.

```sh
bash Scripts/validate.sh --checks debug,release,consumer,asan,tsan \
  --jobs 2 --disable-package-sandbox --output ../evidence/preflight-local
```

Exit 0. Clean/incremental debug and release builds, the public independent consumer and separate AddressSanitizer/ThreadSanitizer runs passed. Each configuration executed 32 test declarations / 33 argument cases, zero failures or skips. [Report with exact commands and tested-source hashes](Evidence/report.json); [debug](Evidence/debug-tests.xml), [release](Evidence/release-tests.xml), [ASan](Evidence/asan-tests.xml), [TSan](Evidence/tsan-tests.xml). The source report precedes later documentation/workflow-only edits; its hashes identify the actual tested implementation.

The CLI check `python3 Scripts/test-cli.py --binary .build/out/Products/Debug/swiftjxl-cli --output ../evidence/cli-preflight-final` exited 0 with 109 process checks, including staged install/update, manual lint/rendering, closed pipes and unavailable operations without I/O. [CLI report](Evidence/cli-report.json). An initial invocation used the wrong build-output path; a subsequent manual lint check exposed a line exceeding 80 columns, which was corrected before the final pass.

Selected predecessor baseline, executed from the unmodified pinned checkout:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" \
xcrun swift test --disable-sandbox --cache-path "$PWD/.build/cache" \
  --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" \
  --build-system swiftbuild --jobs 2 -c release \
  --filter 'JXLSwiftContractTests|SpecModular|PublicAPILosslessJPEGTests'
```

Exit 0: 35 XCTest cases and 14 Swift Testing declarations (18 argument cases), zero selected failures/skips. The empty XCTest wrapper for the Swift Testing target is not counted as coverage. [Exact baseline output](Evidence/predecessor-selected-tests.log). This is a selected baseline, not the complete predecessor regression suite. Independent tools on this host report `cjxl`/`djxl` 0.12.0; future oracle evidence must pin binaries and fixture generation. The resolved CLI-only ArgumentParser revision is `6a52f3251125d74daf04fcbd5e6f08a75d074382` (1.8.2); it is not added to SwiftJXL.

The subsequent complete release test invocation used the same command without the filter and with `--skip-build`. It exited 0: 717 XCTest cases (694 passed, 23 skipped, zero failures), plus 14 Swift Testing declarations / 18 argument cases. [Full baseline summary and every skip](Evidence/predecessor-full-summary.json). Skips include missing external fixtures, disabled diagnostics and unsupported parser patterns. A diagnostic-only VarDCT distance-10 sweep also reports a decode failure without failing its test. These are unresolved coverage/behaviour findings; the process exit is not full feature qualification.

A focused external public consumer demonstrates a real precision defect in the pinned predecessor contract adapter: an image declared with 12 meaningful bits produces an inspected codestream declaring 16 bits. The internal `encodeGrayscale16` supports an explicit precision, but `encodeGreyscale16` omits that argument and uses the 16-bit default. [Probe source](Evidence/precision-probe.swift) and [result](Evidence/precision-probe.json). The first probe raised its failed expectation at top level (exit 133); the final probe reports structured evidence and exits 1. Neither changes predecessor code. Migration must forward and validate declared precision and test it independently, rather than preserve this defect or infer precision from sample maxima.

## Contract adapter audit — 7 October continuation

The successor CI state was rechecked: run 35800215617 attempt 2 is completed with failure and no newer run exists. Publication of the prepared branch remains pending explicit user approval after automatic approval review rejected the push; there is no live CI job to wait on. The previous goal turn made progress through local fixes, baseline execution and precision evidence. Codec relocation remains unstarted under the CI precondition.

A new external consumer exercised six small, deterministic policy cases against the unmodified pinned predecessor. All six failed their contract expectations. [Source](Evidence/policy-probe.swift) and [results with source/binary hashes](Evidence/policy-probe.json).

| Requirement | Executed observation | Required successor acceptance |
| --- | --- | --- |
| Encoding workspace ceiling (TEST-06) | Encoding succeeds with one byte of allowed workspace despite an Int32 plane | Reject before allocating workspace beyond the declared ceiling |
| Encoding aggregate admission (TEST-06) | Encoding an existing 16-byte image succeeds with a one-byte total budget | Account for retained samples, compressed bytes and workspace before starting |
| Required acceleration (API-07) | Encoder and decoder both succeed with unavailable acceleration required | Return `backendUnavailable`, without silent scalar fallback |
| Decoding workspace ceiling (TEST-06) | Decoding succeeds with one byte of allowed workspace | Preflight and enforce bounded algorithm workspace |
| Required metadata preservation (API-07) | An image with required `interpretation` metadata encodes and decodes without it | Preserve representable required metadata or reject before publication |

These findings concern `JXLSwiftContract.JXLContractCodec`, not a claim about every legacy API path. The successor must retain its existing operation preflight and extend it through real codec execution; importing the predecessor adapter wholesale would regress those policies. The probe does not allocate large images or exercise unbounded inputs. Its first compile needed an explicit main-actor annotation for its serial results collector. The corrected source compiled and linked, but debug-symbol generation was denied by the local environment. Running that linked executable separately returned the six structured failures and exit 1; this is behavioural evidence, not a passing build gate.

## Outstanding completion gates

1. Pass the complete successor CI workflow on the corrected foundation, then migrate and independently verify the scalar codec with path-level provenance.
2. Complete common API integration and direct caller-storage encode/decode, with precision, stride, lifecycle, resource, cancellation and measured copy/allocation evidence. No full final-frame adapter copy.
3. Qualify all required retained modes, colour/alpha/ICC, frames and native JPEG reconstruction; explicitly account for deferred features. Implement and test the supported CLI verbs.
4. Execute required parser mutation/fuzz campaigns, regressions, independent interoperability in both directions, sanitizers, controlled release performance and platform gates. Existing synthetic tests are not codec evidence.
5. Verify clean versioned consumption, SBOM/provenance, examples, migration documentation and release readiness. No stable tag or production cutover follows from this preflight.

The programme history sequences SwiftJLS and SwiftJLI before SwiftJXL; their completed migration evidence is not established by this repository's checks. Other repository releases, downstream application edits and predecessor archival remain separate tasks.

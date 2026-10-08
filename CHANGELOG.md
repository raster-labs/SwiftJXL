# Change log

## Unreleased — internal caller-storage integration, 2026-10-08

- Decode the restricted scalar profile directly into caller storage, preserving offsets, strides, byte order, padding and allocation identity.
- Encode from a scoped immutable source borrow into the codec's Int32 working plane; verify exact codestream equivalence and concurrent reads.
- Qualify 45 test declarations / 59 argument cases in debug, release and both sanitizers, including 25 independent oracle fixtures. Public resource accounting, measured allocations and public codec integration remain outstanding.

## Unreleased — internal scalar migration, 2026-10-08

- Adapt the pinned predecessor’s native bitstream, container, entropy and Modular algorithms into a package-internal test target, with path-level hashes and retained notices.
- Verify exact lossless samples and precision with independent tools in both directions across 25 greyscale images; add malformed-input, cancellation and container regressions.
- Remove payload tracing and pointer-based worker dispatch; harden selected parser bounds and entropy completion. Full resource-policy, storage, performance and security qualification remains outstanding.
- Expand evidence discovery to include every local test target. Public codec capabilities, production consumers and release tags remain unchanged.

## Unreleased — migration preflight, 2026-10-07

- Reject reentrant storage access before attempting a non-recursive mutex, fixing the Swift 6.2 Linux trap while retaining exclusive mutable borrows and concurrent sealed readers.
- Apply contract 0.10.0's executable name `swiftjxl-cli` across the product, help, installer and manual. Report the actual Apple 26.0 deployment floor.
- Repair the isolated consumer's package identity and exercise its public storage/API behaviour in CI; run CLI installation checks on macOS.
- Align the example and generated consumer with the Swift 6.2 manifest minimum and record pinned predecessor, baseline failures and remaining migration gates in `Documentation/Engineering/Migration/README.md`.
- No codec source, production consumer dependency or stable release changes in this preflight.

## 2.1.0-dev.1 — Swift 6.4 upgrade, 2026-09-19 (unreleased)

- Require Swift tools/compiler 6.4, retaining Swift 6 language mode and OS 26 deployment floors.
- Advance the coordinated common contract to 0.3.0 and the earlier unreleased 2.0.0 version target to 2.1.0.
- Adopt checked native-order span access for UInt16 samples with explicit endian conversion; preserve public API and owning-storage semantics.
- Add the supplied upgrade references, F01–F13 feature register, headless Swift Build validation and exact evidence. No codec capability, stable release or tag is added.

## Unreleased — application migration documentation, 2026-09-18

- Added [MIGRATION.md](MIGRATION.md) for humans and coding agents preparing JXLSwift applications: pinned API/product mappings, dependency and platform changes, a standalone preparation example, precision/ownership policies and rollout/rollback gates.
- Linked the guide from README, agent, contributor, implementation and transcoding entry points. Clarified Milestone 1 availability and separated future pixel-lossless encoding from original-JPEG-byte reconstruction. No codec implementation or release is added.

## Unreleased — Milestone 1 feasibility, 2026-09-18

- Final Milestone 1 review: prevent image publication when cancellation occurs inside provider sealing/validation; deterministic regressions and full checks pass.
- Added a standalone Swift 6.2-minimum package in Swift 6 language mode, local common API, checked descriptors, resource policies and owning storage with exclusive leases and immutable publication.
- Added native transcoder call shapes with empty capabilities and explicit unsupported errors. No codec algorithm, private codestream, real transcoder or CLI is implemented.
- Added 24 descriptor, ownership, concurrency, cancellation, resource and API tests plus an independent public consumer. Debug/release, AddressSanitizer and ThreadSanitizer checks passed locally with Xcode 27's Swift 6.4 toolchain; see [exact commands and limitations](Documentation/MILESTONE1.md).
- Added the coordinated ownership-contract refinement and retained predecessor provenance without copying codec code. Swift 6.2, Linux, other Apple runtime targets and codec interoperability remain unexecuted qualification gates.

## Unreleased — documentation foundation, 2026-09-17

- Defined the standalone SwiftJXL successor and intended first stable version 2.0.0.
- Added the common API, memory, platform, CLI, testing and performance specifications, codec-specific agent instructions, source provenance and MIT licence.
- No source migration, implementation, package manifest, executable test, binary or release tag is included.
- No runtime behaviour, support matrix or performance result is claimed as verified.

## Documentation clarification — contract 0.1.1, 2026-09-17

- Aligned the suite policy, README and agent handoff with the staged implementation plan: contract feasibility first, codec migration second, shared-storage integration third.
- Added explicit Milestone 1 test evidence and labelled the later codec delivery sections to prevent accidental expansion of the first task.
- Mirrored all seven common documents and regenerated their SHA-256 manifest across the four repositories. API/memory behaviour, platform floors, intended library versions and release gates are unchanged.
- Verified documentation consistency and links; no codec code or executable tests were added or run.

## Native transcoding instructions — contract 0.2.0, 2026-09-18

- Added a common native format-pair API/CLI pattern and explicit in-memory ownership, fidelity and testing requirements for SwiftJ2K and SwiftJXL.
- Distinguished sample-exact J2K ↔ HTJ2K conversion from original-JPEG-byte restoration through JPEG XL. Neither operation requires an umbrella or sibling codec dependency.
- Recorded predecessor implementation/test findings in the relevant repositories; kept Milestone 1 scoped to feasibility. No native transcode placeholder is required in SwiftJLS/SwiftJLI.
- Updated all seven shared documents and their SHA-256 manifest. This is documentation only; no source migration, codec execution or performance claim.

The foundation document version is 0.2.0. It is separate from the intended library version.

## OS 27 and CLI foundation — 19 September 2026

Apple platform floors are 26.0; contract 0.5.0 reverses the 0.4.0 raise to 27.0, which no released SDK, toolchain or CI runner can currently validate. Development version 2.1.0-dev.2, common contract 0.5.0. The standalone `swiftjxl` provides help/version/capabilities, five diagnostic levels and a matching section 1 manual installed/updated with the binary. Codec commands remain unavailable. Byte-order sample access uses explicit fixed-width integer conversion and does not raise the runtime floor. See [qualification and limitations](Documentation/Engineering/OS27CLI/README.md). Historical evidence and supplied documents remain unchanged.
## Apple floor restored to 26.0 — contract 0.5.0, 20 September 2026

- Revert the 0.4.0 Apple deployment raise: macOS, iOS/iPadOS, tvOS, visionOS and watchOS return to **26.0**. Xcode 27 is a public preview with a 27.2 beta, no generally available SDK or stable CI runner exists for OS 27, and Swift 6.4.0 rejects a 27.0 deployment target outright because its supported range ends at 26.5.x. The raise could not be validated on any supported configuration.
- Return `swift-tools-version` to **6.2**, keeping Swift 6.4 as the qualified primary toolchain. A manifest floor constrains consumer resolution, and every current consumer resolves at 6.2.
- Replace the OS-27-gated `RawSpan.load(fromByteOffset:as:_:)` and `OutputRawSpan.append(_:as:_:)` byte-order overloads with explicit fixed-width integer conversion. This restores the rule contract 0.3.0 already specified and was the sole reason the floor moved. Public API, ownership and fidelity semantics are unchanged.
- Relax `Scripts/validate-swift64.py` from one pinned preview-Xcode build to accepting Swift 6.2 or 6.4, recording the exact toolchain as evidence rather than enforcing it as an admission gate.
- Retain the OS 27 records under `Documentation/Engineering/OS27CLI` as superseded history for their platform claims; their CLI content remains current.
- Verified on Swift 6.2.4 and Swift 6.4.0, debug and release. No codec capability, stable release or tag is added.

## Shared-storage contract refined from measurement — contract 0.6.0, 20 September 2026

- Advance the coordinated common contract to **0.6.0**. Seven memory rules are amended and one testing rule is added, each from something an exploratory spike measured or broke across all four predecessor codecs in both directions.
- **MEM-03** requires a multi-plane layout to state the distance between plane origins rather than infer it from height and `rowBytes`; with padded rows the two defensible readings differ by one row's padding per plane and shear the image instead of failing.
- **MEM-05** records that read-only storage is shared rather than leased and admits concurrent readers, an asymmetry with destinations the contract did not previously state.
- **MEM-06** requires caller-storage entry points to take the owner rather than a pointer, which an `async` codec cannot otherwise satisfy under MEM-08.
- **MEM-07** requires a safe owning constructor to exist and to be the documented default; unsafe adoption becomes the named exception.
- **MEM-10** requires algorithm workspace to be bounded by a stated per-codec figure, and records that removing the hand-off copy does not by itself reduce peak memory.
- **MEM-12** requires a codec whose native sample order differs from the shared layout to convert on the shared path rather than relax MEM-03.
- **MEM-13** records that allocator telemetry is invalid under a sanitizer, and that encode-side proofs compare codestreams byte for byte rather than comparing samples.
- **TEST-09** collects the resulting evidence bar, including mutation testing to demonstrate the checks are load-bearing.
- The predecessor reads caller samples at one function and writes them at one stage, and its `ImageFrame.data` is a packed `[UInt8]` with no row stride. A caller-destination decode must stop before the frame is assembled; routing through the ordinary decode would build a full image and copy it in, which is the shortcut MEM-10 names. Workspace is `Int32` channel planes at twice the final frame.
- Updated all seven shared documents and their SHA-256 manifest. Documentation only: no source migration, codec execution, platform change or release. Every figure cited comes from a developer machine and none has been reproduced in continuous integration.

## Decision D1: codec libraries stay where they are — contract 0.7.0, 20 September 2026

- Advance the coordinated common contract to **0.7.0**, recording decision **D1**: the shipping codec libraries are the existing repositories, and codec sources are not relocated. Nothing is deleted and no source moves.
- This repository's role is settled: it holds this codec's copy of the seven shared documents, the reference implementation of the shared image layer, and its share of the cross-codec conformance harness. POL-03 already stated that the contract is a specification rather than a runtime module, so the Milestone 1 types built here become that reference rather than discarded work.
- Rationale, from measurement: the Milestone 3 spikes showed all four codec interiors contract-capable through single-point changes, and the obstacle to `requireSharedStorage` is the public image type. That layer is additive work of the same size in either repository, so migration buys nothing it does not also buy, while additionally relocating about 219,000 lines of codec source and 184,000 lines of tests with no CI to catch what breaks.
- Rationale, from arithmetic: the contract repositories hold about 1,000 lines of source each, so abandoning migration discards almost nothing built; three in-house consumers already resolve the existing libraries by URL at pinned released versions and none references a contract repository.
- JXLSwift keeps its codec, its 47,898 lines of source and its 28,322 lines of tests. Its library target already has no external package dependency, and its references to J2KSwift are comments describing naming parity rather than a dependency, so POL-01 and POL-02 need no work here. DICOMKit consumes it by URL.
- Updated all seven shared documents and their SHA-256 manifest. Documentation only: no source migration, codec execution, platform change or release. Continuous integration remains blocked and has verified none of this.

## Decision D2: codec libraries relocate into the successor repositories — contract 0.8.0, 22 September 2026

- Decision D2 supersedes D1. JXLSwift's codec relocates here; the predecessor becomes a maintenance project and is archived once its consumers have moved. Restores the direction of the repository foundation v0.1.0, reaffirmed by the owner as the guidance for this migration.
- Licence changed from MIT to **Apache-2.0** for this repository, its in-house source and its documentation, amending POL-07 and settling the split that 0.7.0 referred to the owner. LICENSE replaced, NOTICE added, SPDX identifiers updated (27 files).
- Recorded as preconditions rather than resolved: continuous integration must execute before any source moves (Actions billing is still locked, verified 22 September 2026), the POL-05 product inventory must be signed off, and the Apple 26.0 deployment floor against current consumer floors is referred to the owner.
- All seven shared documents stay byte-identical; `SUITE_POLICY.md` and the SHA-256 manifest advance together. No platform, precision, ownership, fidelity or testing rule changes. This revision authorises no codec milestone and no release.

## Product dispositions under POL-05 — 22 September 2026

- Inventoried every JXLSwift product and recorded it as retained, adapted or deferred in [IMPLEMENTATION.md](IMPLEMENTATION.md), as contract 0.8.0 §3 requires before any subsystem is relocated. Four products become two: `SwiftJXL` and `swiftjxl`. `JXLSwiftContract` folds into the principal module and the `jxl` parity alias is dropped under CLI-01. Reversible JPEG recompression migrates inside the codec with its own POL-09 gate, and Linux is not claimed at 2.1.0 — the requirement stands, the unexecuted claim is simply not made (POL-08).
- Measured at predecessor `57e81cb` with `swift package dump-package`, with an import census across DICOMKit, CompressionFamily, VoxeliaValidation, DICOMAdapter, RasterOneImage, OneImageViewer-iOS and telerad-dicom-viewer. Every deferred product has zero in-house importers.
- Deferred is not deleted: a deferred product stays with the predecessor through its maintenance window. No shared contract document changes, no source moves, and no release or milestone is authorised by this record.


## Contract 0.9.0: deployment floor stays at 26.0, migration sequence recorded — 22 September 2026

- Decision D3 settles the question 0.8.0 referred to the owner: the Apple deployment floor stays at exactly 26.0 (PLAT-01/02 unchanged), and a consumer raises its own floor to 26.0 in the same change that re-points it from JXLSwift to this repository. Until then JXLSwift remains its supported route. DICOMKit consumes JXLSwift from 1.4.0 at macOS 15 / iOS 18 / tvOS 18 / visionOS 2.
- Corrected the continuous-integration record: J2KSwift now has a CI workflow (its pull request 488, merged 22 September 2026), and every successor carries the Milestone 1 contract workflow. All are written and unexecuted; Actions billing is still locked, verified the same day with `steps=0` on every job. No codec source moves before CI executes and passes here.
- Recorded the programme sequence: preconditions, then JLSwift → SwiftJLS as the pilot, then JLISwift, JXLSwift and J2KSwift, then consumers. This repository is third in sequence, after SwiftJLS and SwiftJLI.
- Defined what may proceed before CI runs: documentation, inventories, provenance audits, pin selection, the 0.8.0 item 5 reconciliation choice, and dependency extraction inside the predecessor. Adding predecessor codec or codec-test files here is the line that is not crossed.
- README now states the shared contract version it actually carries (it had read 0.7.0 since 0.8.0). All seven shared documents stay byte-identical; `SUITE_POLICY.md` and the SHA-256 manifest advance together. No platform, precision, ownership, fidelity or testing rule changes. This revision authorises no codec milestone and no release.

## Contract 0.10.0 mirrored: the executable naming rule — 23 September 2026

- Took contract revision **0.10.0** across from SwiftJLI, where it was prepared. CLI-01 renames the four successor executables to `swiftj2k-cli`, `swiftjls-cli`, `swiftjxl-cli` and `swiftjli-cli`, and adds the rule that no executable name may differ from a target or module name in the same package by case alone. `SUITE_POLICY.md`, `CLI_CONTRACT.md` and the SHA-256 manifest advance together; the other five shared documents were already byte-identical here and are untouched.
- The rule exists because Swift Build names each product's intermediates directory after the product. **This repository has the defect it describes.** `SwiftJXL` and `swiftjxl` differ only in case, so on a case-insensitive filesystem — the macOS default — the library target and the executable product resolve to one directory and overwrite each other's dependency files. Measured here on 23 September 2026 with Apple Swift 6.2.3: `swift build --build-system swiftbuild` fails with `unable to open dependencies file (.../swiftjxl.build/Objects-normal/arm64/main.d)`. All four repositories were checked and all four reproduce it identically.
- **The rename itself is not done here.** This revision carries the amended CLI-01 text only; the executable is still `swiftjxl`. Renaming it — the product name, `ManPages/swiftjxl.1`, the installer tool name, the CLI documentation and the tool name the executable reports in help and JSON — is separately assigned work in this repository. SwiftJLI has completed its own, and its change records what the rename touches.
- Documentation only: no source, platform, precision, ownership, fidelity or testing rule changes, and no codec milestone, release or tag is authorised. Continuous integration remains blocked by the Actions billing lock and has verified none of this.

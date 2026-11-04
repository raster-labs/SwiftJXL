# Milestone 5 — release preparation

This record covers the owner-assigned release-preparation task on 4 November 2026. It does not authorise a stable tag or consumer cutover. **Milestone 5 cannot receive full release sign-off while the outstanding qualification gates remain open.** The machine-readable checklist distinguishes completed preparation from stable-release readiness.

## Revisions and scope

- Target: `raster-labs/SwiftJXL`, branch `codex/milestone5-release-preparation`.
- Committed Milestone 4 baseline: `3e00d934bef331cdbc7c4be752857dc9eca8f799`.
- Selected predecessor: JXLSwift `57e81cb9e2411d1efac435b429a306a031744c1e` (`v1.5.0-rc.1`). The older `760697a` API inspection remains historical.
- Common contract: **0.10.0**, unchanged seven-file distribution and hash manifest. Development identifier remains **2.1.0-dev.2**.
- The working decoder optimisations on `codex/djxl-decoder-optimisation` were excluded. This task uses a separate worktree. The initial preparation changed no production code or package manifest. The subsequent platform qualification adds the Linux locking compatibility and test support described below; fixtures and existing licence texts remain unchanged.

The [gate checklist](release-gates.json) binds the actual runtime files and every passing preparation report. Historical correctness, independent-oracle, sanitizer, security and controlled-performance results remain attributed to their original runs in the [Milestone 4 record](../Migration/MILESTONE4_REMAINING.md). They are not counted as fresh executions here. The initial preparation did not change a hot path. The subsequent Linux locking change is being qualified with a controlled before/after latency and RSS comparison; no performance improvement is assumed.

## Preparation checks

| Check | Scope |
| --- | --- |
| Clean versioned consumer | A private shallow Git remote contains only the selected commit and a disposable `2.1.0-dev.2` tag. An independent tools-6.2 package resolves it with `.package(url: ..., exact:)`. Debug and Release build/run, lockfile revision/version, package graph, products, deployment floors, language mode and version/manual agreement are checked. No tag is added to the real repository. |
| Fresh HTTPS consumer | A second clean consumer resolves the published full candidate SHA from the actual GitHub URL using `revision:`. It checks the same public example in Debug and Release. This is distinct from fetching an eventual published semantic version. |
| Docs and examples | The [migration guide](../../../MIGRATION.md) contains the exact compiled [consumer](../../../Examples/ContractConsumer/Sources/ContractConsumer/Consumer.swift). Local document links and the canonical successor URL are checked. |
| Distribution provenance | The [notice index](../../../THIRD_PARTY_NOTICES.md) and [fixture inventory](fixture-inventory.json) cover 119 production source files and 995 fixture/support files, including retained MIT/BSD, CC0 and Adobe exceptions. The audit verifies existing manifest hashes and pinned Git blobs. |
| Evidence review | Reports retain commands, actual toolchain/host, exit outcomes, failed attempts, hashes and remaining gates. Negative tests reject incorrect pins, changed fixtures, missing evidence and false readiness. |

The example checks all six independently known 12-bit values in padded UInt16 source storage, an allocating decode, a direct decode into a different row stride, exact caller allocation identity, reported copy events, refusal of a second write and two independently owned animation frames with exact timing. It retains owners across awaits. Public allocation/peak-workspace measurements are `nil` and remain **unknown**, not zero. The existing allocation-site/mutation/sanitizer evidence in Milestone 3/4 supplies the broader no-handoff-copy and lifetime proof; this consumer is a public packaging regression check.

## Executed results

The [initial validation summary](Evidence/validation.json), [CI harness follow-up](Evidence/ci-followup.json) and [derived-SBOM qualification review](Evidence/sbom-qualified-review.json) bind the receipts and source groups; the full command logs are retained in the evidence archives.

| Executed check | Outcome |
| --- | --- |
| Local exact-version and actual HTTPS revision consumers | Debug and Release builds/runs pass on macOS arm64, Apple Swift 6.4.2 / Xcode 27.2, with exact source, lockfile and runner hashes in each report. |
| Release CLI foundation, staged install/update and manual rendering | Exit 0; 98 process checks. |
| Consumer/gate/provenance/SBOM validator regression tests | Exit 0; 8 + 14 + 12 + 4 focused tests. |
| Documentation and fixture/licence audits | Exit 0; matched compiled example and local links; 119 production source files and 995 fixture/support files. |
| Build-associated SBOM generation | Exit 0; schema validation was skipped by SwiftPM and independently performed afterwards. |
| Raw SBOM validation | Exit 1 with retained schema/semantic findings; the original generator output remains defective. |
| Explicitly derived SBOMs | Exit 0; both official JSON Schemas, reference/identifier checks and full official SPDX SHACL pass. Four derivation regression tests pass; the missing-timestamp SHACL sentinel correctly fails. |
| Release-readiness enforcement | Audit exit 0 with `preparationComplete: true`, `stableReleaseReady: false`; `--require-ready` exits 2. |

Initial failed consumer attempts are retained: inherited stale SDK lookup, file-URL lockfile classification and an incorrect expectation that an optional public allocation counter was zero. The final example preserves unknown counters. The first CLI test invocation used an incorrect assumed binary path; the corrected invocation used SwiftPM's reported output directory. No production change was needed for these harness mistakes. Independent audit also required baseline Git-blob verification in the provenance checker and explicit Python/checkout-ownership handling in the container workflow.

Hosted checks for the submitted PR are separate from these local receipts. The local host is macOS 27.0.1; these results do not qualify the macOS 26.0 runtime or physical Apple devices.

## Reproduce the checks

Use a committed candidate: uncommitted files never enter the consumer's private source snapshot. Each command records the excluded working changes and exact selected SHA. Choose new evidence directories; prior failures are retained.

```sh
python3 Scripts/TestSupport/test-release-consumer.py
python3 Scripts/test-release-gates.py
python3 Scripts/Tests/test_release_provenance.py
python3 Scripts/check-release-docs.py --output .build/release-docs.json
python3 Scripts/audit-release-provenance.py --output .build/release-provenance.json
python3 Scripts/validate-release-consumer.py --revision HEAD --build-system swiftbuild --jobs 2 --output .build/release-versioned
# After the selected SHA is published on a review branch:
python3 Scripts/validate-release-consumer.py --revision HEAD --repository-url https://github.com/raster-labs/SwiftJXL.git --build-system swiftbuild --jobs 2 --output .build/release-https
python3 Scripts/check-release-gates.py --output .build/release-gates.json
python3 Scripts/check-release-gates.py --require-ready
```

`--build-system native` is the explicit Swift 6.2 baseline selection; Swift 6.4 qualification requests `swiftbuild`. No fallback is implicit. On macOS the runner selects the macOS SDK from the chosen Xcode and records it. Linux execution uses the selected Swift container. The [preparation workflow](../../../.github/workflows/release-preparation.yml) runs the evidence checks and exact-version consumer on Swift 6.2/6.4, while the existing [codec workflow](../../../.github/workflows/contract.yml) retains its separate matrix. A green preparation workflow is not stable-release approval. Fixture auditing requires the pinned baseline Git object; CI checks out full history.

Normal gate audit exits 0 for a structurally valid checklist, even when blocked. `--require-ready` exits **2** while any required gate is open, and malformed/missing/stale evidence exits **1**. `publicationAuthorised` remains false. The eventual published tag must be consumed afresh during the separately authorised release task.

## Build SBOM disposition

`bash Scripts/validate.sh --checks sbom --jobs 2 --output .build/milestone5-sbom` generated fresh build-associated SPDX 3.0.1 and CycloneDX 1.7 documents with Apple Swift 6.4.2; generation exited 0. SwiftPM still reports its schema bundle unavailable. The originals were preserved and validated separately with `jsonschema==4.25.1`, offline versioned official schemas and recorded SHA-256 values:

```sh
python3 -m venv .build/release-tools
.build/release-tools/bin/python -m pip install 'jsonschema==4.25.1'
# Supply the official schema files and sources.json with URLs and SHA-256 values.
.build/release-tools/bin/python Scripts/validate-release-sbom.py --build-report .build/milestone5-sbom/report.json --schemas .build/release-schemas --output .build/release-sbom-validation
```

Validation exits **1**: SPDX has unsupported `externalUrl`/`software_internalVersion` properties and a CreationInfo specification version containing the compiler version; CycloneDX passes JSON Schema but repeats a `bom-ref`. The validator checks original hashes, disables schema-network retrieval and separately reports these semantic failures. Full SPDX SHACL validation remains unexecuted. Neither a JSON parse nor the distribution inventory closes this gate. Schema URLs are the official [SPDX 3.0.1 schema](https://spdx.org/schema/3.0.1/spdx-json-schema.json) and [CycloneDX 1.7 schema](https://cyclonedx.org/schema/bom-1.7.schema.json), including its referenced `spdx.schema.json`, `jsf-0.82.schema.json` and `cryptography-defs.schema.json`. Do not silently repair generated originals or advertise these documents as conformant.

## Explicitly derived SBOMs — validated follow-up

The [derived artefacts and exact edit record](Evidence/sbom-derived/report.json) close the package-graph conformance gate without changing the original failed emissions. [SPDX](Evidence/sbom-derived/derived/SwiftJXL-spdx-derived.json) and [CycloneDX](Evidence/sbom-derived/derived/SwiftJXL-cyclonedx-derived.json) are explicitly labelled derived documents, not unchanged SwiftPM output.

`Scripts/derive-release-sbom.py` recognises only this clean, source-pinned Swift 6.4.2 graph and its exact known defects. It preserves source-version values using the standard SPDX property, corrects the specification-version field, removes only demonstrably malformed optional package identifiers and records their original values. The [Swift package-URL definition](https://raw.githubusercontent.com/package-url/purl-spec/main/types/swift-definition.json) requires a source-host/organisation namespace; the generator used a local checkout name. No replacement identity is guessed. The structurally identical CycloneDX product duplicate is removed while the unique metadata component and all dependency references remain. The valid SwiftPM tool identifier is retained.

The new SPDX document has a distinct UUID, real derivation agent/time and raw-file hash provenance. CycloneDX keeps its serial number, increments BOM version 1 to 2 and records the derivation tool/time. Every edit is logged; unknown defects fail rather than being repaired speculatively. Both delivered files are reparsed and validated against the pinned official JSON Schemas and checked for identifier/reference integrity. Full official SPDX OWL/SHACL validation passes with 62 data triples and 3,737 model triples, all shapes, no allowed warnings, and no inference. Removing a required creation timestamp is rejected by the same model, demonstrating that the semantic check is active. The final output and original SHA-256 values are rechecked.

```sh
.build/release-tools/bin/python -m pip install 'pyshacl==0.30.1' 'rdflib==7.1.4' 'owlrl==7.1.4'
# Add the official SPDX 3.0.1 model/context and semantic-sources.json pins to the offline schema directory.
.build/release-tools/bin/python Scripts/derive-release-sbom.py --build-report .build/milestone5-sbom/report.json --schemas .build/release-schemas --output .build/release-sbom-derived
python3 Scripts/TestSupport/test-derived-release-sbom.py
```

[Model/context URLs and hashes](Evidence/sbom-derived/semantic-sources.json), validator versions, raw validation failures, the initial derivation harness failure, exact edits and the negative semantic result are retained. This is a validated **SwiftPM package graph**. Embedded third-party source uses the separate notice/provenance inventory; complete SDK/runtime or binary-system inventory is not inferred. The upstream generator defects remain documented and should be re-evaluated when the toolchain changes.

## Remaining release gates

The seven source-bound Milestone 4 gaps remain: Linux ASan/TSan; exact macOS 26.0 runtime; native Intel macOS runtime; representative physical Apple devices; current-source iOS Simulator Debug/ASan/TSan; the complete ten-group CLI TSan matrix; and full applicable tvOS/watchOS/visionOS simulator bundles. SDK builds and historical smoke tests are not runtime substitutes. Existing performance and mutation-campaign acceptance is retained within its measured scope.

The maintainer-established private reporting channel/supported-version policy in [SECURITY.md](../../../SECURITY.md) also remains open. No organisation settings, predecessor history or downstream application is changed. JXLSwift remains the production route. Completing this preparation task does not waive those requirements or allow a stable tag.

## Library qualification follow-up

The owner subsequently assigned all remaining Milestone 5 library work, excluding physical-device testing and DICOMKit integration. DICOMKit and other downstream application changes remain outside this repository task. The physical-device gate stays required for stable release and is excluded only from this assignment; the checklist reports assigned-task completion separately from release readiness.

Native Linux Swift 6.2.4 and 6.4.2 sanitizer runs exposed behaviour reproduced in standalone standard-library experiments: Synchronization lock operations produced TSan diagnostics, while Foundation.Process retained allocations. The candidate now uses a package-scoped, pthread-backed Foundation lock on every Linux build, with the original Synchronization.Mutex implementation retained on Apple platforms. It preserves sending ownership boundaries, typed throws and synchronous borrows. A written unchecked-Sendable proof and Linux-only concurrent access, try-lock, throw/unlock and noncopyable-owner tests accompany it. The Linux representation adds a heap box and lock object; unchanged allocation counts are not claimed.

Test reference tools use a bounded, shell-free POSIX launcher on Linux, with descriptor/string owners retained through spawn and child termination/reaping on timeout. The executable and library never use this test launcher. Six additional Linux-only declarations cover the compatibility boundaries, while existing ownership/cancellation and codec tests remain required. All affected source-bound qualification and preparation gates are reopened until the final candidate reports have been independently reviewed. Historical passing reports above retain their original revisions.

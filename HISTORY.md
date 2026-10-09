# History and provenance — SwiftJXL

## Native JPEG preparation — 9 October 2026

Brotli framing and stored-block encoding now have native bounded implementations, correcting predecessor metadata skip semantics. Independent libbrotli checks cover 29 streams; compressed-body decoding and full restoration remain open. See the evidence below.

The reconstruction-metadata checkpoint adapts JBRD fields, bounded serialisation and strict Exif/XMP/ICC assembly from the same predecessor pin. Sixteen independent bundles qualify the header boundary; native Brotli, coefficient-bridge integration and full original-JPEG restoration remain open. The coefficient commit passed macOS and the Linux matrix; its oracle job exposed a missing `cc` alias, corrected to the container's existing `clang` for the next run.

Adapted the segment-reader design from pinned predecessor `57e81cb9e2411d1efac435b429a306a031744c1e` under Apache-2.0. Added range retention and resource/cancellation limits, and new checked frame geometry. The nine synthetic JPEG fixtures and source hash records are retained for offline regression. See [native preparation evidence](Documentation/Engineering/Migration/NATIVE_JPEG.md). The next checkpoint adapts entropy and sequential/progressive coefficient decoding, with source hashes for every contributing predecessor file and 15 independent coefficient snapshots. This is internal preparation, not a completed reversible-transcoding implementation.

## NRRD CLI stage — 9 October 2026

Added new bounded attached/raw UInt16 NRRD parsing and serialisation around the existing public scalar codec. The official specification is pinned before implementation; no predecessor codec or third-party implementation was copied. See [profile and evidence](Documentation/Engineering/Migration/NRRD_PROFILE.md).

## CLI inspection and validation — 8 October 2026

Added bounded file/pipe inspection and full supported-frame validation through the public decoder, structured reports, cooperative deadlines/cancellation and atomic report publication. No codec subsystem was relocated in this stage. Encode/decode file adapters and reconstruction remain deferred. See [stage evidence](Documentation/Engineering/Migration/CLI_VALIDATION.md); platform gates must pass before merging.

## Public scalar integration — 8 October 2026

Connected public lossless greyscale encode, inspect and both decode call shapes on the feature branch, from predecessor pin `57e81cb9e2411d1efac435b429a306a031744c1e`. Added aggregate memory admission, bounded output assembly, encoder deadlines, required rendering-intent preservation, storage allocation instrumentation and public independent-oracle coverage. See the current resource audit and migration record for executed evidence and remaining release gates. This is not a release or production cutover.

## Documentation foundation — 17 September 2026

The owner chose four fresh repositories under Raster-Lab, with independent codecs, a common API and memory contract, MIT licensing and an optional adapter-based umbrella. The previous proposal for a new shared-foundation package, SwiftCompressionFamily 2.0.0, was superseded. The intended first stable release here is 2.0.0; no library version has been released or tagged by this foundation.

| Item | Recorded source |
| --- | --- |
| Predecessor | [Raster-Lab/JXLSwift](https://github.com/Raster-Lab/JXLSwift) |
| Default branch observed | main |
| Inspected source snapshot | [760697a54dd253da8e8466c3fd09ecf2c2d89aec](https://github.com/Raster-Lab/JXLSwift/commit/760697a54dd253da8e8466c3fd09ecf2c2d89aec) |
| Highest stable-shaped tag observed | [v1.4.0](https://github.com/Raster-Lab/JXLSwift/tree/v1.4.0) |
| Source-tree licence observed | MIT |
| Successor licence | Apache-2.0, for owner-authorised in-house material (contract 0.8.0) |
| Inspection date | 2026-09-17 |

The tag and the inspected branch snapshot are separate references; this record does not assert they resolve to the same commit. Before migrating a tagged baseline, resolve annotated tags to commits and record the exact chosen SHA. The pinned snapshot above was read for documentation preparation; it was not independently built or regression-tested in this task.

## Migration provenance requirements

The coding agent must record source repository, commit, original path and successor path for each migrated subsystem, and distinguish copied/adapted in-house material from new implementation. Record retained tests, fixture licences and explicit product/feature dispositions. Keep predecessor bug history accessible through links. Do not import old tags, rewrite predecessor history or imply all historical commits have been relicensed.

The owner states the implementation is in-house and has authorised Apache-2.0 relicensing (contract 0.8.0; the foundation recorded this as MIT). Preserve accurate original copyright years and ownership. Audit any third-party dependencies, tools or fixtures separately. The root licence is not authority to remove another party's notices.

The originals are intended to become maintenance projects while new development moves here. No predecessor settings, README, branch, release, licence or archive flag was changed during this documentation preparation. Maintenance announcements and downstream DICOMKit/Voxelia migration are separate work.

## Native transcoding source review — 18 September 2026

Re-inspected the same pinned predecessor snapshot for the owner-requested native transcoding instructions. [TRANSCODING.md](TRANSCODING.md) records concrete entry points, test assertions, known limitations and required successor corrections. Source presence/control flow were reviewed; no codec build, test or benchmark was executed. No predecessor files were changed.

## Swift 6.4 development upgrade — 19 September 2026

The owner assigned the successor upgrade before Milestone 2 and requested version increments. Starting from `423b8ae404ca5029a6a5fa1abe736d57dc8f0a96`, the candidate requires Swift tools 6.4 in Swift 6 language mode, advances shared contract 0.2.1 to 0.3.0 and advances the unreleased 2.0.0 target to 2.1.0 (`2.1.0-dev.1` development identifier). Platform floors, public API signatures, licensing and codec milestone scope are preserved. This is not a release/tag. The [upgrade record](Documentation/Engineering/Swift64/README.md) keeps current evidence separate from the earlier historical reports.

## OS 27 and CLI foundation — 19 September 2026

Apple platform floors are 26.0; contract 0.5.0 reverses the 0.4.0 raise to 27.0, which no released SDK, toolchain or CI runner can currently validate. Development version 2.1.0-dev.2, common contract 0.5.0. The standalone `swiftjxl` provides help/version/capabilities, five diagnostic levels and a matching section 1 manual installed/updated with the binary. Codec commands remain unavailable. Byte-order sample access uses explicit fixed-width integer conversion and does not raise the runtime floor. See [qualification and limitations](Documentation/Engineering/OS27CLI/README.md). Historical evidence and supplied documents remain unchanged.
## Apple floor restored to 26.0 — 20 September 2026

Contract 0.5.0 reverses the 0.4.0 raise of the Apple deployment floors to 27.0 and returns them to 26.0. Verification found that no generally available Xcode ships OS 27 SDKs, that no stable `macos-27` continuous-integration runner exists, and that Swift 6.4.0 rejects a 27.0 deployment target because its supported range ends at 26.5.x. Every OS 27 qualification claim was therefore unreproducible.

The raise was not an independent platform decision. Contract 0.4.0 adopted the OS-27-gated byte-order span overloads, and the floor moved so that they would compile. Contract 0.3.0 had already specified the correct treatment, explicit fixed-width integer endian conversion without raising the runtime floor, and that rule is restored. The compiler minimum returns to Swift 6.2 with Swift 6.4 retained as the qualified primary toolchain, because a manifest floor constrains consumer resolution and every current consumer resolves at 6.2.

Public signatures, ownership and fidelity semantics, milestone boundaries and Linux scope are unchanged. The OS 27 and Swift 6.4 records remain as history, marked superseded where they assert a platform baseline.

## Shared-storage rules refined from measurement — 20 September 2026

Contract 0.6.0 amends seven memory rules and adds one testing rule. Exploratory spikes ran the caller-storage question against all four predecessor codecs in both directions before any migration work, and every amendment comes from something those spikes measured or broke rather than from anticipated design.

The central finding reverses a standing assumption. `CopyPolicy.requireSharedStorage` is reachable in every codec, and each library reaches caller samples through exactly one stage, so pointing that stage at caller memory is small and local. What blocks the policy is the container each library exposes — `Data` per component, a packed `[UInt8]` with no row stride, a `[[Int]]` façade over an already-flat interior, or an initialiser that rejects any buffer that is not the packed frame size. A caller holding a padded plane cannot describe an image without first copying it. The `Image`/`ImageDescriptor` layer is therefore not packaging around working codecs; it is the Milestone 3 work.

The predecessor reads caller samples at one function and writes them at one stage, and its `ImageFrame.data` is a packed `[UInt8]` with no row stride. A caller-destination decode must stop before the frame is assembled; routing through the ordinary decode would build a full image and copy it in, which is the shortcut MEM-10 names. Workspace is `Int32` channel planes at twice the final frame.

Measured effects, all from a developer machine: live heap held after one JPEG 2000 decode fell from 16 MB in 6 blocks to 1 KB in 2 at 2048×2048, and for JPEG XL from 2 MB to nothing at 1024×1024; the JPEG 2000 output stage ran 9–35% faster writing the caller's plane; and on the encode side the copy a caller must make today costs 5.5 ms and 8 MB at 2048×2048 while the widening loop costs the same either way. Four defects surfaced during the work: inferred plane origins shearing padded multi-plane output, a shared encode that dropped its container wrapper and was caught only by comparing bytes rather than samples, a harness that bound an owner to storage released on the same line, and an address-sanitizer run reporting 100 MB live on a path holding nothing, which a probe traced to the sanitizer quarantining freed blocks.

The spikes are exploratory and are not proposed for merge into the predecessor repositories. No platform, milestone, release or CLI decision changes, and continuous integration remains blocked, so none of these results is a release gate.

## Decision D1 — codec libraries stay where they are, 20 September 2026

Contract 0.7.0 settles the programme's open architectural question. The shipping codec libraries are the existing repositories; the four contract repositories hold the shared documents, the reference implementation of the shared image layer and the cross-codec conformance harness. No codec source is relocated and nothing is deleted.

The Milestone 3 spikes decided it. All four codec interiors proved contract-capable through single-point changes, and the obstacle to caller-owned storage is the public image type rather than the codec, so the remaining work is additive and identical in size wherever it is done. Migration would have paid, on top of that identical work, the relocation of roughly 219,000 lines of codec source and 184,000 lines of tests together with fixtures and cross-codec oracles, with no continuous integration available to catch what such a move breaks. The contract repositories hold about 1,000 lines of source each, so little built work is given up; three in-house consumers already resolve the existing libraries by URL at pinned released versions, and none references a contract repository.

JXLSwift keeps its codec, its 47,898 lines of source and its 28,322 lines of tests. Its library target already has no external package dependency, and its references to J2KSwift are comments describing naming parity rather than a dependency, so POL-01 and POL-02 need no work here. DICOMKit consumes it by URL.

Two matters are referred to the owner rather than assumed: the Apache-2.0 and MIT split between the existing libraries and the contract repositories, which POL-07 authorises resolving but which should be a deliberate choice; and the inventory and splitting of auxiliary predecessor products under POL-05. The decision rests on documentation evidence gathered on one machine and authorises no codec milestone or release.

## Decision D2 — codec libraries relocate here, 22 September 2026

Contract 0.8.0 supersedes Decision D1. The owner has reaffirmed the repository foundation v0.1.0 as the guidance for this migration and instructed that the codecs move into the successor repositories. Under document precedence rule 1 the owner's current explicit decision outranks a previous contract revision.

JXLSwift relocates here: 47,898 lines of source and 28,322 lines of tests, with its fixtures and oracles. The predecessor source is MIT-licensed and is relicensed to Apache-2.0 under POL-07 as amended; Raster Images Private Limited holds that copyright, and third-party fixtures and dependencies keep their own terms. Its library target already has no external package dependency, and its references to J2KSwift are comments describing naming parity rather than a dependency. `JXLSwiftContract`, `jxl-tool` and the `jxl` alias need a POL-05 disposition, and the predecessor is Apple-only where this repository claims Linux, which is platform work rather than a file move. DICOMKit consumes it by URL.

The sequence is a final JXLSwift release at v1.5.0, then relocation, then a first stable 2.1.0 here once the TEST-07 gates pass, then a maintenance window on the predecessor, then its archive. JXLSwift is not renamed or deleted: this repository's HISTORY.md and MIGRATION.md pin its commits and source files by permalink, and those links are the provenance record.

D1's measurements are retained as the risk register rather than discarded. The continuous-integration objection is unresolved and becomes a precondition: the organisation's Actions billing remains locked, a re-run of JLSwift's CI on 22 September 2026 completed with `steps=0`, and no codec source moves before CI executes and passes here. This record authorises no codec milestone and no release.

## Contract 0.9.0 — floor decision and programme sequence, 22 September 2026

Decision D3 keeps the Apple deployment floor at 26.0 and places the cost of adoption on each consumer at its own cutover. DICOMKit consumes JXLSwift from 1.4.0 at macOS 15 / iOS 18 / tvOS 18 / visionOS 2. JXLSwift is the supported route for those consumers until they raise their floors and re-point, and it is archived only after the last of them has moved.

This repository is third in sequence, after SwiftJLS and SwiftJLI. The predecessor's current release candidate is v1.5.0-rc.1; its promotion is the predecessor's own release task and is not authorised here.

The continuous-integration precondition from 0.8.0 stands. Actions billing remained locked on 22 September 2026, so every workflow in the suite is written and unexecuted. No codec source moves here before CI executes and passes here.

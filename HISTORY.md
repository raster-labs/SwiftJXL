# History and provenance — SwiftJXL

## Higher-effort Modular admission and cancellation — 14 October 2026

Add cumulative reservations for collection, candidate routing/costing, selected emission and capped learning on top of the caller's effort-3 admission. Stable bounded sorting and checkpointed learner blocks preserve the scoped byte output while exposing resource/cancellation failures. Final debug/release pass 40 declarations / 249 cases; focused ASan/TSan pass 18 / 123. Fifty-four small streams and fourteen larger/control baseline/candidate streams independently decode exactly, and 42 old/new worker-budget comparisons reproduce the accounting repair. Repeated higher-effort tree latency still rises roughly 6–7% after investigation, and activity-grey process RSS rises about 5.5%; those safety/performance trade-offs remain open under PERF-03. Public effort stays 3 and Milestone 4 is incomplete. See [evidence and remaining gates](Documentation/Engineering/Migration/MODULAR_EFFORT_BUDGET.md).

## Exact Modular learner sample cap — 14 October 2026

Both internal effort-8/9 learners now select exactly at most 256,000 uniformly distributed samples with overflow-safe arithmetic. The former floor stride could nearly double that count. Debug/release/ASan/TSan each pass 13 declarations / 89 cases; 54 small streams remain unchanged and eight larger/control baseline/candidate streams independently decode exactly. Two release comparisons show about 30–33% faster encoding on two cases whose learning population nearly halves, with compressed-size changes below 0.002%. Public effort remains 3; full admission/cancellation and broader Milestone 4 gates remain open. See [the scoped qualification](Documentation/Engineering/Migration/MODULAR_LEARNING_CAP.md).

## Modular candidate resource enforcement — 14 October 2026

PR26's Swift 6.2 Linux builds exposed a compiler type-checking limit in the grouped test fixture expression. A loop preserves all 8,721 samples and every assertion; focused debug/TSan each pass seven declarations / eleven cases locally. Runtime sources are unchanged. See [the retained failure and repair evidence](Documentation/Engineering/Migration/Evidence/CIRepair/EffortFixture/README.md).

A grouped higher-effort candidate could swallow a worker workspace rejection and return its effort-3 baseline. Propagate cancellation/resource errors through optional candidates, add bounded costing/routing checkpoints and reserve shared-property scratch with checked arithmetic before allocation. The old/new two- and eight-worker probe confirms the repair. Final affected debug/release/ASan/TSan each pass 32 declarations / 202 cases; 54 new independently decoded streams preserve fixture bytes. Public effort remains 3 and complete higher-effort admission remains open. See [qualification and remaining gates](Documentation/Engineering/Migration/MODULAR_EFFORT_LIMITS.md).

## Modular internal effort qualification — 13 October 2026

Single-section effort 4–7 activity candidates now omit unused tree properties and token buckets, reducing that visible array payload from 36 to 8 bytes per sample on 64-bit hosts. Checkpoints bound the shared property pass. All 54 effort/case outputs match baseline bytes and independently decode exactly; affected debug/release/ASan/TSan each pass 25 declarations / 191 cases. A decoder coordinate experiment was reverted after repeated colour regressions. Public effort remains 3; higher-effort admission and wider Milestone 4 gates remain open. See [qualification and retained evidence](Documentation/Engineering/Migration/MODULAR_EFFORT_QUALIFICATION.md).

## Hierarchical sanitizer test deadline — 13 October 2026

Two main-branch Thread Sanitizer attempts reached the same 30-second resource deadline in a combined hierarchical correctness fixture. Separate quantisation inheritance from horizontal/vertical group boundaries, strengthen complete-map checks and add explicit expired/cancelled-before-admission regressions. Production sources, deadlines, memory limits and the complete hosted sanitizer/CLI workflow are unchanged. Affected debug, release, ASan and TSan each passed 6 declarations / 19 cases locally. Hosted Swift 6.2 verification remains required; see [diagnosis and retained evidence](Documentation/Engineering/Migration/Evidence/CIRepair/HierarchyDeadline/README.md).

Hosted Swift 6.2 then exposed a type-checker limit in nested fixture construction. Explicit typed patch arrays preserve the samples and assertions; focused debug and TSan again pass 6 declarations / 19 cases locally on Swift 6.4 after incorporating merged PR23. The hosted compatibility failure and both local validation stages remain archived.

## Public sample-read qualification — 13 October 2026

Investigated the retained PR22 read gap against the original pre-span baseline. Direct byte assembly under the existing descriptor, coordinate and actual borrowed-capacity checks improves the 512×511 read median by 3.17% / 3.20% against PR22 in the fixed sustained-warm comparison. The original-baseline difference is +1.86% / +1.65%. A capture-only experiment was discarded, and all initial timing/resource-wrapper failures remain available. The separate start-of-process tiny-image variation remains unresolved. No ownership, public API, codec or common contract changes. See [bounds proof, exact validation and evidence](Documentation/Engineering/Migration/STORAGE_READ_PERFORMANCE.md).

## Sample-row write qualification — 13 October 2026

Reconciled the historical span-write regression against the current byte-wise implementation. Two fresh baseline comparisons retained a repeated current write slowdown; a row-extent check and cached immutable loop values then reduced write medians by 16.3–25.8% against merged PR21 in two controlled comparisons, and beat the original pre-span baseline at every measured size. Strided padding, byte order, meaningful precision, row cancellation and owning publication are preserved. No codec, public API or shared contract changes.

Full debug and release each passed 290 declarations / 1,136 cases, with focused ASan and TSan each passing 43 declarations / 134 cases; no failures, skips or sanitizer diagnostics. New cases cover pixel gaps, exact final-row capacity, callback order and a throwing callback in a later row. The independent untimed benchmark preflight checks sample bytes, padding and owner identity. The separate 512×511 read regression against the original baseline remains open. See [qualification and retained evidence](Documentation/Engineering/Migration/STORAGE_PERFORMANCE.md); hosted checks and broader migration gates remain separate.

## Grouped VarDCT, reusable scratch and animation decoding — 12 October 2026

Extended public lossy encoding to multiple DC/AC regions and straight alpha within 4096 pixels per dimension and 4,194,304 pixels. Eight independently accepted grouped streams are reproduced byte-for-byte through padded planar public source storage; exact alpha and source ownership are retained. Operation-local noncopyable transform scratch reduces cumulative admission without weakening resource limits; all twelve tested 128–512 pixel admission cases now pass. Combined core ASan/TSan each pass 30 declarations / 110 cases. The preceding public hierarchy/grouped-decoder snapshot passes both sanitizers with 33 declarations. These are scoped checkpoints, not final combined-head qualification.

Added bounded owning animation decoding, indexed selection and structural timing inspection for independent full-canvas frames. Four pinned scalar-reference streams cover twelve RGB8/RGBA16 lossless/lossy frames, timing, exact alpha and aggregate resource/cancellation checks. Unsupported frame dependencies and filter rewrites reject. Subsequent animation encoding preserves exact rational timing and matches the explicit still-image fidelity mode. Eight emitted sequences (24 frames) pass the pinned scalar reference with lossless samples and alpha exact; selected animation checks pass seven declarations / fifteen cases. Final combined safety checks, broader interoperability, hosted platform checks and release gates remain open.

## Public VarDCT encoder and intermediate precision — 12 October 2026

Added explicit lossy encoding through owning source storage, with validated distance and preparation controls, plus CLI options. Public decode now accepts every integer precision from 8 through 16. Thirty-six precision streams pass the unchanged separate scalar reference limits (peak one level, RMS ≤0.187) with exact alpha; a failing-before regression records 28 rejected intermediate-precision cases. Full debug passes 246 declarations / 988 cases without skips; affected ASan and TSan each pass 32 declarations / 221 cases. Hierarchical public defaults, wider groups, original ARM integer-oracle differences and final qualification remain open. See [checkpoint evidence](Documentation/Engineering/Migration/Evidence/VarDCT/PublicEncoder/validation.json).

## Public VarDCT decoder integration — 12 October 2026

Connected the bounded sRGB 8/16-bit VarDCT decoder through the public owning-storage API and CLI. Shared header preparation parses once under the existing admission bounds; allocating output and caller destinations preserve precision, roles, byte order, padding and owner identity. Lossy fidelity is reported explicitly, including CLI JSON. ICC and associated-alpha VarDCT output reject. Full local debug with the independent oracle enabled passed 230 declarations / 883 cases without skips, and CLI inspection, validation, sRGB output and transfer-mismatch rejection passed all 32 retained streams. Final affected sanitizer evidence, original ARM oracle differences and broader migration gates are recorded separately; this is not complete interoperability or release readiness.


## VarDCT single-cell strategy search — 12 October 2026

Added ten bounded forward transform choices with the predecessor cost heuristic and tie priority. All 650 direct pinned libjxl forward vectors pass; twenty mixed streams are independently accepted and meet the separate scalar numerical limits with exact alpha. Affected debug, ASan and TSan each pass 11 declarations / 54 cases. Larger hierarchical strategy search and final integration remain pending. See [exact evidence](Documentation/Engineering/Migration/Evidence/VarDCT/EncoderSmall/validation.json).

## VarDCT encoder preparation — 12 October 2026

Added explicit inverse Gaborish, adaptive quantisation and DC-smoothing controls to the internal DCT8 encoder. The filter agrees with 45 directly generated pinned libjxl plane vectors, including tiny and edge inputs. Twenty prepared streams pass independent acceptance and the separate unchanged scalar numerical limits, with exact alpha. Initial no-control fixture bytes remain unchanged. Full strategy search, public integration and final qualification remain open. See [preparation evidence](Documentation/Engineering/Migration/Evidence/VarDCT/EncoderPrepared/validation.json).

## Internal DCT8 encoder checkpoint — 12 October 2026

Adapted bounded source borrowing, DCT8 analysis and frame entropy writing from the pinned predecessor. Twenty emitted streams are independently accepted; all pass the separate scalar same-stream numerical limits with exact alpha. Affected debug, ASan and TSan each pass 4 declarations / 16 cases. Original NEON integer failures remain recorded. This is a partial internal encoder: inverse Gaborish, adaptive quantisation, mixed strategy search, wider grouping and public integration remain pending. See [exact evidence](Documentation/Engineering/Migration/Evidence/VarDCT/EncoderDCT8/validation.json).

## VarDCT ICC reference extension — 12 October 2026

Preserved bounded ICC metadata for internal XYB reconstruction and qualified the pinned official grayscale/grayscale_5 samples in their prescribed linear-grey Float32 domain. Both meet the original RMS/peak limits; the expanded affected debug suite passes 27 declarations / 110 cases, with ICC-specific ASan/TSan each passing 2 declarations / 3 cases. Public VarDCT and integer ICC output remain unsupported; this does not claim full conformance or silently convert the original profile. See [exact evidence](Documentation/Engineering/Migration/Evidence/VarDCT/ICC/validation.json).

## Internal VarDCT pixel integration — 12 October 2026

Adapted the bounded single-pass default-matrix XYB pipeline from pinned JXLSwift `57e81cb9e2411d1efac435b429a306a031744c1e` under contract 0.10.0: coefficient entropy, strategy mapping, DCT/small/AFV reconstruction, restoration and synchronous borrowed integer output. Full debug passed 207 declarations / 805 cases; affected ASan and TSan each passed 25 declarations / 107 cases. All 32 retained frames pass a separately pinned scalar Float32/nearest-integer oracle; the original ARM integer oracle still has ten recorded failures. This is a scalar numerical milestone, not complete interoperability or public VarDCT support. Official corpus scope, source provenance and remaining gates are in [the updated preflight](Documentation/Engineering/Migration/VARDCT_PREFLIGHT.md).

## VarDCT primitive preparation — 12 October 2026

Adapted bounded scaled DCT, visible-boundary Gaborish and default opsin primitives from pinned JXLSwift `57e81cb9e2411d1efac435b429a306a031744c1e` under contract 0.10.0. Independent mathematical references expose and correct three inherited large-transform precision failures without widening thresholds. Pixel baseline diagnostics identify padded-edge filtering errors; four 16-bit colour cases remain outside the declared limits. Public VarDCT remains disabled. Full debug passed 192 declarations / 721 cases; affected ASan and TSan each passed 10 declarations / 23 cases. See [preflight](Documentation/Engineering/Migration/VARDCT_PREFLIGHT.md) and [exact validation](Documentation/Engineering/Migration/Evidence/VarDCT/primitive-validation.json). Frame, entropy, storage integration and full qualification remain open.

## Modular review and qualification — 12 October 2026

Added bounded encoder workers with joined ordered results, inherited resource/allocation contexts and a live cancellation signal. The nine-case controlled encoder comparison preserves exact serial-successor bytes and independent samples; several native-predecessor latency gaps remain. A single-gradient-leaf decode specialisation passed signed-extreme, layout, malformed-input and cancellation equivalence checks, then improved both timing blocks in all five measured cases (15–27% median reduction). The rejected row-address experiment remains archived separately. Source review also removed a reachable Select-predictor signed-magnitude trap and retained a public malformed-input regression. Final combined validation and hosted CI are recorded separately from the earlier experimental binaries.

Corrected unsupported palette error classification and added public regression cases (ten affected declarations / fourteen cases passed). Larger ordinary-build memory probes passed with zero additional final-image handoff allocations; deliberate stride and byte-order implementation mutants triggered 70 and 42 issues respectively, and restored code passed all 68 cases. The controlled nine-case performance investigation separates native and serial predecessor execution, retains exact sample/output evidence and records residual latency differences as an open stable-release gate. A tested address optimisation was rejected after reproducible large-case regressions; production addressing is unchanged. See [qualification and disposition](Documentation/Engineering/Migration/MODULAR_QUALIFICATION.md).

## ICC preservation and low-precision compatibility — 12 October 2026

Embedded grey/RGB ICC decoding now retains exact profile bytes and caller interpretation under profile, metadata and operation memory limits. Twelve independent streams verify samples and profiles; malformed headers, size ceilings and mismatched destinations reject. ICC encoding remains unsupported. The predecessor rejects these inputs, which is recorded separately from successful successor qualification. Local full debug passed 180 declarations / 669 cases; affected ASan/TSan each passed 19 declarations / 115 cases, and the expanded CLI suite passed 299 checks in each of debug, release, ASan and TSan. See [ICC evidence](Documentation/Engineering/Migration/Evidence/ModularColour/ICC/validation.json).

The next compatibility extension restores 1–7-bit Modular decoding supported by the predecessor. All 28 independent cases retain exact samples in allocating UInt16 and caller-owned UInt8 layouts. The final full debug suite passed 182 declarations / 698 cases; affected ASan/TSan each passed 14 declarations / 53 cases; low-precision CLI checks passed 81 cases in each configuration. See [low-precision evidence](Documentation/Engineering/Migration/Evidence/ModularColour/LowPrecision/validation.json). Head bfd12bc passed all eight hosted checks, including macOS 26 / Swift 6.2. Three ICC and three low-precision one-hour ASan campaigns subsequently passed 577244 mutations; reports retain the exact runtime revisions. Earlier head 526d6bb passed all eight hosted jobs and four one-hour campaigns totalling 471158 mutations. No overall release qualification is claimed.

## BT.709 colour semantics and PNM CLI — 9 October 2026

Added required transfer metadata and a bounded P5/P6/P7 adapter, preserving standard BT.709 or explicitly selected sRGB samples without conversion. The predecessor probe demonstrates silent sRGB labelling, ignored unsupported PAM tuples and rejected valid comments; the new regression suite covers these differences. Input retains its Data owner, and export uses one bounded row rather than an additional full image.

The full local debug library suite passed 177 declarations / 655 cases. Affected library tests passed 52 declarations / 191 cases in each sanitizer. Colour CLI and independent libjxl checks passed 239 checks in each of debug, release, ASan and TSan; foundation, NRRD and native JPEG regressions passed 96, 119 and 141 checks respectively. The release build required an authorised retry after sandboxed debug-symbol generation failed. The initial oracle-path and manual-lint failures, corrected results, hashes and commands are recorded in [validation evidence](Documentation/Engineering/Migration/Evidence/ModularColour/PNM/validation.json). See [profile and provenance](Documentation/Engineering/Migration/PNM_PROFILE.md). Hosted CI, performance regressions, broader feature/platform coverage and release gates remain open.

## Decoder checkpoint overhead — 9 October 2026

Profiling found opaque clock-value setup on the ordinary bit/token checkpoint path. Isolating cancellation and clock comparison in a non-inlined helper preserves the original check frequency while reducing allocating-decode median time by 9–13% on four larger local cases. All five benchmark cases retain exact samples and identical encoded bytes. The full local debug, ASan and TSan suites each pass 175 declarations / 642 cases. Experiments in neighbour inlining and coordinate addressing were reverted after insufficient benefit or a measured colour regression; only the checkpoint change remains. [Raw timings and validation](Documentation/Engineering/Migration/Evidence/ModularColour/Performance/reader-validation.json) record the comparison against the previous successor build. Remaining predecessor performance, wider corpus and release gates are still open.

## Modular edge coverage and entropy checkpoint profiling — 9 October 2026

Added six independently encoded associated-alpha inputs, public strided-source byte-equivalence checks and precision extrema/invalid-high-bit regressions. Profiling identified repeated cancellation/deadline/task-local checks in entropy token emission. These now run before the first token and within 256 tokens, including zero-bit symbols; byte-growth admission remains immediate and final publication remains checked. Added tests for cancellation, expired deadlines and latched failures at this boundary. The full local suite passed 175 declarations / 642 argument cases in debug, ASan and TSan, with no failures or skips.

Release probes retain raw interleaved timings against both the pinned predecessor and the pre-change successor, with independent sample verification and exact successor codestream equality. The checkpoint change reduced measured encoding latency by 31–48% across five cases. Remaining encoder and decoder regressions exceed the investigation threshold; no performance waiver or release qualification is claimed. Power mode, wider corpus and peak-workspace qualification remain open. See [validation and raw measurements](Documentation/Engineering/Migration/Evidence/ModularColour/Performance/validation.json). Predecessor source and production are unchanged.

## Integer Modular colour/alpha API — 9 October 2026

Connected integer greyscale/RGB and optional alpha through owning decoder and encoder storage, with explicit component mapping, 8/16-bit storage, byte order and strides. Inspection allocates no pixel planes; identity decoding writes directly to caller samples, while transforms use admitted Int32 algorithm planes. Encoding uses fixed effort 3 and preserves rendering intent and alpha association. Grouped rANS output now includes the required terminal state for its empty global stream. Invalid UTF-8 names reject rather than silently becoming empty.

The decoder milestone passed 35 declarations / 120 cases in debug, ASan and TSan. The subsequent encoder/API regression scope passed 21 declarations / 112 cases in each configuration, including 54 independent libjxl output checks and six premultiplied-alpha cases. An independent C header oracle confirmed precision, alpha association and rendering intent. The expanded NRRD CLI gate passed 119 checks per configuration, covering grouped images through its 1024-pixel dimension limit. These scopes reuse earlier evidence rather than represent a whole-suite or release gate. Commands and hashes are in [decoder storage evidence](Documentation/Engineering/Migration/Evidence/ModularColour/public-storage-validation.json) and [encoder evidence](Documentation/Engineering/Migration/Evidence/ModularColour/encoder-validation.json). Full feature-group edge cases, release performance/memory, fuzz/platform/hosted validation, review and broader migration remain open. Production is unchanged.

## Native transcoder ICC preservation — 9 October 2026

Added bounded RGB/greyscale ICC decoding and standard ICC writing to native JPEG recompression/reconstruction. Public resource limits cover profiles, fragmented APP2 ordering is preserved, and malformed fragment sets reject. The scalar pixel codec's ICC limits are unchanged. Local debug, ASan and TSan each pass 36 declarations / 124 cases without skips; the expanded independent CLI checks pass 121 process checks. Exact source hashes and commands are in [ICC validation](Documentation/Engineering/Migration/Evidence/NativeJPEG/ICC/validation.json). Final-head hosted validation, review and broader migration gates remain open.

## Public native JPEG integration — 9 October 2026

Connected the bounded native JPEG coefficient/reconstruction stages through the public Transcoder and CLI. Local independent checks cover both directions, Exif/XMP container resolution, repeated byte-exact restoration, resource admission, cancellation and owner lifetime. CLI streams and atomic publication pass regression checks. ICC, final-head qualification and broader migration remain open; this is not a release or production cutover. Exact validation and source hashes are recorded in [PublicIntegration](Documentation/Engineering/Migration/Evidence/NativeJPEG/PublicIntegration/validation.json).

## Native JPEG preparation — 9 October 2026

Native compressed Brotli decoding and JBRD metadata resolution now pass local debug/ASan/TSan qualification. Wire-order prefix codes fix an independently demonstrated predecessor failure; all block/context/dictionary paths have recorded corpus evidence. MIT attribution and exact provenance are retained. Hosted validation and full JPEG restoration remain separate gates.

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

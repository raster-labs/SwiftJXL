# Native JPEG reconstruction preparation

This dependent stage starts from PR #16 at `3f9a981671f0c3d1b95c75258e38341d571d321a`, after its eight hosted jobs passed. Contract 0.10.0 and the pinned predecessor `57e81cb9e2411d1efac435b429a306a031744c1e` remain unchanged. Public native transcoding and CLI integration are now locally tested for the bounded profile. The chronological evidence below distinguishes completed stages from remaining ICC, review, hosted-validation and broader migration gates.

## Executed predecessor baseline

Nine synthetic, textured 31 × 17 images were generated using libjpeg-turbo cjpeg 3.2.0. Independent recompression/restoration used cjxl/djxl 0.12.0. The pinned predecessor's cached release `jxl-tool` used explicit `coefficient-bridge` and autonomous `reverse` modes, never pixel fallback or an original-source argument. Exact commands, binary/source/output hashes, exits and byte comparisons are in [predecessor-baseline.json](Evidence/NativeJPEG/predecessor-baseline.json). The original executed generator is retained alongside it; its output-directory paths document the actual invocation, not a portable default.

| Fixture | Predecessor forward | Predecessor JXL restored by both decoders | Independent JXL restored by predecessor |
| --- | --- | --- | --- |
| Greyscale, 4:4:4, 4:2:2, 4:2:0, 4:4:0, restart interval | Succeeded | Byte-exact in all six cases | Byte-exact in all six cases |
| Progressive | Failed: malformed AC symbol | No output to qualify | Succeeded but wrong bytes: 950 rather than 951 |
| COM plus trailing data | Failed while interpreting the tail as another marker | No output to qualify | Byte-exact |
| Extra marker-fill byte | Succeeded | Both lose one fill byte: 1010 rather than 1011 | Byte-exact |

Independent forward/reverse succeeds byte-exactly for all nine inputs. This confirms the special fixtures can be preserved by the reference implementation; it does not qualify the successor. Original synthetic JPEGs are retained under `Tests/SwiftJXLCoreTests/Fixtures/JPEG`, with hashes and Apache-2.0 provenance. No external photographs or patient data are used.

A portable audit entry point is now available (requires a **new** output directory):

```sh
python3 Scripts/audit-native-jpeg.py --predecessor-binary /path/to/pinned/jxl-tool --tools /path/to/tools --output /new/audit
```

Its successful exit means that the baseline was recorded, not that all preservation cases passed. Inspect the individual `exact_bytes` and exit fields. Oracle executables remain test-only.

## Adaptation and ownership

`JPEGSegmentReader` adapts the predecessor framing design but replaces copied marker payloads with integer ranges over the retained immutable Data owner. Every returned record includes marker fill, the length/payload region and following entropy representation, including stuffed bytes and restart markers. EOI terminates iteration and exposes the complete tail separately. No original byte is silently normalised. Sliced Data uses relative offsets, and retaining the reader keeps the underlying owner alive. This structural walk does not validate Huffman symbols, scan/frame consistency or reconstructed JPEG semantics.

The reader admits input bytes before processing, caps segment count, and checks cancellation/deadlines at entry and within 4098 scanned bytes, including stuffing lookahead. Its workspace is constant; callers must charge retained input and any record collection to the operation budget. It creates no coefficient arrays, pixel images or metadata copies. Whole-operation accounting will be connected with the native operation; these observations are not a measured peak-RSS or throughput claim.

`JPEGFrameLayout` validates 8-bit SOF0/SOF1/SOF2 geometry for one or three components. It checks lengths, dimensions, unique component IDs, sampling/table selectors and coefficient-size arithmetic before future coefficient allocation. It separates the padded interleaved MCU grid from visible single-component blocks and maps scan ordinals into the common storage grid.

Source inspection shows the predecessor progressive AC decoder and encoder iterate the padded grid. For the retained progressive 31 × 17 4:2:0 image, this is 16 luma blocks while a single-component scan contains 12. This is a concrete geometry defect consistent with the baseline failure. The coefficient checkpoint below verifies corrected traversal against an independent decoder. Byte-exact restoration still requires the reconstruction implementation; geometry and coefficient tests alone do not establish that the preservation failures are fixed end to end.

## Initial framing checkpoint

Local Xcode Swift 6.4 debug, ASan and TSan each passed **11 declarations / 25 argument cases**, with zero skips. Tests cover all nine retained independent fixtures offline; fill/tail boundaries; every truncated prefix of a synthetic scan; malformed lengths and markers; multiple scans; sliced-owner lifetime; input/segment/time limits; bounded cancellation during long entropy and fill runs; malformed/unsupported frame headers; coefficient admission and single-component padding exclusion. Logs and source hashes are under [Evidence/NativeJPEG](Evidence/NativeJPEG).

Commands use the existing SwiftBuild caches rather than redundant clean builds:

```sh
swift test --disable-sandbox --build-system swiftbuild --jobs 2 --filter 'JPEG.*Tests'
swift test --disable-sandbox --build-system swiftbuild --jobs 2 --scratch-path /existing/asan --sanitize address --filter 'JPEG.*Tests'
swift test --disable-sandbox --build-system swiftbuild --jobs 2 --scratch-path /existing/tsan --sanitize thread --filter 'JPEG.*Tests'
```

Executed commands additionally set workspace module-cache/config/security paths as recorded in the task evidence. The full existing library/CLI suites and independent interoperability gate remain in hosted CI. Native reconstruction has no successor oracle pass yet.

## Coefficient checkpoint

The internal decoder now reads sequential and progressive 8-bit DCT coefficients without pixel decoding. It checks Huffman code-space bounds, table selectors, scan history, coefficient arithmetic, EOB-run boundaries and restart marker order. The original Data owner is retained. Coefficients use one flat Int32 array per component; quantisation tables are latched at each component’s first scan, and actual scan/restart padding is recorded for later reconstruction. Input, coefficient, aggregate memory, segment and padding-record limits are enforced before growth. The memory policy reserves input, two coefficient bounds, fixed scratch and four padding capacity bounds; this is conservative admission, not measured peak RSS or proof of the future complete transcoder’s allocation behaviour.

All visible coefficients and quantisation values match an independent libjpeg-turbo 3.2.0 reader for **15 fixtures**: the original nine plus 17 × 17 progressive edge, progressive restart, progressive 4:2:2 and 4:4:0, non-interleaved DC refinement and sequential multi-scan inputs. The progressive input that failed in the predecessor now decodes with exact independent coefficients. Padded dummy-block values and original-byte reconstruction still require the reconstruction gate; visible-coefficient equality does not establish that gate.

Local debug, ASan and TSan each passed **23 declarations / 51 cases**, zero skips. Added tests cover every truncated progressive prefix, deterministic bit mutations, malformed Huffman trees, wrong restart order, noncanonical padding retention, admission limits, sliced-owner lifetime, concurrent operations and cancellation during coefficient work. Two regressions first demonstrated that odd-offset FF00 stuffing could skip modulo-based checkpoints; threshold-based checks fix both framing and entropy readers. The failing-before log and all passing logs/hashes are retained under Evidence/NativeJPEG.

The test-only C reader in `Scripts/TestSupport/jpeg-coefficient-oracle.c` uses the installed libjpeg API; it is never linked into or invoked by the library. Snapshot JSON and JPEG hashes are retained in the fixture manifest. `Scripts/validate-jpeg-coefficients.py --oracle /compiled/oracle --output /new/evidence` requires a fresh oracle comparison of every fixture and records the executable hash/version. CI compiles this reader against its test-only libjpeg dependency and requires all snapshots to match, in addition to normal debug/release Swift tests. Missing tools or mismatches fail. Local tool build arguments are recorded in `coefficient-validation.json`.

The initial framing head `c43c3c6cb13d604dcc75e6152da12f178c9df2af` passed all eight jobs in [run 37887784159](https://github.com/raster-labs/SwiftJXL/actions/runs/37887784159), including macOS. The coefficient checkpoint requires its own hosted validation. Controlled release performance and larger security corpora remain open.

## Reconstruction metadata checkpoint

Adapted the predecessor JBRD field reader/writer and metadata distribution inside the core. Input, payload expansion declarations, aggregate workspace, marker counts, reconstruction events and padding-bit counts are admitted before allocation. Header reads validate component/table references, Huffman code space, scan history, event ordering and extra-zero-run counts. Writes validate array shapes and field ranges before indexing or integer conversion, reserve a conservative header-output envelope, and run semantic validation before returning bytes. APP/COM/tail slots initially contain admitted sizes; they do not imply that Brotli has been decoded.

The metadata resolver checks the exact expanded-payload length and each APP/COM marker identity and length. External Exif TIFF, XMP and ICC bytes must fit exactly. ICC fragment count is bounded to 255; missing, truncated or surplus required metadata throws instead of leaving zero-filled content. Inputs remain immutable and failure publishes no partial resolved result. No external XML or metadata is executed. Container-specific Exif offsets and complete native decompression will be connected separately.

Sixteen independent reconstruction bundles were generated using cjxl 0.12.0 from the retained 15 JPEG fixtures and an additional noncanonical-padding image. For the latter, libjpeg-turbo independently confirms that clearing the padding bit leaves coefficients unchanged. Original JPEG fields and metadata payloads are recorded. A separate system Brotli decoder finds the unique offset that expands to those exact metadata bytes; the native header reader lands on that offset. Native header re-serialisation is **byte-identical to the independent header in every fixture**. Field, Huffman, scan, fill-byte, tail and zero-padding checks also pass. These tests qualify the metadata boundary, not a completed JPEG→JXL→JPEG operation.

Local Xcode Swift 6.4 debug, ASan and TSan each passed **30 declarations / 73 cases**, zero skips, covering the prior JPEG tests plus the 16 bundles, truncated/mutated headers, invalid writer shapes, event/expansion/memory limits, malformed metadata, exact external metadata assembly, sliced inputs, concurrency and cancellation. Evidence is under `Evidence/NativeJPEG/jbrd-*`; fixture and tool hashes are in `Tests/SwiftJXLCoreTests/Fixtures/JBRD/manifest.json`. The executed generator is retained as evidence; its recorded paths describe the local run. The native package gains no reference-tool dependency.

Field semantics were checked against libjxl at `a7a9c787341cf703dede03c2009fa460cae5e5df`: [jpeg_data.cc](https://github.com/libjxl/libjxl/blob/a7a9c787341cf703dede03c2009fa460cae5e5df/lib/jxl/jpeg/jpeg_data.cc) and [dec_jpeg_data.cc](https://github.com/libjxl/libjxl/blob/a7a9c787341cf703dede03c2009fa460cae5e5df/lib/jxl/jpeg/dec_jpeg_data.cc). Their downloaded hashes are recorded; the migrated implementation comes from the owner-authorised predecessor source, not a new runtime reference-code dependency.

The coefficient head `420c890b90efd62c6f3859600030d06da4489211` passed macOS, all four Linux jobs, the consumer and contract checks. [Run 37889538000](https://github.com/raster-labs/SwiftJXL/actions/runs/37889538000) failed its independent-oracle job because the new test step invoked absent `cc`; that job had already passed its debug/release libjxl tests but skipped the later NRRD checks. The container's recorded C compiler is `/usr/bin/clang`, so the workflow now invokes `clang`, matching the successful local oracle build. The next head requires a complete fresh hosted run; this setup fix is not yet a hosted pass.

## Remaining integration

Continue with native bounded Brotli, extraction of reconstruction events from JPEG entropy data, and the native VarDCT coefficient bridge. Connect the qualified metadata fields to JPEG scan restoration, then the common in-memory Transcoder and CLI with resource/copy reports and cancellation throughout. Qualify autonomous byte equality in both oracle directions, corrupted/unsupported metadata, repeated cycles, concurrency, performance and all required platforms before declaring this native gate complete. Main, releases and JXLSwift production are unchanged.

The metadata head `c277c1c9fc152996581a843875e017c904b54b96` failed Swift 6.2 compilation in [run 37891489224](https://github.com/raster-labs/SwiftJXL/actions/runs/37891489224): the synthesised `JBRDBudget` initializer was private on that compiler. Swift 6.4 Linux x86/ARM passed. An explicit internal initializer now fixes the access-control difference; local Swift 6.4 targeted metadata checks passed (7 declarations / 22 cases, no skips). Existing sanitizer evidence remains tied to the earlier source hashes. Fresh hosted Swift 6.2 validation is required. See `Evidence/NativeJPEG/jbrd-initializer-fix.json` and its log.

## Native Brotli framing foundation — 9 October 2026

Adapted the pinned predecessor's stream/meta-block and stored-block encoding algorithms. A new input-owner reader uses relative offsets without a full byte-array copy. Metadata now has distinct skip semantics: MSKIPBYTES zero means zero bytes, metadata never enters output/history, nonminimal lengths and nonzero alignment bits reject. This corrects predecessor source behaviour not covered by its passing baseline. Window encodings, variable-length counts and trailing-input checks are bounded; encoding admits input, output capacity/transients and scratch before allocation, and checks cancellation every 4096 payload bytes. Bit reading checks work every 1024 calls (at most 4096 consumed bytes). These are conservative operation reservations, not measured RSS; enclosing JBRD/container memory still needs aggregate admission.

The existing predecessor baseline has **36 Brotli tests passing, zero failures** across nine suites. Its metadata edge coverage was insufficient; no predecessor source was edited. RFC 7932 sections 9–10 were checked before adaptation; the exact text hash is recorded in `Evidence/NativeJPEG/brotli-framing-validation.json`.

Local Swift 6.4 debug, ASan and TSan each passed **36 declarations / 79 cases**, zero skips, covering JPEG coefficients/reconstruction headers and six new Brotli test declarations. The new tests exercise 23 independently accepted streams (all window sizes, empty/nonempty/final metadata), all 256 variable-length counts, truncation, reserved fields, noncanonical lengths, fill/trailing bytes, sliced input, cancellation/deadlines and allocation limits. Encoder bytes match six independently decoded boundary streams at 0, 1, 65536, 65537, 1048576 and 1048577 bytes. `Scripts/validate-brotli-framing.py` independently rechecks all 29 streams with libbrotli and records version plus fixture/output hashes; it is also required in the hosted oracle job. The test-only library is not linked to any package product.

Commands (repository root; all recorded local results exit 0):

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" xcrun swift test --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security --build-system swiftbuild --jobs 2 --filter 'JPEG.*Tests|JBRDTests|BrotliFramingTests'
# Sanitizers use the same filter, --sanitize address or thread, and existing
# --scratch-path ../evidence/cli-validation-qualification/build/asan or tsan;
# cache/config/security are under ../evidence/cli-validation-qualification.
python3 Scripts/validate-brotli-framing.py --library /opt/homebrew/opt/brotli/lib/libbrotlidec.dylib --output ../native-jpeg-audit/brotli-framing-oracle.json
(cd Documentation && shasum -a 256 -c COMMON_CONTRACT_SHA256.txt)
```

Hosted validation of the Brotli additions is **pending**. Compressed-body decoding (block switching/context maps, LZ77 and dictionary), integration with JBRD, full JPEG restoration, hot-path release performance and whole-operation resource evidence remain open. No full Brotli decoder or public transcoding capability is advertised. The stored-block encoder is standard Brotli but does not perform entropy compression.

## Native Brotli decoder and JBRD resolution — 9 October 2026

The compatibility-fix commit `1e40cee9bef7aa8df9c37dc83c25d63a237c9276` passed all eight hosted jobs, including macOS 26 / Swift 6.2, in [run 37892041402](https://github.com/raster-labs/SwiftJXL/actions/runs/37892041402). This is evidence for that commit, not the subsequent Brotli implementation.

Implemented native RFC 7932 simple/complex canonical prefix codes, all four literal context modes, context maps with zero-run/inverse-MTF decoding, literal/command/distance block switching, short/direct/postfix distances, overlapping LZ77 copies and the standard dictionary/transforms. Distance history persists across meta-blocks. Metadata blocks are skipped without entering output/history. Input, declared output, table allocations, command/meta-block counts, alignment, trailing bytes and insert/copy/dictionary expansion are checked. Cancellation covers zero-bit prefix trees, bounded bit work and long copies. The decoder returns exactly the caller-admitted expansion size or throws, without partial success or external fallback.

A new isolated predecessor regression demonstrates why a direct copy was insufficient: stream `420000006450804060108006` yields `41 01 02` with independent libbrotli, but pinned JXLSwift returns `01 02 41`. Its three-symbol simple-code implementation sorts symbols before assigning lengths; RFC 7932 section 3.4 assigns lengths in wire order. The successor passes this regression. The original 36 passing predecessor Brotli tests and this failing additional probe are both retained.

`JBRDBoxReader.readResolved` now combines header parsing, native Brotli expansion and strict marker-metadata assembly. It admits retained header/external buffers before giving the decoder the remaining memory budget, and charges persistent dictionary workspace during subsequent assembly. The public JPEG transcoder remains unavailable: coefficient-bridge integration and complete original-JPEG byte restoration are still required. The standalone stored-block Brotli encoder exists; full JPEG reconstruction event extraction/forward assembly is not yet connected.

Validation on local Swift 6.4: debug, ASan and TSan each passed **44 declarations / 142 cases**, zero skips. The decoder matches **41 independent compressed streams** and **16 independent JBRD payloads**. Additional loops check the 23 framing streams, six encoder size boundaries, all 121 dictionary transforms on the first/last word of every supported length (**5082 independent vectors**), truncation/bit mutations, expansion errors, allocation/command/meta-block limits and cancellation. Coverage counters prove all four context modes, all four postfix values, all sixteen short distance codes, two block types in each category, six literal/two distance trees, actual block switches, dictionary references and multi-meta-block/metadata paths. These counters describe the retained corpus, not exhaustive format/security qualification.

The dictionary blob is byte-identical to independent libbrotli. Its transforms and predecessor-derived decoding material retain MIT attribution alongside owner-authored Apache-2.0 work. The 2048 context entries come from `google/brotli` pin `028fb5a23661f123017c060daa546b55cf4bde29`; source hashes and the MIT licence are retained. Neither libbrotli nor libjxl is a runtime dependency. `Scripts/validate-brotli-decoder.py` repeats the independent fixture/transform checks in the hosted oracle job.

An isolated optimised build of the exact Brotli source files (`swiftc -O`, local macOS arm64/Swift 6.4) decoded the 297576-byte mixed fixture at a **230.70 MiB/s median** across seven samples of 200 iterations after ten warmups; every result was byte-compared. Raw timings, harness and toolchain are retained. This is a narrow local measurement, not full package release, comparative performance, RSS or platform qualification; the CPU-model query was unavailable under the current sandbox. Conservative admitted memory is reported separately from measured memory, and whole-transcoder copy/lifetime accounting remains open.

Commands and evidence:

```sh
# Use the same debug/sanitizer cache and scratch options recorded in the framing section:
xcrun swift test --filter 'JPEG.*Tests|JBRDTests|Brotli.*Tests'
python3 Scripts/validate-brotli-decoder.py --decoder-library /opt/homebrew/opt/brotli/lib/libbrotlidec.dylib --common-library /opt/homebrew/opt/brotli/lib/libbrotlicommon.dylib --output ../native-jpeg-audit/brotli-native-oracle.json
xcrun swiftc -O -package-name SwiftJXL Sources/SwiftJXLCore/Brotli/*.swift ../native-jpeg-audit/brotli-release-probe/main.swift -o ../native-jpeg-audit/brotli-release-probe/benchmark
../native-jpeg-audit/brotli-release-probe/benchmark "$PWD/Tests/SwiftJXLCoreTests/Fixtures/Brotli"
```

All listed executed tests/oracle/benchmark commands returned zero. `Evidence/NativeJPEG/brotli-native-validation.json` records final source hashes and coverage. Hosted Swift 6.2/6.4 debug/release and macOS checks for the new implementation remain pending its pushed head. Full fuzzing, whole-transcoder release benchmarks, broader image features, Apple adapters/platform coverage and release preparation remain open. All seven common contracts remain byte-identical. No main merge, tag, release or production cutover occurred.


## Scan reconstruction events — 9 October 2026

The native coefficient decoder now retains per-scan SOS parameters, component/table selectors, end-of-block-run reset points and redundant trailing zero-run counts. Block indices follow entropy scan order, including padded blocks in interleaved MCUs. Fresh scan/restart state is distinguished from an exhausted EOB run; this preserves adjacent run boundaries in initial and refinement scans. Events share a cumulative limit (default 65536); scan inventory is capped at 4096 and admitted alongside source, coefficient and padding capacity before allocation. Unrepresentable redundant refinement tails reject explicitly rather than silently losing codewords; libjpeg decodes the test vector, while the independent libjxl reconstruction encoder rejects it. No original JPEG fallback is introduced.

Fifteen existing JPEG/JBRD fixture pairs match all extracted scan parameters and events. Five authored entropy vectors independently restore byte-exactly through libjxl: sequential extra zero runs, split/grouped progressive EOB runs, restart boundaries and exact-band zero runs. Tests compare explicit expected event indices/counts as well as the independently encoded JBRD records. The event cap is tested at and below its cumulative boundary. A required CI oracle step regenerates these bundles and checks exact restoration; no test-only runtime dependency enters the library. JPEG XL Project BSD attribution is retained for the adapted reconstruction semantics.

Final local debug, ASan and TSan each pass **48 declarations / 164 cases**, no failures/skips. The only initial failure was a missing fixture-resource declaration; final evidence includes that declaration and the unsupported-tail regression. The independent oracle passes five byte-exact vectors and verifies the explicit unsupported case. Exact commands, hashes, generator, benchmark harness and logs are in `Evidence/NativeJPEG/ScanEvents`.

An isolated Swift 6 `swiftc -O` before/after comparison over the unchanged 834-byte progressive-edge fixture (1536 coefficients, 100 warmups, seven samples of 2000 decodes) measured median 25.475 → 27.465 microseconds per decode, approximately 7.8% added latency for retained reconstruction metadata on this small fixture. This is a bounded overhead measurement, not general performance qualification or a full package release build. Broader performance and memory measurements remain open.

This stage extracts reconstruction data; it does not implement the native VarDCT bridge or byte-restoring JPEG writer. Those, public Transcoder/CLI integration and whole-operation resource reporting remain required. Hosted CI must validate the new head. PR #15's separately reviewed diagnostic-backpressure fix must also be inherited when the dependent branches are updated.

## Native reconstruction metadata assembly — 9 October 2026

`JPEGReconstructionMetadata` now assembles a complete JBRD bundle from validated coefficient owners using the native stored-Brotli encoder. It preserves APP/COM records without external metadata, marker fill and trailing bytes, active quantisation-table binding, scan reset/extra-zero events and noncanonical entropy padding. Fill runs exceeding the 16-bit per-record size are split without changing their bytes. Source JPEG data supplies metadata; it is never returned as a fallback result.

Resource admission spans retained source/coefficient owners, scan events, copied metadata, header validation, Brotli payload and final bundle construction. Nested phases receive only the remaining memory budget. Copies and loops have bounded checkpoints, including immediately before publication. These are conservative reservations, not measured RSS guarantees; the header writer can reject a tight compressed-size ceiling based on its upper-bound capacity admission. Repeated DRI, extra fill inside restart markers and a superseded first quantisation table that leaves the first JBRD table unused are explicitly unsupported. They are not silently normalised.

Local Swift 6.4 debug, ASan and TSan each passed **54 declarations / 214 cases**, with no failures or skips. Each configuration includes **23 independent byte-exact JPEG restorations**: libjxl supplies the coefficient frame, its reconstruction box is replaced with the native bundle, and djxl must produce every original byte. Tests cover the 15-file JPEG corpus, five authored entropy-event vectors, zero padding, a nonzero quantisation slot and long marker fill/tail. The reference JPEG reader rejects a single fill run above 65535 bytes; that case uses the unchanged grayscale coefficient frame while the native split metadata records reconstruct the longer original. This explicitly tests metadata interoperability; it does not claim a native coefficient-to-JXL bridge.

Additional tests exercise resource ceilings, exact final bundle-size admission for a payload-dominated case, cancellation across initial/middle/final checkpoints, sliced-owner lifetime and concurrent assembly. The valid JPEG table-redefinition rejection was cross-checked against libjxl's failure to create reconstruction data. Evidence, hashes and commands are under `Evidence/NativeJPEG/MetadataAssembly`.

PR #17 also inherits the reviewed NRRD branch's diagnostic fix and regressions. Full native VarDCT frame encoding/decoding, the native JPEG reconstruction writer and public transcoder integration remain outstanding. No main merge, stable release or production cutover is authorised by this checkpoint.

A standalone Swift 6.4 `-O` benchmark on local macOS 27 arm64 measured native metadata assembly only (coefficient decode excluded), with 20 warmups and seven trials of 200 iterations per fixture. Median times: gray 29.22 microseconds, progressive-edge 39.17 microseconds, metadata-tail 27.02 microseconds, long-fill 346.8 microseconds. These are absolute new-stage timings, not a predecessor speedup comparison, full-package release qualification or peak-memory measurement. Exact source hashes, harness and compiler command are captured beside the validation evidence.

## Native JPEG output writer — 9 October 2026

`JPEGReconstructionWriter` now reconstructs JPEG bytes from flat coefficient owners and resolved JBRD metadata. Its API has no original-JPEG parameter. It writes baseline/extended/progressive Huffman scans, including scan reset/extra-zero events, restart markers, exact padding, original marker order, APP/COM, fill and tail data. The implementation adapts the pinned predecessor architecture and pinned libjxl reconstruction algorithms with their Apache-2.0/BSD attribution. It uses one bounded final output buffer, without separate complete scan buffers or pixel conversion.

Before publication it validates metadata shape, geometry and coefficient sizes, active quantisation binding, table symbols, scan history, event consumption, padding consumption and coefficient representability. Malformed or unsupported input throws rather than trapping or returning a partial result. Output growth and buffered refinement bits share admission with retained coefficient/metadata owners and fixed workspace allowances. Cancellation is checked during validation, markers, MCUs/blocks, bit flushing, copies and final publication. These are source-level lifetime/admission arguments, not measured peak RSS or instrumented allocation counts.

Local Swift 6.4 debug, ASan and TSan each passed **61 declarations / 262 cases**, without failures or skips. The writer restores 23 regular synthetic variants byte-for-byte and also crosses the 32767-block progressive EOB limit with a 32768-block constant image. Twenty regular cases and the large EOB case use independently generated JBRD metadata. The large fixture is authored synthetic CC0 data, generated by libjpeg-turbo 3.2.0 and independently recompressed/restored by libjxl 0.12.0. Its test explicitly allows 60 seconds for instrumented execution. The mandatory reference script now verifies six entropy fixtures, their source/bundle hashes and exact restoration.

Other tests cover exact output-size admission, low coefficient/memory/refinement limits, malformed owners and metadata, initial/mid/final cancellation, concurrent operations and bounded coefficient mutations: accepted mutations must decode to the changed coefficients exactly. This is targeted regression coverage, not a completed long-running fuzz campaign. Commands, hashes and outcomes are in `Evidence/NativeJPEG/Writer`; Swift Testing summaries supply counts because local Swift Build did not emit requested xUnit files.

The standalone Swift 6.4 `-O` benchmark measured the writer plus exact-byte comparison, excluding coefficient decoding and metadata assembly. Seven trials measured medians of 49.73 microseconds (gray), 73.41 (progressive-edge), 63.13 (metadata-tail), 47.20 (long-fill) and 36043.63 (32768-block EOB case). The large case used three warmups and ten iterations per trial; others used twenty warmups and two hundred iterations. This is absolute stage timing on local macOS 27 arm64, not a predecessor speedup, whole-package release test or peak-memory claim. The exact harness, compiler command and source hashes are retained.

PR #17 now targets main after the authorised #14/#15/#16 merges. The earlier metadata commit `a8caf403e788508f4c0279b529222c5159858e73` passed all eight jobs in run 37902408866; fresh CI is required for this writer checkpoint. Native JPEG/JXL VarDCT coefficient bridging and public Transcoder/CLI integration remain unfinished. This checkpoint authorises no main merge, tag, release or production change.

The first writer CI run (37905238946 at `6e73484`) exposed a Swift 6.2 access-control difference: its synthesized `JPEGOutput` initializer was private. An explicit initializer preserves all property defaults and entropy logic. Local Swift 6.4 debug again passed 61 declarations / 262 cases with no skips; fresh hosted Swift 6.2 validation is required. The earlier sanitizer and benchmark evidence remains tied to its recorded source hashes. See `Writer/swift62-initializer-fix.json`.

## Native forward coefficient frame — 9 October 2026

The internal `JPEGBridgeCoefficients` adapter retains the existing immutable flat coefficient arrays and presents JXL channel order, transposed quantisation and one transposed scratch block. Greyscale chroma is implicit zero storage. Source-owner release, concurrent reads, copy-on-write isolation and scoped buffer-identity tests pass. The adapter does not retain the source JPEG or create a pixel image.

`JPEGBridgeFrameWriter` now writes a native VarDCT codestream from that view. It uses streaming histogram passes, one-cluster prefix entropy, RAW quantisation sub-images, a shared Modular DC/metadata tree and standard section/TOC assembly. It supports multiple AC groups within the predecessor's single-DC-group limit of 2048 pixels per side. Larger frames reject explicitly. The predecessor's ANS/context-clustering optimisation remains pending; this checkpoint makes no compression-ratio or performance-parity claim.

Local Swift 6.4 debug, ASan and TSan each passed **11 declarations / 58 cases**, with no failures or skips. Each includes **19 independent byte-exact restorations**: both the codestream and JBRD are native, and djxl reconstructs the source JPEG from their standard container. Cases include the existing 15-file corpus, 257×513 4:2:0, 513×257 progressive 4:2:2, 2048×17 greyscale and SOF1 with 16-bit quantisation entries. Container assembly is still test-only. No reference encoder supplies any part of these native files.

Resource tests cover exact and insufficient output bounds, coefficient/memory ceilings, expired deadlines, and cancellation before/mid/after construction. Aggregate adapter/writer admission includes retained coefficient capacity, fixed table/predictor scratch and six bounded output copies/capacities. The eventual operation must also admit the source JPEG, decoded scan events and reconstruction metadata. There is no measured peak-RSS claim.

An optimised standalone frame-writer benchmark (three warmups, seven trials; forty iterations for small cases and three for multi-group) measured: gray 537.61 µs, progressive-edge 507.33 µs, quant16 521.03 µs, multigroup-420 18177.25 µs. It includes deterministic output comparison and excludes JPEG decoding/metadata assembly; it is not whole-package release qualification. Commands, source/fixture hashes and results are in `Evidence/NativeJPEG/ForwardFrame`.

Native reverse coefficient-frame decoding, full container/operation memory integration, public Transcoder and CLI remain unfinished. Hosted validation for this change remains pending. The owner has authorised review and merge of PR #17 **after its complete implementation and required validation pass**; that permission does not authorise merging this intermediate state, tagging, releasing or changing production.

## Native reverse coefficient frame — 9 October 2026

`JPEGBridgeFrameReader` now reads bounded JPEG-reconstruction VarDCT frames into flat coefficient owners and resolves their quantisation/sampling for the native JPEG writer. It handles prefix/ANS entropy, global/local Modular trees, custom DCT8 coefficient orders, multiple AC groups and integer chroma correlation restoration. It validates section boundaries, entropy terminal states, quantisation fingerprints and coefficient bounds. No pixel decode, source-JPEG lookup or runtime external codec is involved.

Local Swift 6.4 debug, ASan and TSan each passed **14 declarations / 61 cases**, without failures or skips. Each configuration now checks all 19 fixtures in both independent directions: native frame/metadata → djxl → exact JPEG, and cjxl frame/metadata → native decoder/writer → exact JPEG. Native-only reconstruction also checks coefficient and quantisation equality. Inputs include progressive/subsampled/restart and multi-group JPEGs, the 2048-pixel boundary and 16-bit quantisation.

Negative tests reject every truncated prefix of a small native frame, trailing bytes, insufficient memory/coefficient budgets and expired deadlines. They exercise initial/mid/final cancellation, bounded single-bit mutations and concurrent readers. The shared entropy parser retains its default 4096-context ceiling; the VarDCT reader explicitly admits larger, bounded context counts under cumulative workspace accounting. Existing scalar regression coverage passed **28 declarations / 41 cases**, including independent greyscale interoperability, with no skips.

The optimised standalone reader benchmark measured gray 39.68 µs, progressive-edge 39.19 µs, quant16 35.74 µs, multigroup-420 4454.88 µs. Three warmups and seven trials use forty iterations per small case and three for multi-group. This measures native frame decoding with coefficient comparison; JPEG input decoding, JBRD resolution and JPEG output are excluded. It is neither predecessor performance parity nor full-package release/peak-RSS qualification. Commands, source hashes, oracle byte hashes and results are in `Evidence/NativeJPEG/ReverseFrame`.

The reader explicitly rejects ICC, extra channels, animation, multiple passes/DC groups and profiles outside the qualified DCT8 JPEG quantisation representation. Container/external metadata handling, aggregate operation integration and public Transcoder/CLI remain pending. All eight hosted jobs, including macOS, passed for published head `5f67bfb` in run 37905750662; that result does not validate this newer local code. PR #17 remains a draft and must satisfy the owner's completion/review/check conditions before its authorised merge.

## Public native operation and CLI — 9 October 2026

`Transcoder.transcode(_:to:options:)` now composes the native coefficient, reconstruction-metadata and frame components into in-memory JPEG recompression and autonomous original-byte restoration. Capabilities advertise the bounded qualified profile and `.originalBitstream` fidelity. It never accepts an original-source fallback, creates a pixel image, invokes an external codec or stages an intermediate file. The input owner, coefficients, scan records, metadata, entropy workspace and compressed output share conservative remaining-capacity admission. Caller dimension/pixel/nesting, workspace, metadata, compressed/coefficient, aggregate memory and deadline limits are enforced. Destructive metadata policies and required unavailable acceleration reject.

The container layer admits copies, rejects missing/duplicate reconstruction data and ambiguous/truncated codestreams, validates file-type/level metadata and resolves external Exif/XMP, including independently generated compressed `brob` boxes using native Brotli. Nonzero Data start indices and caller-released owners are covered in both directions. Unused quantisation records that the frame cannot recover reject rather than silently changing restored bytes. ICC remains explicitly unsupported pending its colour-header integration.

CLI `transcode` now accepts explicit `jpeg` ↔ `jxl`/`jpeg-xl` pairs. It uses existing bounded file/pipe I/O, atomic final-file publication, overwrite/alias protection, deadlines and cancellation. JSON success reports use stderr after successful binary publication. Help, man page, capability reporting, public consumer, migration guide and mandatory debug/release independent CLI CI checks are aligned. The CLI keeps its 4 MiB input/output ceiling; the public operation has a 64 MiB compressed/coefficient ceiling under caller limits.

Combined local debug, ASan and TSan each passed **32 declarations / 116 cases**, without failures or skips. Coverage includes 19 repeated public round trips, 20 public independent checks in each direction (including compressed Exif/XMP), limits, cancellation, sliced-owner/concurrent calls, container failures and the existing bridge/API groups. Initial concurrent ASan execution hit work limits in two large bridge fixtures; fixture suites now execute serially while explicit concurrent-call tests remain. No production limit was relaxed. A subsequent review increased the persistent dictionary/inventory reservation from 1 MiB to 2 MiB; the affected public/API debug groups then passed **18 declarations / 55 cases**. Sanitizer evidence retains its exact earlier source hashes rather than claiming this later admission-only edit was instrumented.

The integrated CLI passed **106 native JPEG**, **96 help/installation/manual**, **111 NRRD** and **104 inspection/validation** process checks. The standalone optimised stage benchmarks remain historical evidence; whole-operation benchmarking and measured allocation/copy accounting are still pending. Unknown public peak/allocation measurements stay nil. Copy reports identify known compressed container assembly/extraction bytes without claiming all entropy or metadata copies are measured. Evidence and exact source/command/binary hashes are in `Evidence/NativeJPEG/PublicIntegration`.

PR #17 remains incomplete pending ICC/profile work, final review and required validation at its completed head. The owner's standing authorisation now covers review and merge of each fully completed migration PR after resolving blockers and passing required checks, including macOS. It does not authorise releases, tags or production cutover. Broader migration/platform/release gates remain open.

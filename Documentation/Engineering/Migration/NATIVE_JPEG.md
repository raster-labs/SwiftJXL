# Native JPEG reconstruction preparation

This dependent stage starts from PR #16 at `3f9a981671f0c3d1b95c75258e38341d571d321a`, after its eight hosted jobs passed. Contract 0.10.0 and the pinned predecessor `57e81cb9e2411d1efac435b429a306a031744c1e` remain unchanged. Native public transcoding is still unavailable. The work below is internal preparation for the required byte-exact JPEG reconstruction gate in TRANSCODING.md.

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

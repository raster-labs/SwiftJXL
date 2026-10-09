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

The reader admits input bytes before processing, caps segment count, and checks cancellation/deadlines at entry and at most every 4096 scanned bytes. Its workspace is constant; callers must charge retained input and any record collection to the operation budget. It creates no coefficient arrays, pixel images or metadata copies. Whole-operation accounting will be connected with the native operation; these observations are not a measured peak-RSS or throughput claim.

`JPEGFrameLayout` validates 8-bit SOF0/SOF1/SOF2 geometry for one or three components. It checks lengths, dimensions, unique component IDs, sampling/table selectors and coefficient-size arithmetic before future coefficient allocation. It separates the padded interleaved MCU grid from visible single-component blocks and maps scan ordinals into the common storage grid.

Source inspection shows the predecessor progressive AC decoder and encoder iterate the padded grid. For the retained progressive 31 × 17 4:2:0 image, this is 16 luma blocks while a single-component scan contains 12. This is a concrete geometry defect consistent with the baseline failure. Full causal confirmation and byte-exact restoration still require the adapted entropy/reconstruction implementation; the new geometry tests alone do not establish that those failures are fixed end to end.

## Validation at this checkpoint

Local Xcode Swift 6.4 debug, ASan and TSan each passed **11 declarations / 25 argument cases**, with zero skips. Tests cover all nine retained independent fixtures offline; fill/tail boundaries; every truncated prefix of a synthetic scan; malformed lengths and markers; multiple scans; sliced-owner lifetime; input/segment/time limits; bounded cancellation during long entropy and fill runs; malformed/unsupported frame headers; coefficient admission and single-component padding exclusion. Logs and source hashes are under [Evidence/NativeJPEG](Evidence/NativeJPEG).

Commands use the existing SwiftBuild caches rather than redundant clean builds:

```sh
swift test --disable-sandbox --build-system swiftbuild --jobs 2 --filter 'JPEG.*Tests'
swift test --disable-sandbox --build-system swiftbuild --jobs 2 --scratch-path /existing/asan --sanitize address --filter 'JPEG.*Tests'
swift test --disable-sandbox --build-system swiftbuild --jobs 2 --scratch-path /existing/tsan --sanitize thread --filter 'JPEG.*Tests'
```

Executed commands additionally set workspace module-cache/config/security paths as recorded in the task evidence. The full existing library/CLI suites and independent interoperability gate remain in hosted CI. Native reconstruction has no successor oracle pass yet.

## Remaining integration

Continue with bounded JPEG tables/entropy/coefficient storage; progressive and non-interleaved scan traversal; JBRD extraction/restoration of marker fill, tail and noncanonical scan details; bounded Brotli metadata and the native VarDCT coefficient bridge. Then connect the common in-memory Transcoder and CLI with resource/copy reports and cancellation throughout. Qualify autonomous byte equality in both oracle directions, corrupted/unsupported metadata, repeated cycles, concurrency, performance and all required platforms before declaring this native gate complete. Main, releases and JXLSwift production are unchanged.

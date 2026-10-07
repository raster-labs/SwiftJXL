# SwiftJXL — reversible JPEG ↔ JPEG XL transcoding

Native-transcoding requirements introduced in contract **0.2.0**; the current common contract distribution is **0.10.0**. Implementation instructions and source review, 18 September 2026. Milestone 1 supplies an unsupported transcoder call shape with empty capabilities; real recompression and reconstruction remain deferred. Read AGENTS.md, IMPLEMENTATION.md and the common contracts first. For application API/dependency changes and rollout gates, see [MIGRATION.md](MIGRATION.md).

## Required outcome and exact meaning

Recompress an **existing lossy JPEG** into a standards-conformant JPEG XL container and reconstruct the **identical original JPEG bytes** from that JXL alone. Both operations run inside SwiftJXL, accept/return owned in-memory compressed data and retain intermediate coefficients/reconstruction metadata in memory. No temporary uncompressed image, intermediate file, external codec executable, sibling SwiftJLI dependency or optional umbrella is required.

“Lossless” here refers to reversible preservation of the existing JPEG bitstream. It does not restore pixels discarded when that JPEG was originally encoded. JPEG → RGB pixels → JPEG XL cannot establish original-JPEG byte reconstruction, even when the JXL pixel encoder is lossless. Arbitrary JXL files without valid JPEG reconstruction data cannot satisfy the reverse operation. JPEG → JXL → JPEG must be byte-identical; JXL → JPEG → JXL need not reproduce the original JXL bytes.

## Verified predecessor implementation

Reviewed [JXLSwift at 760697a54dd253da8e8466c3fd09ecf2c2d89aec](https://github.com/Raster-Lab/JXLSwift/tree/760697a54dd253da8e8466c3fd09ecf2c2d89aec), on 18 September 2026. **The implementation and tests exist.** This was a source inspection, not an executed build, codec test run or complete interoperability qualification.

| Source | Observed behaviour |
| --- | --- |
| [JXLEncoder.swift](https://github.com/Raster-Lab/JXLSwift/blob/760697a54dd253da8e8466c3fd09ecf2c2d89aec/Sources/JXLSwift/Codec/JXLEncoder.swift) | Public `encodeLosslessJPEG(_:)` takes Data, decodes quantised JPEG coefficients, invokes the coefficient bridge and builds a JXL container containing `jbrd` reconstruction data. |
| [JXLDecoder+LosslessJPEG.swift](https://github.com/Raster-Lab/JXLSwift/blob/760697a54dd253da8e8466c3fd09ecf2c2d89aec/Sources/JXLSwift/Codec/JXLDecoder+LosslessJPEG.swift) | Public `decodeLosslessJPEG(_:)` reads the JXL container, reconstruction metadata and coefficient bridge, then returns reconstructed JPEG Data. It does not require a source JPEG argument. |
| [PublicAPILosslessJPEGTests.swift](https://github.com/Raster-Lab/JXLSwift/blob/760697a54dd253da8e8466c3fd09ecf2c2d89aec/Tests/JXLSwiftTests/PublicAPILosslessJPEGTests.swift) | Uses plain `import JXLSwift`, calls both public methods and asserts byte equality for baseline colour/greyscale fixtures; also rejects a non-reconstruction JXL. Fixtures depend on a hard-coded cjpeg path and may skip. |
| [JPEGTests.swift](https://github.com/Raster-Lab/JXLSwift/blob/760697a54dd253da8e8466c3fd09ecf2c2d89aec/Tests/JXLSwiftTests/JPEGTests.swift) | Contains coefficient, reconstruction and independent-tool cases, including autonomous reverse tests for progressive, ICC, odd dimensions, restart/subsampling and greyscale inputs. Inspect each assertion and prerequisite; test presence is not a pass result. |
| [CLI Transcode.swift](https://github.com/Raster-Lab/JXLSwift/blob/760697a54dd253da8e8466c3fd09ecf2c2d89aec/Sources/JXLTool/Transcode.swift) | The `coefficient-bridge` branch calls public forward recompression; `reverse` first calls autonomous reconstruction. The default remains a pixel-fallback path, and reverse has an optional original-source fallback. Some comments/help still describe implemented paths as pending. |

### Limits that the coding agent must qualify

- Follow executable guards rather than stale comments. `encodeFromJPEGCoefficients` accepts 8-bit DCT baseline, extended-sequential and progressive frame kinds, with one or three components. Its nearby public-method comment still says baseline-only. This proves that those kinds reach the bridge, not that every variant is correctly supported end to end.
- The coefficient bridge rejects higher JPEG sample precision and non-DCT frame kinds. Do not infer 12/16-bit JPEG recompression, SOF3 predictive lossless-JPEG reconstruction, arithmetic coding or CMYK/YCCK support from the separate JPEG pixel decoder or the suite's general 16-bit Image contract. Explicitly test/reject them until independently implemented.
- [JBRDExtractor.swift](https://github.com/Raster-Lab/JXLSwift/blob/760697a54dd253da8e8466c3fd09ecf2c2d89aec/Sources/JXLSwift/JPEG/JBRDExtractor.swift) retains APP/COM/tail content but documents missing inter-marker/non-canonical-padding capture and sets canonical padding. Exact reconstruction must preserve such bytes or reject the input; normalising them silently cannot pass a byte-exact contract.
- [BrotliDecoder.swift](https://github.com/Raster-Lab/JXLSwift/blob/760697a54dd253da8e8466c3fd09ecf2c2d89aec/Sources/JXLSwift/Brotli/BrotliDecoder.swift) implements more than uncompressed payloads, but still throws for multiple block types or multiple trees. Wrapper comments overstate the restriction as all compressed metadata being unsupported. Build a precise metadata capability matrix, bounded decompression checks and negative tests; neither blanket full-Brotli nor uncompressed-only claims are justified.
- A reverse test that reads the original JPEG to fill missing coefficients/metadata is not autonomous reconstruction. Keep source-driven diagnostic tooling out of the successor's guaranteed reversible operation. Missing required oracle tools or unsupported fixtures must be visible as unexecuted coverage, never counted as passes.

## Implementation requirements

Reuse the native coefficient/reconstruction architecture after its baseline is reproduced and its gaps are understood. Preserve quantised DCT coefficients, quantisation tables and every reconstruction detail needed to recover the original marker/scan/entropy representation. Emit the standard JXL reconstruction/container machinery, including `jbrd` and required metadata. Do not invent a private archive or merely attach the complete original JPEG to an unrelated JXL image as a substitute for interoperable recompression.

Keep coefficients, compressed bytes and bounded reconstruction/Brotli metadata under owning lifetimes. No JPEG pixel decode, IDCT → RGB conversion or new lossy JPEG encode in the reversible path. Avoid redundant full-coefficient copies solely for adapter handoff; report necessary coefficient transformations/workspaces and compressed-data copies. Do not label this as pixel-buffer sharing when no pixel image was materialised. Enforce the common deadline, cancellation, memory and input limits across the entire operation, including reconstructed-output bytes and expanded metadata, before publishing success.

Exact reconstruction overrides ancillary metadata-discard conveniences: reject a discard request that would change the restored bytes. Preserve or reject noncanonical padding, fill bytes, repeated/unknown markers, APP/COM ordering, Exif/XMP/ICC/JUMBF, scan tables and trailing data. The reverse operation fails for absent, malformed, unsupported or inconsistent reconstruction data; it never falls back to re-encoding decoded pixels or consulting an original JPEG.

Use a safe output-size bound and checked counts/offsets throughout JPEG parsing, Huffman tables, JXL box lengths, coefficient allocation and Brotli expansion. Translate malformed input and unsupported features into the suite's distinct error categories; do not preserve the predecessor's broad use of “not implemented” for unrelated parse failures. Ensure errors/cancellation leave no successful partial result and no leaked owner or background work.

## Harmonised API and CLI

Expose the same native format-pair call shape as SwiftJ2K: local `Transcoder(configuration:)`, `transcode(_:to:options:) async throws` returning `EncodedImage`, and `capabilities`. Local `TranscodeTarget` cases are `jpegXL` and `jpeg`. JPEG → `jpegXL` selects reversible coefficient recompression; reconstruction-bearing JXL → `jpeg` selects autonomous original-byte restoration. The result identifies its actual output format and original-bitstream preservation contract. Use the common option names, resource/error/copy reporting and Swift 6.4 concurrency rules.

The predecessor's forward/reverse public entry points may remain explicit convenience wrappers if useful, but must delegate to the same qualified implementation and policies. Do not introduce a second divergent lifecycle or lossless meaning. The ordinary Image encode/decode API remains the route for pixel compression. No quality/distance setting or pixel-fallback default is permitted in the reversible operation.

Planned CLI examples, to be implemented and tested later:

```sh
swiftjxl-cli transcode -i source.jpg --input-format jpeg --output-format jxl --mode lossless -o recompressed.jxl
swiftjxl-cli transcode -i recompressed.jxl --input-format jxl --output-format jpeg --mode lossless -o restored.jpg
```

The output JXL is a reconstruction-bearing container. `--mode lossless` is the default for these native pairs and requires original-JPEG byte preservation. It must not select the predecessor's default pixel fallback. There is no `--source original.jpg` dependency in the reverse command. Support standard streams, bounded input/output and final-file atomic publication using the shared CLI rules; no intermediate file is created by either operation. Reject incompatible lossy/quality/discard flags.

## Acceptance and regression tests

1. Use licensed, hash-pinned JPEG fixtures and known synthetic generators. For each claimed feature, compare original and restored JPEG **length and every byte**, recording SHA-256. Pixel equality or visual similarity is insufficient. After generating the JXL, reconstruct in an independent invocation with only the JXL available; retain the original solely in the test comparator, outside the reconstruction operation.
2. Prove interoperability both ways: successor recompression → pinned independent JPEG reconstruction, and independent recompression → successor reconstruction. Independently decode the generated JXL image too. Pin actual tool options/version; restore to JPEG rather than accidentally comparing a pixel-output file. Development tools stay outside shipped dependencies.
3. Cover baseline, extended-sequential and progressive 8-bit DCT inputs as individually qualified; greyscale and supported subsampling, non-MCU-aligned sizes, multiple scans, restart intervals, quantisation/Huffman choices and nontrivial textured images. Test repeated JPEG → JXL → JPEG cycles for zero cumulative change to the JPEG bytes. Encoded JXL size need not always shrink.
4. Exercise metadata ordering, Exif/XMP/ICC/APP/COM content, repeated tables/markers, trailing/inter-marker bytes, noncanonical padding and Brotli variants. Every unsupported case rejects predictably. Include non-reconstruction JXL, raw codestreams, corrupted/missing/duplicate reconstruction boxes, malformed tables, truncated streams and decompression bombs. Do not silently normalise bytes to pass a parser.
5. Prove all work stays in memory during the library call, with no source-file lookup, external process or intermediate file. Account for coefficients, reconstruction payload, compressed input/output and copies. Test release by the caller, concurrent independent operations, cancellation and allocation limits at each stage. Known no-copy values require instrumentation, not a default zero statistic.
6. Retain plain-import public-consumer tests. Make ordinary contract tests run offline using retained permitted fixtures; configure independent-tool jobs explicitly rather than hard-coding `/opt/homebrew`. Missing required tools or old skipped cases are reported as coverage gaps and addressed before support claims.
7. Measure forward and reverse latency, peak memory, allocation/copy counts and output size separately on qualified platforms, including large metadata and cancellation. Apply the common performance/regression gates and do not import predecessor benchmark claims.

## Sequence and handover

Milestone 1 remains API/ownership feasibility. Inventory and reproduce the predecessor bridge baseline in Milestone 2. Add the qualified native reversible transcode integration in Milestone 3; broaden metadata/JPEG profiles and tune performance in Milestone 4. This complements the suite's first J2K → JPEG-LS shared-image proof and does not replace it. Record source provenance, an encode/reconstruct support matrix, actual tests and unavailable gates in the coding PR. This document authorises no implementation on its own.

Standards context: [JPEG's JPEG XL overview](https://jpeg.org/jpegxl/) describes restoration of the original JPEG, and [the libjxl encoder API](https://libjxl.readthedocs.io/en/latest/api_encoder.html) distinguishes JPEG coefficient recompression with reconstruction metadata from lossy pixel re-encoding. Use these as references; libjxl remains an independent test oracle, not a successor runtime dependency.

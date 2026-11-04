# Distribution notices and fixture provenance

SwiftJXL's in-house source and documentation use [Apache-2.0](LICENSE). Third-party code, embedded profiles and test assets retain their original terms. This index accompanies [NOTICE](NOTICE); it does not replace the licence texts or relicense any material.

The release-preparation baseline is SwiftJXL `3e00d93`, contract **0.10.0**. The migrated predecessor is JXLSwift `57e81cb9e2411d1efac435b429a306a031744c1e`; the earlier inspected `760697a54dd253da8e8466c3fd09ecf2c2d89aec` is historical context, not the selected migration source. The [path-level relocation record](Documentation/Engineering/Migration/relocated-sources.json), source headers and later migration records preserve that history. Their historical destination hashes are not rewritten to pretend they describe newer edits.

## Included implementation material

| Material | Retained terms | Provenance and distribution obligation |
| --- | --- | --- |
| Owner-authored SwiftJXL and relocated in-house JXLSwift implementation | Apache-2.0 | Preserve [LICENSE](LICENSE), [NOTICE](NOTICE) and original authorship. The owner-authorised relocation is recorded in [suite policy POL-07](Documentation/SUITE_POLICY.md). |
| JPEG XL algorithm adaptations and tables | BSD-3-Clause alongside the stated Apache-2.0 portions | Preserve [JPEG XL Project Authors' licence](Documentation/ThirdParty/libjxl-LICENSE.txt). Source SPDX headers identify the affected files, including JPEG reconstruction, ICC, Modular and VarDCT code and numerical tables. The reference revision used by migration is `a7a9c787341cf703dede03c2009fa460cae5e5df` (libjxl 0.12.0). |
| Brotli dictionary, transforms, context tables and decoding adaptations | MIT alongside the stated Apache-2.0 portions | Preserve [Brotli Authors' licence](Documentation/ThirdParty/brotli-LICENSE.txt). See [native JPEG provenance](Documentation/Engineering/Migration/NATIVE_JPEG.md), including the context-table pin `028fb5a23661f123017c060daa546b55cf4bde29`. |

These are included source adaptations, not external codec runtime dependencies. Independent libjxl, libjpeg-turbo, Brotli and LittleCMS executables/libraries are development oracles or generators; their use does not make those tools part of the shipped package. A binary distribution must also carry the applicable notice texts. Platform SDKs and compiler runtime components require the separate build-artifact inventory.

## Test-resource collections

Fixtures are resources of `SwiftJXLCoreTests`, not the library target. A source archive includes them and their notices. Each row below links the existing generator/provenance records; the [release inventory](Documentation/Engineering/Release/fixture-inventory.json) maps every fixture/support file to its notice group, exact hash and retained hash evidence.

| Collection | Terms and provenance |
| --- | --- |
| JPEG and derived JBRD/coefficient vectors | Authored synthetic images, Apache-2.0. [JPEG manifest](Tests/SwiftJXLCoreTests/Fixtures/JPEG/manifest.json), [JBRD manifest](Tests/SwiftJXLCoreTests/Fixtures/JBRD/manifest.json) and [native JPEG record](Documentation/Engineering/Migration/NATIVE_JPEG.md). |
| JPEGBridge images | Authored synthetic images, Apache-2.0. [Bridge manifest](Tests/SwiftJXLCoreTests/Fixtures/JPEGBridge/manifest.json) and [RGB/edge manifest](Tests/SwiftJXLCoreTests/Fixtures/JPEGBridge/rgb-edge-manifest.json). |
| Generated ICC profiles | LittleCMS-generated profiles retain their embedded “No copyright, use freely” text. [Profile manifest](Tests/SwiftJXLCoreTests/Fixtures/JPEGBridge/icc-manifest.json) and [generator](Scripts/generate-icc-fixtures.py). This declaration is distinct from the Adobe profile in the official conformance collection. |
| JPEGExtended | Authored synthetic JPEG/sample vectors, Apache-2.0. [Per-case provenance](Tests/SwiftJXLCoreTests/Fixtures/JPEGExtended/manifest.json) and [generator](Scripts/TestSupport/jpeg-extended-fixtures.py); malformed-input fixtures intentionally remain invalid. |
| JPEGEvents | Authored entropy vectors, Apache-2.0, with a separate **CC0-1.0** declaration for `large-eob.jpg`/`.jbrd`. [Event manifest](Tests/SwiftJXLCoreTests/Fixtures/JPEGEvents/manifest.json) and [large-EOB notice](Tests/SwiftJXLCoreTests/Fixtures/JPEGEvents/large-eob.json). |
| Brotli | Authored vectors use Apache-2.0; dictionary-derived material retains MIT. Keep both notices for this collection. [Compressed-vector hashes](Tests/SwiftJXLCoreTests/Fixtures/Brotli/decoder.json), [dictionary/transform vectors](Tests/SwiftJXLCoreTests/Fixtures/Brotli/transforms.json), [framing vectors](Tests/SwiftJXLCoreTests/Fixtures/Brotli/framing.json) and [MIT text](Documentation/ThirdParty/brotli-LICENSE.txt). |
| Modular | Authored synthetic images and predecessor numeric comparisons, Apache-2.0. [RCT](Tests/SwiftJXLCoreTests/Fixtures/Modular/rct-manifest.json), [Squeeze](Tests/SwiftJXLCoreTests/Fixtures/Modular/squeeze-manifest.json), [decoder generator](Scripts/TestSupport/modular-decoder-fixtures.py), [alpha generator](Scripts/TestSupport/modular-alpha-fixtures.c), [ICC](Tests/SwiftJXLCoreTests/Fixtures/Modular/ICC/manifest.json), [transfer](Tests/SwiftJXLCoreTests/Fixtures/Modular/Transfer/manifest.json), [low precision](Tests/SwiftJXLCoreTests/Fixtures/Modular/LowPrecision/manifest.json), [effort](Tests/SwiftJXLCoreTests/Fixtures/Modular/Effort/provenance.json) and [parallel](Tests/SwiftJXLCoreTests/Fixtures/Modular/Parallel/provenance.json) records. |
| Synthetic VarDCT | Authored synthetic inputs and numerical outputs, Apache-2.0. [Base manifest](Tests/SwiftJXLCoreTests/Fixtures/VarDCT/manifest.json), [encoder manifest](Tests/SwiftJXLCoreTests/Fixtures/VarDCT/Encoder/manifest.json), [animation](Tests/SwiftJXLCoreTests/Fixtures/VarDCT/Animation/manifest.json), [grouped decoder](Documentation/Engineering/Migration/Evidence/VarDCT/GroupedDecoder/validation.json) and [grouped encoder](Documentation/Engineering/Migration/Evidence/VarDCT/GroupedEncoder/validation.json). Subdirectory manifests retain exact numerical profiles and oracle revisions. |
| Official VarDCT conformance grayscale | **Not Apache-2.0.** The grayscale source images are CC0; upstream permits reproduction of test bitstreams/reference images for testing, retains its BSD notice, and the original ICC includes its Adobe notice. Preserve [upstream source-licence record](Tests/SwiftJXLCoreTests/Fixtures/VarDCT/Conformance/SOURCE-LICENCES.md), [licence](Tests/SwiftJXLCoreTests/Fixtures/VarDCT/Conformance/LICENSE.txt), original ICC bytes and [pinned manifest](Tests/SwiftJXLCoreTests/Fixtures/VarDCT/Conformance/manifest.json). Only grayscale assets are included; the upstream list also describes assets absent from this repository. |

## Reproduce the distribution audit

```sh
python3 Scripts/audit-release-provenance.py --output /absolute/new/provenance.json
python3 Scripts/Tests/test_release_provenance.py
```

The audit refuses changed or unlisted fixtures, missing/changed retained licence texts, unknown source SPDX expressions and inconsistent evidence hashes. It produces per-file source and fixture hashes. It reads only this repository and writes only the requested new report; it neither regenerates fixtures nor fetches external material.

The initial inventory contains 995 fixture/support files: 959 hashes cross-reference existing manifest/validation JSON; 36 are explicitly pinned baseline snapshots. The latter are principally provenance documents and also include `JPEGExtended/malformed-out-of-range.invalid` and the three VarDCT encoder `*.f32` supplemental vectors. The audit reads each snapshot directly from the pinned Git object and fails if that object is unavailable. Shallow clones must fetch the pinned baseline before running it. Snapshot binding establishes retained bytes, not independent sample correctness. Existing tests and their qualification records remain the evidence for numerical behaviour. All 119 production Swift files carry recognised SPDX declarations at this baseline.

When adding or replacing a fixture, review its generator, source terms, semantic expectations and independent validation first, then deliberately update the inventory and its evidence reference. Do not regenerate the inventory merely to silence a mismatch. Historical engineering logs/archives, toolchain binaries and SDKs are outside this test-resource inventory; a whole-repository redistribution or binary release must account for its selected additional contents separately. This audit is a source/distribution inventory, **not** a schema-validated CycloneDX/SPDX build SBOM or a release-readiness pass.

# Bounded NRRD command profile

Implementation stage following validated PR #15 at `f8adb16c6649f6fd113d74696e794036fa73ca3c`, under contract 0.10.0. The format was pinned and reviewed before parser implementation. The commands are implemented and locally tested; hosted CI remains a separate qualification gate.

Official specification: [Teem NRRD format definition](https://teem.sourceforge.net/nrrd/format.html), retrieved 8 October 2026. Downloaded HTML is 89853 bytes with SHA-256 `43ca6102cc998e0191e225d7954278547d491e29b74a132b3118571d85a8b0d5`. Reviewed sections 1.1–1.4 (versions, ASCII, LF/CRLF, duplicate fields, ordering and axes) and section 5 (dimension, unsigned 16-bit type aliases, raw encoding and endian). The local specification snapshot is retained in work evidence; no third-party implementation is copied.

Accepted subset: attached NRRD0005; dimension 2; full-precision unsigned 16-bit samples; raw encoding; explicit little/big endian; x as fastest axis. Required fields are type, dimension, sizes, encoding and endian. Standard unsigned 16-bit aliases are accepted. Optional kinds must be `domain domain`. Dimension precedes per-axis fields. Comments are ignored as permitted by the specification. LF and CRLF headers are accepted. Duplicate fields, invalid sizes, truncation and surplus payload bytes reject. Header limits: 16 KiB total, 1024 bytes per line, 64 lines. Unknown fields, custom keys, detached data, compression, offsets and spatial/colour metadata reject without dereferencing anything.

The explicit CLI format selection defines this initial greyscale profile. Encoding assigns the existing scalar API's D65/sRGB/default-intent interpretation to the raw full-range samples; it makes no medical/spatial interpretation claim. Decoding must reject sub-16-bit declared precision or non-default required interpretation metadata that plain NRRD uint16 cannot represent. No silent precision widening or metadata discard. Encode/decode must preserve exact sample values, use memory admission and cancellation throughout, and keep binary stdout separate from optional JSON reports on stderr. Shell serialisation copies are not in-process shared-buffer guarantees.

Independent test oracle: [pynrrd 1.1.3](https://pynrrd.readthedocs.io/en/stable/) with NumPy 2.0.2 and typing_extensions 4.15.0 in a test-only environment. Preliminary 7 × 5 fixtures in both byte orders were generated and reread independently with explicit C index ordering. Successor interoperability was verified locally in both directions; see the evidence below. The oracle is not a shipped dependency.

Acceptance: independent NRRD generation → CLI encode → CLI decode → independent NRRD read, comparing every sample on asymmetric textured arrays; public/libjxl checks remain separate. Test both endian orders, stream pipelines, slow/broken pipes, Ctrl+C readiness, atomic output, malformed/huge headers and dimensions, duplicate/missing fields, detached references, metadata/precision rejection and aggregate resource limits. Update CLI help, capabilities, man page and migration mappings only when implemented and tested. Keep common contract files byte-identical.

## Executed evidence and remaining gates

Local macOS Swift 6.4 debug: **101 NRRD CLI checks** passed with pynrrd 1.1.3 / NumPy 2.0.2 and libjxl 0.12.0. These include successor encoding → independent djxl sample comparison, independent cjxl relative-intent encoding → successor decode → independent pynrrd sample comparison, and rejection of independently encoded perceptual-intent input. **96 NRRD checks** passed in each ASan and TSan build; **96 existing inspection/validation checks** also passed in each of debug/ASan/TSan. Fixtures cover 1 × 1, 512 × 1, 7 × 5 and 31 × 17, both byte orders, maximum sample values and an actual producer/consumer pipe. Unsupported metadata and lower precision reject; malformed/huge headers, size mismatches, reference fields, overwrite, aliases, low aggregate memory, deadlines, broken pipes and cancellation are exercised. The updated foundation/install/manual suite passed **97 process checks**, including manual lint/rendering and staged installation. No cases are skipped. Reports are under [Evidence/NRRD](Evidence/NRRD).

Commands (use new evidence directories):

```sh
python3 -m venv /new/oracle-env
/new/oracle-env/bin/python -m pip install --only-binary=:all: -r Scripts/nrrd-oracle-requirements.txt
swift run --package-path Examples/CLIValidationFixtures CLIValidationFixtures /new/fixtures
/new/oracle-env/bin/python Scripts/test-cli-nrrd.py --binary /built/swiftjxl-cli --fixtures /new/fixtures --output /new/nrrd-checks --reference-tools /path/to/libjxl-0.12-tools
python3 Scripts/test-cli-payload.py --binary /built/swiftjxl-cli --fixtures /new/fixtures --output /new/inspection-checks
python3 Scripts/test-cli.py --binary /built/swiftjxl-cli --output /new/foundation-checks
```

Omit `--reference-tools` only in matrix/sanitizer jobs where the separate mandatory reference job supplies that coverage. The flag requires tools and their version; missing reference tools cannot silently pass. Local sanitizer binaries were incremental SwiftBuild builds with `--sanitize address` / `--sanitize thread`, workspace cache paths and two jobs. Reports preserve exact script/binary hashes, process arguments, statuses and dependency versions. The library/codec implementation is unchanged from the green base, so local testing focused on new parsing/borrow/I/O boundaries and existing CLI regression; hosted CI retains the complete library/consumer/oracle gates.

The new `PayloadOwner` retains immutable Data and exposes only a synchronous rebased sample borrow; pointers never become asynchronous owners. Decoder output borrows each row for final publication without a serialisation image array. Existing aggregate admission reserves input growth and command/header scratch before the public codec budget. This is a source-level allocation/lifetime argument verified under sanitizers, not a measured peak-RSS or throughput claim. Large-scale fuzzing, broader feature coverage, platform adapters and controlled release performance remain migration gates.

CI now runs NRRD checks across Linux Swift 6.2/6.4 x86/ARM debug/release, macOS debug/ASan/TSan, and pinned libjxl debug/release. Python 3.12 is selected on hosted macOS for the pinned test-only NumPy wheel. The standard/third-party algorithms remain external test evidence; no runtime dependency or codec subsystem is copied in this stage. No shared contract document, version, stable tag or production configuration changes.

Hosted validation completed successfully at `3f9a981671f0c3d1b95c75258e38341d571d321a`: all eight jobs in [run 37886167431](https://github.com/raster-labs/SwiftJXL/actions/runs/37886167431), including macOS 26 / Swift 6.2, the four Linux matrix jobs, independent consumer, contract identity and pinned libjxl interoperability. [PR #16](https://github.com/raster-labs/SwiftJXL/pull/16) remains unmerged.

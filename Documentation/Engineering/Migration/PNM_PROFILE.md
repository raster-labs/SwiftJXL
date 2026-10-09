# Integer colour CLI migration

This development stage adapts the PGM/PPM/PAM direction of `Sources/JXLTool/PNM.swift` at JXLSwift `57e81cb9e2411d1efac435b429a306a031744c1e` to contract 0.10.0. The new bounded parser and serialiser use the successor's owning image API. JXLSwift source and production are unchanged.

## Interpretation and supported profile

The [PPM](https://netpbm.sourceforge.net/doc/ppm.html), [PGM](https://netpbm.sourceforge.net/doc/pgm.html) and [PAM](https://netpbm.sourceforge.net/doc/pam.html) specifications define BT.709 colour samples for this profile. `--input-format pnm` and `--output-format pnm` preserve that transfer. The explicit `pnm-srgb` variant preserves sRGB; it performs no conversion. Required public metadata `jpegXL.transferFunction` carries one byte: 1 for BT.709, 13 for sRGB; absence means sRGB. Decode emits the non-default BT.709 entry. Required transfer and rendering intent survive `discardAncillary`.

Accepted files contain one binary P5 greyscale, P6 RGB or P7 PAM image. Precision is 8–16 bits with MAXVAL equal to `2^bits-1`; 16-bit storage is big endian. PAM requires a matching GRAYSCALE, GRAYSCALE_ALPHA, RGB or RGB_ALPHA tuple. Alpha is straight; ICC, premultiplied alpha, unsupported metadata, arbitrary MAXVAL, extra frames and rescaling reject. Both dimensions are at most 1024, under the existing CLI input and aggregate memory limits. The header is at most 16384 bytes; PAM has at most 64 lines of at most 1024 bytes. P5/P6 numeric tokens have at most 64 bytes. The exact raster delimiter preserves a leading whitespace or `#` sample.

The actual pinned predecessor parser was compiled with a small probe. It labels standard PPM as sRGB (independent libjxl reports transfer 13), accepts an unsupported CMYK tuple as RGBA, and rejects a valid pre-width comment. The successor regression suite covers these cases and independently verifies transfer, precision, alpha and sample equality.

## Ownership, bounds and evidence

Import retains the input Data owner and borrows its raster range directly. It does not create a packed full-frame adapter copy. Encoding retains the existing admitted Int32 algorithm planes. Export borrows decoded storage and serialises one row, at most 8192 bytes under the CLI profile, covered by the command overhead reservation. Atomic publication, cancellation and input limits reuse the existing CLI implementation. These bounds are not measurements of peak heap or RSS.

`ModularTransferTests` uses twelve independently encoded fixtures (four component layouts, 8/12/16 bits), including grouped width 513. It checks samples, required metadata preservation and invalid metadata/resource limits. `Scripts/test-cli-pnm.py` requires independent tools and exercises all supported precisions, both transfer variants, alpha, exact sample equality, malformed/truncated input, header limits and safe publication. The CI oracle job builds the header checker against its pinned libjxl target and runs debug/release CLI checks; libjxl remains test-only.

Commands, hashes, local configuration results and explicitly unexecuted gates are in [validation.json](Evidence/ModularColour/PNM/validation.json). Fixture provenance is in [the transfer manifest](../../../../Tests/SwiftJXLCoreTests/Fixtures/Modular/Transfer/manifest.json). This stage does not close predecessor performance regressions, full fuzz/platform qualification, ICC/float/general extras/animation/VarDCT pixel migration or release gates.

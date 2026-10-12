# Separate float-oracle diagnosis (2026-10-12)

This is diagnostic evidence, not replacement acceptance criteria. The original integer-output comparison remains `successor-epf/oracle-results.json`, with maximum 2 LSB / RMS 0.5 and exact alpha unchanged. Only 10 of 16 independently encoded DCT8 inputs pass that comparison; all 16 predecessor mixed-strategy streams remain rejected before reconstruction.

Reference: libjxl 0.12.0, source `a7a9c787341cf703dede03c2009fa460cae5e5df`, Homebrew test-only library. `libjxl-stage-write.cc` lines 264–280 applies ordered blue-noise dithering when writing UINT8. The normal Swift probe rounds positive, clamped sRGB output to nearest integer without dithering. The raw integer oracle therefore includes an additional quantisation operation absent from the probe.

A separate C oracle (`pixel-oracle-float.c`) requests `JXL_TYPE_FLOAT` with the same explicit sRGB colour encoding. Its raw Float32 outputs are retained as `successor-epf/*.float-oracle`. Python diagnostics clamp each sample to 0...1, scale by `(1 << bits) - 1`, and use positive round-half-up (`int(scaled + 0.5)`). This is a distinct conversion path, never an overwrite of the integer oracle.

Results in `successor-epf/float-oracle-results.json`: all 17×9 8-bit colour samples are exact with this conversion; 64×64 8-bit RMS errors range 0.015625...0.033754, maximum 1. The 16-bit RGB/RGBA discrepancy remains (maximum 14; RMS approximately 0.77). Thus UINT8 dithering explains the two 8-bit RMS failures but does not explain or resolve the substantive 16-bit issue. Original corpus, failures, thresholds and public capability restrictions remain intact.

## 16-bit coefficient-bias isolation

Pinned `quantizer-inl.h` lines 62–64 computes `quant - 0.145 * ApproximateReciprocal(quant)` and explicitly documents extra approximation error. A temporary diagnostic changed only our coefficient-bias inverse to the ARM `vrecpeq_f32` values for magnitudes 2...256 (larger values retained exact division). This is captured in `reconstruction-reciprocal-diagnostic.swift`; the temporary lookup table was removed from repository source after the experiment.

With the temporary approximation, all eight independent 16-bit inputs have maximum error 0...1 LSB / RMS 0...0.169 against the original Float32 sRGB oracle, with identical explicit nearest conversion. The earlier 14-LSB error therefore comes from the reference hardware reciprocal approximation in coefficient bias, not lost bit depth or a proven transform error. Results and pixels are retained in `successor-reciprocal/`. The original exact-division result remains in `successor-epf/`.

A separate `hwy::SetSupportedTargetsForTest(HWY_SCALAR)` experiment did not change output: the installed library contains NEON and NEON_BF16 implementations, with no compiled scalar fallback. It is not evidence of a scalar oracle passing. Building the pinned reference with a scalar target and full-precision filters is the next diagnostic; original NEON comparison and thresholds remain separately recorded.

## Subsequent scalar numerical qualification

The pinned scalar-only reference build and mixed reconstruction now complete all 32 retained inputs within the separately declared scalar limits. `JXL_HIGH_PRECISION` already defaults to one upstream; selecting Highway scalar is what replaces approximate NEON reciprocal arithmetic with exact scalar division in coefficient bias. The latest `validation.json` records full debug and affected sanitizer results. Original ARM integer failures remain separate, and official/public interoperability is still open.

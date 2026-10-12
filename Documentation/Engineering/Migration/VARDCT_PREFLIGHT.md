# VarDCT pixel migration preflight

This stage is in progress on `codex/swiftjxl-vardct-pixels`, based on PR #18 at `bfd12bc`. It does not yet enable public VarDCT pixel decoding or encoding. The pinned predecessor is JXLSwift `57e81cb9e2411d1efac435b429a306a031744c1e`; contract 0.10.0 applies. Predecessor source and production remain unchanged.

## Executed baseline

The public predecessor encoder and decoder accepted all sixteen synthetic combinations of greyscale, greyscale+alpha, RGB and RGBA; 8/16-bit samples; and 17×9/64×64 geometry at distance 1, effort 3. Independent libjxl 0.12.0 (`a7a9c787341cf703dede03c2009fa460cae5e5df`) decoded all files. Alpha matched exactly. Acceptance alone did not establish colour fidelity: only six cases met the predeclared same-stream decode limits (maximum two integer sample levels and RMS 0.5, in encoded sRGB). The 17×9 16-bit cases differed by up to 2,640 levels. These are decoder comparisons against the same compressed input, not an expectation of lossless lossy compression.

The predecessor also accepted sixteen independently encoded libjxl files; ten met those same numerical limits. The other cases remain recorded failures, including small RMS excesses, rather than being silently excluded. [Raw results and acceptance criteria](Evidence/VarDCT) and the [synthetic fixture manifest](../../../Tests/SwiftJXLCoreTests/Fixtures/VarDCT/manifest.json) retain exact geometry, source hashes and oracle outputs.

An isolated diagnostic copy of the predecessor decoder filters the visible rectangle before restoring its padded layout. All sixteen encoded files remained byte-identical. This change removed the large right/bottom-edge discrepancies: twelve cases then met the original limits. Four RGB/RGBA 16-bit cases still exceeded the limits. Disabling Gaborish also removed the large edge errors, corroborating the boundary diagnosis. The diagnostic is evidence, not a production patch or complete pixel qualification.

## Adapted primitives

`ScaledDCT` implements the scaled forward/inverse transform with DC equal to the mean, for power-of-two axes 2–64, including rectangles. Thirty-six vectors compare the actual pinned predecessor Accelerate and scalar implementations. Independent Double-precision cosine evaluation exposed three inherited inverse-transform errors: 64×64 constant/pattern inputs and one 32×16 pattern. Double angles and accumulation correct these errors without widening the predeclared tolerance (absolute 0.0002 plus relative 0.00002). Float matrices, samples and intermediate planes remain explicit.

The plan retains its operation budget. Matrix allocation is admitted before construction; each application admits its own two scratch/output buffers cumulatively. Invalid dimensions, wrong sample counts, non-finite values, floating-point overflow, cancellation and exhausted resources throw. No unbounded global matrix cache or escaped pointer is introduced.

`Gaborish` accepts visible width/height separately from storage stride, honours explicit weights and produces a tight plane. Tests include 1×1 and odd dimensions with NaN padding, so any accidental padding read fails. It checks geometry, allocation admission and bounded cancellation points. `DefaultOpsin` supplies default-matrix linear-RGB/XYB maths with Double intermediates, high-precision anchors and invalid-input rejection. This does not implement a colour-management engine or custom opsin parameters.

## Executed primitive validation

The full debug suite passed 192 declarations / 721 cases. The affected VarDCT suite passed 10 declarations / 23 cases under each of AddressSanitizer and ThreadSanitizer, with no failures or skips. Tests cover numerical references, budget admission and cumulative exhaustion, cancellation, concurrent plan use and invalid inputs. [Exact commands, log hashes and source hashes](Evidence/VarDCT/primitive-validation.json) scope this evidence to the internal primitives.

## Remaining integration gates

The primitive checkpoint originally left frame/global metadata, entropy, dequantisation, restoration and output integration open. The internal integration below now covers its stated default profile. Custom parameters, public owning destination publication and encoder settings still need qualified integration. The sixteen-case baseline is a starting corpus, not coverage of every predecessor strategy, large image or animation.

Public capability declarations remain unchanged until the complete pixel path passes independent interoperability, fidelity, storage, cancellation and malformed-input checks. Controlled release performance measurements remain unexecuted for this pixel integration. Primitive correctness is not evidence of complete migration, release readiness or a production cutover.

## Internal pixel integration (in progress)

The bounded reader now parses all 32 retained predecessor/independent streams, including containers and extra-channel context. Generic coefficient scans, strategy coverage, default quantisation, DCT transforms through 64×64, small transforms, AFV, Gaborish and default EPF reconstruct all 32. Alpha is exact. This is internal algorithm-plane reconstruction; public VarDCT encode/decode capabilities remain disabled.

The original installed ARM libjxl integer comparison meets its unchanged maximum-two-level/RMS-0.5 limits in 22/32 cases. Its ten failures remain visible. Two distinct reference operations explain observed differences: UINT8 output adds ordered dithering, and coefficient bias uses an approximate ARM reciprocal. A temporary reciprocal-only diagnostic reduced all eight independent 16-bit cases to maximum 0–1 level/RMS ≤0.169; that hardware lookup was discarded from production source. Exact scalar arithmetic remains in Swift.

A separate build of the same pinned libjxl source uses `HWY_COMPILE_ONLY_SCALAR` and `JXL_HIGH_PRECISION=1`, emits Float32 sRGB, then explicitly rounds to the original integer precision. All 32 cases meet the same numerical limits against that separate oracle (maximum one level, RMS ≤0.172), with exact alpha. This establishes scalar algorithm agreement, **not** a reclassification of the ten original integer-oracle failures or completion of the interoperability gate. The [separate results and diagnosis](Evidence/VarDCT/PixelIntegration) preserve both paths. Fixture manifests record raw output hashes, conversion rules and the independent small-transform basis source.

The internal output writer now writes directly into validated, exclusively borrowed planar or interleaved 8/16-bit component storage. Explicit endian, row/pixel stride and padding are preserved; alpha remains exact. It rejects associated alpha, invalid/short destinations and cancellation before writes. The caller must discard or poison the destination on failure; public owner publication/report integration remains pending.

Full debug passed 207 declarations / 805 cases; affected AddressSanitizer and ThreadSanitizer each passed 25 declarations / 107 cases, without skips. This includes 585 independently generated small-transform impulse/pattern vectors and 32 scalar-reference frame decodes. Exact commands, source hashes and logs are in [integration validation](Evidence/VarDCT/PixelIntegration/validation.json), with [adaptation provenance](Evidence/VarDCT/PixelIntegration/provenance.json).

The official libjxl conformance corpus pinned by its CI (`4bf053529c7cefd2951be453475bb3dccc7e7be8`) contains 39 streams; none is within the current narrow envelope. This is **not** a conformance pass. The closest grayscale/grayscale_5 streams embed ICC and are accepted by the pinned predecessor, while bike/bike_5 use BT.709 and multiple DC groups and the predecessor rejects both with `paletteRangeInvalid`. The preserved descriptors specify per-channel RMS/peak limits; these are distinct from the synthetic integer limits and must not be inferred from them. [Inventory and baseline](Evidence/VarDCT/PixelIntegration/conformance-inventory.json) record the gap.

Public output publication and fidelity/resource reporting, encode integration, larger/grouped/extended profiles, extended malformed-input/fuzz qualification, controlled performance and platform checks remain open. Public VarDCT stays disabled.

## Bounded ICC metadata and official grayscale numerical check

A subsequent internal envelope extension reuses the existing bounded ICC decoder and validates the profile header and colour model. It retains the original profile under explicit profile/metadata ceilings. The original `Dot Gain 10%` grey profile is preserved byte-for-byte in the two official `grayscale` and `grayscale_5` cases. Their XYB reconstruction is compared in the official **linear-grey Float32** reference domain: RMS 0.0000078255 / peak 0.00022822, within prescribed RMS 0.0001 / peak 0.004. These are two scoped numerical checks, not a complete corpus or public API conformance claim.

The integer destination writer explicitly rejects ICC input; emitting sRGB integers while preserving a different profile would silently change interpretation. Public colour-management/output policy remains open. A diagnostic maps the predecessor’s UInt8 sRGB output back to linear grey and exceeds the official Float32 thresholds; this includes integer quantisation and is not used as a new acceptance threshold.

The expanded affected debug suite passed 27 declarations / 110 cases. ICC-specific ASan and TSan each passed 2 declarations / 3 cases, without skips. [Exact evidence](Evidence/VarDCT/ICC/validation.json) and [official fixture provenance](../../../Tests/SwiftJXLCoreTests/Fixtures/VarDCT/Conformance/manifest.json) retain prescribed descriptors, reference hashes, original profile and licence notices. The earlier 39-stream unsupported inventory is a historical pre-extension snapshot.

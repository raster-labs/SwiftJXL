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

Frame/global metadata, entropy and coefficient reconstruction, dequantisation and strategy dispatch must feed these primitives through admitted operation storage. EPF, custom parameters, alpha, colour transfer, owning destination publication and encoder settings need their own qualified integration. The sixteen-case baseline is a starting corpus, not coverage of every predecessor strategy, large image or animation.

Public capability declarations remain unchanged until the complete pixel path passes independent interoperability, fidelity, storage, cancellation and malformed-input checks. Controlled performance measurements must wait for the separate active mutation campaigns to finish. Primitive correctness is not evidence of complete migration, release readiness or a production cutover.

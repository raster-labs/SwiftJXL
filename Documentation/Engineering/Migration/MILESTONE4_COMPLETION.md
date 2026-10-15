# Milestone 4 completion plan and evidence

This record applies to checkpoint `540a0b1`. The subsequent owner-requested
[remaining-work follow-up](MILESTONE4_REMAINING.md) has separate source and
validation evidence; the results here do not qualify those later changes.

Contract: **0.10.0**. Pinned predecessor: **57e81cb9e2411d1efac435b429a306a031744c1e**.
Starting main: **cce875c1620b5ca40971ee9fff5f02ab0ba42d58** (PR31, merged by the owner).

The owner requires implementation of the complete Milestone 4 plan before final
validation begins, followed by commit and feature-branch push for GitHub CI.
The owner will initiate the merge after CI passes. No release, tag, production
cutover or downstream application edits are part of this task.

## Implementation checklist

| Work | Implementation | Final validation |
| --- | --- | --- |
| Modular precision/layout/colour/alpha | 432 semantic combinations; both layouts/endians, explicit intent/transfer and alpha association | Passed local checks; final record below |
| Two-dimensional/DC group edges | 15 large profiles including 4097-square; worker determinism, independent encoder/decoder and 4 default-budget refusals | Passed local checks; final record below |
| Explicit pixel-container output | `CodecOptions.container`: raw default or basic ISO; still/animation, compressed-copy and resource accounting | Passed local checks; final record below |
| JPEG pixel convenience | Explicit sRGB, bounded 8-bit Huffman DCT grey/RGB; owning/caller layouts, cancellation, metadata and resource checks | Passed local checks; final record below |
| CLI animation | Multiple named inputs, timed singleton, rational clock/loops, selected/all-frame decode, inspect/validate and protected publication | Passed local checks; final record below |
| CLI capability/help/manual | Container, JPEG pixel and animation bounds; correct grouped VarDCT description and generic pixel inspection label | Passed local checks; final record below |
| Apple runtime coverage | Four-platform runner and 14-check ownership/cancellation/Watch/container/JPEG probe | 10 final-source SDK builds and four 14-check simulator runs passed |
| Independent and sanitizer runners | Required profile/animation reference tools, mandatory CLI/reference script, optimised complete sanitizer suite, pinned CI reference build | Passed local checks; final record below |
| Feature/provenance reconciliation | Explicit profile distinctions and existing deferrals below; exact source and fixture manifests accompany evidence | Final source hashes and profile dispositions recorded |

Implementation was prepared at 12:25:56 UTC on 14 October 2026; final validation
started at 12:27:03 UTC. The table records the subsequently executed final-source
checks. Earlier PR31 evidence retains its original source identity.

## Executed local validation

- Debug: 325 declarations, no failures/errors. The first full invocation skipped
  four optional oracle declarations; all four then passed with reference tools
  enabled on the same source/binary. There are no unresolved oracle skips.
- Release, AddressSanitizer and ThreadSanitizer: each completed all 325
  declarations and 1,612 parameterised invocations with no failures/errors/skips.
  The 541-case Modular subset includes 432 exact sample/interpretation oracles,
  15 independently encoded group profiles and 89 independent decodes in each run.
- All eight established CLI groups passed. The new 26-group JPEG/container/
  animation reference script passed under debug, release, ASan and TSan.
  Foundation capability assertions and manual line wrapping were corrected;
  the original failed attempts remain in the evidence.
- Ten Apple SDK targets compiled. iOS/tvOS/visionOS 26.5 and watchOS 26.0 each
  passed 14 runtime checks. All four disposable devices were shut down/deleted.
- All seven shared contract hashes match. No runtime dependency was introduced.

The [validation manifest](Evidence/Milestone4Completion/validation.json) records
exact commands, source hashes, counts, resolved attempts and limits. Compressed
raw test logs/XML are alongside it. The [feature audit](Evidence/Milestone4Completion/feature-audit.json),
[security scope](Evidence/Milestone4Completion/security-scope.json) and
[fixture provenance](Evidence/Milestone4Completion/fixture-provenance.json) keep
unqualified capabilities and historical evidence separate from current passes.

## Controlled performance result and disposition

The [performance record](Evidence/Milestone4Completion/performance.json) retains
48 predecessor rows (37 eligible paired comparisons, 11 candidate-only rows),
14 targeted paired PR31 comparisons, encoded sizes and rate-distortion.
The [compressed raw record](Evidence/Milestone4Completion/performance-raw.json.gz)
retains every timing sample, p95/spread, throughput, RSS and sampled heap endpoint.
Each process has five warm-ups and ten timed iterations; two interleaved
processes per implementation give 20 timed samples per round. Threshold
triggers repeat in reverse order. All recorded thermal states were nominal.
The host was Apple M4, 16 GiB, Swift 6.4, on AC power.

The 14 PR31 comparisons have no >5% latency/RSS trigger. Observed latency
changes range from -4.94% to +3.67%; these small differences are not presented
as speedups. All 22 checked default pixel/native streams match PR31 bytes.
The new JPEG pixel route passes its independent natural-image tolerance;
predecessor progressive-JPEG failures are excluded from ratios.

Against JXLSwift, 21 paired rows retain latency increases above 5%, and four
retain RSS increases above 5%, on both rounds. Three separate sampled profiles
identify residual/predictor/ANS work and scaled/hierarchical transform analysis
as optimisation targets. These kernel files are unchanged from PR31; the
profiles do not isolate the complete cause of every predecessor gap. Eight-bit
allocating JPEG XL decode rows also include the successor's UInt16 output
storage versus predecessor UInt8 storage. Treat them as public-API migration
costs, with that physical-layout difference explicit.

The 2048-square flat UInt16 lossless output is 367 bytes versus 363 (+1.1019%):
the retained investigation identifies the four-byte terminal ANS state in the
empty global pixel stream. The native benchmark's initial hash-seed mismatch
was reproduced and corrected in setup before its timings; pixel measurements
were retained. These investigations do **not** waive stable performance/size
acceptance. Exact workspace peaks and leak freedom are not inferred from RSS.


## Profile and predecessor dispositions

The assigned milestone extends the bounded profiles already implemented; it is
not a claim of arbitrary JPEG XL or JPEG conformance. Modular remains public
effort **3** by the continuation constraint. The internal 1–9 qualification does
not expose a new public effort control. Existing explicit signed/float and
advanced CLI/duplicate-executable deferrals in `IMPLEMENTATION.md` and
`MIGRATION.md` remain unchanged.

The predecessor's basic container option and independent-frame CLI operations
are adapted here. The new JPEG pixel path restores its 8-bit DCT convenience
route with owning storage and explicit colour interpretation. Its wider 12-bit
and SOF3 pixel envelope is **not implemented**; native JPEG byte reconstruction
also remains separately restricted to its documented 8-bit DCT profile.

Source inventory does not establish complete preservation of predecessor
orientation, arbitrary colour tags, extra channels, progressive options,
custom restoration or multi-pass VarDCT: several parsed or declared values have
no corresponding preserving output path. These remain explicit unsupported
successor profiles, not silently accepted new deferrals. ICC pixel encoding
was also explicitly rejected by the pinned predecessor. Advanced compositing
has no demonstrated complete predecessor implementation. The capability audit
retains exact anchors and hashes, including these limitations.

Optional acceleration requires a measured benefit and retained scalar path;
adding a GPU or SIMD backend is not itself a mandatory exit condition. Consumer
adoption/versioned release is Milestone 5 and remains separate.

## Validation sequence after implementation

1. Review all implementation changes, public surfaces, unsafe borrows,
   cancellation, checked size accounting, output transactions and provenance.
2. Build/run full debug and release suites, CLI suites and required independent
   references. Run the 541-case Modular matrix with 432 metadata/sample oracles,
   15 independent group encodes and 89 independent decodes.
3. Run full affected address/thread sanitizer coverage in optimised builds;
   do not change assertions or ignore timed-out/failed historical attempts.
4. Refresh final-source Apple SDK builds and available iOS/tvOS/visionOS/watchOS
   simulator execution. Preserve existing user devices and remove only the
   disposable test devices.
5. With CPU-heavy tests stopped, run controlled optimised performance cases:
   five warm-ups, at least twenty timed iterations, interleaved predecessor and
   candidate, repeat regression triggers, retain source/oracle/binary hashes,
   rate-distortion and original-JPEG byte equality. Separate failed predecessor
   cases from valid comparisons. Investigate every confirmed threshold breach.
6. Record bounded mutation/cancellation/lifetime tests for new JPEG parsing and
   source-scoped reuse of older campaigns. Historical campaigns are not a fresh
   final-binary fuzz or leak-freedom claim.
7. Reconcile exact final results, document remaining external gates, commit,
   push and open the review request needed to run repository CI. Leave the merge
   to the owner.

Commands and raw outputs are retained with the final evidence manifest. Core
entry points are `Scripts/test-modular-completion.py` and
`Scripts/test-cli-completion.py`; missing independent tools fail these gates.
The CI workflow builds the pinned libjxl source with the test-only CMake hook.

## Gates that must not be silently converted into passes

- Native Intel and representative physical Apple hardware cannot be inferred
  from cross-compilation or simulator success. Available simulators have
  different OS revisions; Watch 26.0 supplies one deployment-floor runtime,
  not proof for every minimum-OS target.
- Hosted Swift 6.2/6.4 and Linux execution require the pushed CI run. A branch
  push or completed local build is not a CI result.
- Original ARM integer-oracle differences remain archived with unchanged
  maximum-2/RMS-0.5 thresholds. The separate scalar numerical reference does
  not silently waive hardware dithering/reciprocal differences.
- Initial-release TEST-05 one-hour campaigns for the added JPEG pixel inspect,
  allocating decode and caller-storage decode entry points remain outstanding.
  New deterministic mutation and sanitizer tests do not substitute for that gate.
- Process RSS and sampled heap endpoints do not measure exact global peak
  workspace, allocation count or leak freedom. Direct owner identity and
  controlled final-allocation counters prove only their declared handoff scope.
- A repeatable >5% latency/RSS or >1% lossless-size trigger requires investigation.
  A deliberate safety/correctness trade-off requires a recorded acceptance;
  implementation of a bounded profile is not permission to waive that gate.

JXLSwift remains the supported production route until the required qualification
and separately authorised consumer/release gates are satisfied.

## Extreme JPEG quantiser reference diagnosis

The retained `quant16.jpg` fixture multiplies quantisation entries by 257 while retaining the original entropy coefficients. Direct inverse-DCT values range approximately -35133 to 36202 before the 8-bit level shift. This is an adversarial saturation fixture, not a normally encoded photograph. The initial libjpeg floating-output comparison failed (maximum 255, RMS 176.036 LSB); that result is retained. The [pinned libjpeg source](https://github.com/libjpeg-turbo/libjpeg-turbo/blob/3.2.0/src/jdmaster.c#L362-L400) documents that its masked range-limit table can wrap for extreme inputs.

An independent libjpeg coefficient extraction followed by a direct 64-term double-precision T.81 A.3.3 calculation matches all 527 successor samples exactly. The pinned predecessor also matches exactly. The successor uses a separate separable IDCT implementation and saturating clamp; it is not changed to reproduce wrapped values. The mandatory test retains the libjpeg disagreement and requires exact direct-formula agreement for this hash-pinned stress fixture. All ordinary JPEG fixtures keep the declared maximum-2/RMS-0.75 criterion. This diagnosis does not modify the separate historical VarDCT ARM numerical gate.

# Resource admission audit — current scalar profile

This is an implementation checklist, not completed memory qualification. Public codec capabilities remain unavailable until the remaining admission and storage-proof requirements are implemented. Contract 0.10.0 TEST-06 and MEM-10–13 control acceptance.

## Implemented controls

`ScalarDecodePolicy` carries compressed-input, dimension, pixel-count, nesting and monotonic deadline limits. Smaller caller limits are respected; larger values cannot expand the initial qualified profile. Container iteration, entropy reads and prepared-frame writes check the operation deadline/cancellation. A cumulative entropy-table ceiling now admits codebooks before construction, including nested context maps; it is not total workspace accounting. Source and destination geometry use checked arithmetic and bounded dimensions. Existing canonical storage validates capacity, leases, sealing and invalidation.

## Allocation inventory requiring admission

| Path | Payloads to account for before allocation | Outstanding work |
| --- | --- | --- |
| Container extraction | Retained compressed input, complete-box copy or concatenated partials, temporary partial copies and box arrays | Charge extraction and growth against workspace and aggregate budgets |
| Bit reader | A contiguous byte-array copy of the codestream, retained alongside its Data | Admit the copy before constructing the reader |
| Metadata/frame parsing | Extra-channel arrays and names, frame names and pass fields | Reject unsupported profile branches before constructing their payloads where possible; account for remaining metadata |
| Prefix codebooks | Per-alphabet lengths and codewords, sorted symbol arrays and a lookup table up to 2^15 entries per histogram | Bound aggregate tables across all histograms and nested context maps, not only individual alphabet sizes |
| ANS/codebooks | Histogram arrays, alias tables and construction temporaries | Charge both retained and transient tables across nested parsing |
| Modular trees | Bounded node arrays, tree token state, global/local codebooks | Account for simultaneously retained global and local structures |
| Pixel decode | Weighted predictor row arrays and 16 properties; LZ77 history when enabled | Admit row/history workspace before writing; report workspace separately from final pixels |
| Pixel encode | Int32 working plane; gradient and weighted residual/symbol arrays; predictor rows; entropy candidates | Audit retained lifetimes and calculate a conservative admission bound for effort 3 |
| ANS encoding | Buffered token tuples, refill words, frequency/alias-inversion tables | Include these in the encoder bound, not merely its four-byte input working plane |
| Output assembly | Bit-writer backing buffers, section Data and final compressed Data | Bound growth before appending and enforce compressed-output and aggregate limits |

The observed Int32 input working plane is four bytes per sample. Each predictor candidate additionally creates UInt32 residuals and UInt16 symbols. These payload sizes alone are not a peak-memory measurement: table construction, output buffers, capacity growth, temporary copies and compiler-controlled lifetimes still matter. Do not label their sum as measured peak workspace.

## Next implementation sequence

1. Add checked operation accounting for retained input/destination, workspace and output, with explicit per-allocation admission. Keep conservative bounds distinct from measured peak usage.
2. Propagate encoder cancellation/deadline checks through residual calculation, entropy cost evaluation and emission; callbacks must remain outside storage locks.
3. Wire canonical public Encoder/Decoder only for the qualified unsigned greyscale profile. Preserve precision, reject unsupported required metadata/ICC/interpretation, map internal failures to stable errors, and report backend/fidelity accurately.
4. Prove shared storage with allocation/copy instrumentation in an ordinary build, exact encode-byte comparisons, destination writes and source audit. Existing address/identity tests are necessary but insufficient.
5. Extend profiles and native JPEG reconstruction with their separate oracle, metadata, performance, fuzz and platform gates.

No downstream consumer or predecessor changes are needed for this audit. Merge, stable release and production cutover require their separate owner decisions.

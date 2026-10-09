# Resource admission — public integer Modular profile

Contract 0.10.0 MEM-10–13 and TEST-06 control this implementation. These are conservative operation reservations, **not measured allocator/RSS peaks**. Unknown report measurements remain `nil`. The encoder supports unsigned greyscale/RGB with optional same-precision alpha through 16384 per axis at effort 3, subject to caller limits. The general decoder admits 8–16-bit grey/RGB with optional alpha, dimensions through 16384 per axis, caller-defined compressed/pixel/memory ceilings, entropy tables at most 32 MiB per reader and nesting at most 32.

## Admission model

`ScalarOperationBudget` uses checked arithmetic and an operation-local mutex. Workspace charges accumulate without release, so temporary table lifetimes cannot hide retained allocations. Independent workspace, decoded, compressed and aggregate ceilings apply. Aggregate admission includes retained source/input capacity (including padding and retained metadata), destination capacity, workspace and compressed output. A caller destination is charged before parsing; allocating decode reserves pixel capacity after supported headers and geometry are validated, before allocating. Inspection creates no pixel planes. An externally supplied destination's full capacity replaces the packed reservation before writing.

| Decode allocation group | Reservation before allocation |
| --- | --- |
| Extraction, reader and container inventory | `6*C + 256*min(4096,C/8) + 65536`, where C is retained compressed input size. Six input lengths cover extracted/concatenated Data, growth overlap, partial payload copies and the reader's byte copy. The per-box term covers box/partial/sorted inventory; parser count is capped at 4096. |
| Final samples | `2*N*channels` for allocating decode, or the actual entire caller-provided capacity (including UInt8 destinations), under both decoded and aggregate ceilings. |
| Pixel predictor and LZ77 history | `12*N + 192*(width+2) + 1024`: three history payload lengths cover append growth overlap; predictor rows require 48 bytes per extended column, with remaining allowance for row-array rounding/properties. Charged per decoded channel/section before writes. |
| Global/local trees | For each tree, `limit*(3*MemoryLayout<ModularTreeNode>.stride+72)+4096`, limit ≤4096. Includes node growth and at most six UInt32 history tokens per node with growth overlap. Both trees are charged when present. |
| Entropy headers | `(contexts+1)*64+32768` for each header, including nested maps: maps, MTF/seen state, configuration vectors and context-stream history. Contexts ≤4096; at most 256 histograms. |
| Prefix/ANS tables | Existing cumulative table admission now also debits the operation workspace/aggregate ledger. Prefix alphabet ≤65536: `40*alphabet + 8*32768 + 4096`; ANS: 65536 bytes per histogram; histogram inventory: 128 bytes each. These allowances cover construction temporaries, retained tables and stream alias state. |
| Modular geometry and planes | Geometry descriptors are admitted before transform planning (at most 4096 channels, 256 transforms). Each allocated Int32 algorithm plane reserves `4*sampleCount+64`. Inverse RCT reserves possible COW; Squeeze and palette reserve their restored planes before allocation. Group rectangles use separately admitted bounded planes only when transforms require them. |
| Sections and transforms | TOC entries reserve 128 bytes each; every reader is bounded to its exact section. Group descriptor/rectangle arrays are admitted before creation. ANS stream alias state reserves 64 KiB per histogram per stream. |
| Unsupported payloads | Bounded extra-channel descriptors/names are admitted before parsing; unsupported semantics are rejected before pixel writes. ICC, non-default tone mapping, non-D65/sRGB transfer, animation and unsupported extras are rejected. Required rendering intent uses a bounded one-byte metadata value and counts against the metadata ceiling. |

The public decoder never calls the allocating `[Int32]` convenience decoder. Without global transforms it writes through `BorrowedModularChannel`, including independent group rectangles. Group-local transforms may require group Int32 workspace. Global transforms require signed Int32 algorithm planes (at least four bytes per transformed sample; inverse palette/Squeeze can overlap additional admitted planes); final reconstructed values are written from those planes into the caller's storage with no additional packed final-image allocation. Pointer lifetime stays inside the synchronous owner borrow. Reservations accumulate across groups and passes; they deliberately overestimate peak live workspace. Allocation-site audit counts controlled plane allocations, not allocator/RSS peaks. Operation report peak fields remain unknown (`nil`).

## General encoder envelope

The public encoder admits `N = width*height*channels` samples and `G = ceil(width/512)*ceil(height/512)` groups using checked arithmetic before allocating planes. Its compressed-output reservation is `B = min(6*N + 65536, maximumCompressedBytes)`. Workspace is conservatively `144*N + 192*(min(width,512)+2)*channels + 16384*G*channels + 6*B + 4194304`. This includes original Int32 planes, three RCT candidate planes, group rectangle scratch, both predictor/residual/symbol candidates, ANS pending/refill arrays, section/final buffers and capacity overlap. It is a cumulative admission bound, not measured peak RSS. The original narrow scalar internal entry remains available for baseline tests with its earlier envelope below.

The public path preserves rendering intent for both colour interpretations and alpha association. Grouped rANS streams emit a 32-bit terminal state even when their global pixel stream is empty. Source ingestion, RCT/cost passes and grouped residual rows include cancellation/deadline checkpoints.

## Encoder envelope

For N samples and width W, output bound B is `min(maximumCompressedBytes, 6*N + 65536)`. The operation reserves B compressed bytes plus workspace:

```
88*N + 192*(W+2) + 6*B + 4194304
```

The 88*N term is twice the payload sum of the Int32 working plane (4*N), both gradient/weighted residual-and-symbol candidates (12*N), buffered ANS tuples (24*N) and refill words (4*N). It allows capacity/transient overlap without pretending these lifetimes are precisely measured. The row term covers both weighted predictor lifetimes. The 4 MiB fixed allowance covers the bounded raw4 alphabets (≤256), two retained gates, prefix LUTs, Huffman construction, ANS distributions/inversions and small headers. Six output lengths cover section/final writer backing buffers, Data conversion and growth overlap. The token bound is at most 15 prefix bits plus 28 extra bits, or 16 ANS refill bits plus 28 extra bits; six bytes per sample plus the fixed header allowance therefore bounds this profile.

`BitWriter` admits growth before appending and clamps speculative capacity requests. Its nonthrowing bit API latches overflow; bounded throwing checkpoints and final publication propagate `resourceLimitExceeded`. Frame and outer Data appends are checked separately before growth. Source copies, prediction rows, entropy costing/emission and ANS reverse/forward work have cancellation/deadline checks. Scratch candidate failures cannot swallow the operation's latched limit/deadline failure.

Entropy emission checks cancellation, deadline and the overflow latch before the first token and at intervals of at most 256 tokens, including zero-bit prefix symbols. Prefix counters belong to each bit writer; ANS uses its pending-token count. ANS finalisation also checks before allocating refill storage. Output-byte admission remains per write, and public publication performs its final operation check. This replaces expensive per-token clock/task-local/lock calls without allowing unchecked output growth. Regression tests cancel or latch a failure immediately after the first zero-bit token and require rejection within the next 256 tokens.

This envelope is intentionally conservative and may reject an image whose actual allocator peak would fit. It covers this exact effort/profile only; a broader codec path must receive a new audit and admission model. Heap overhead/runtime allocations are not an exact process RSS guarantee.

## Storage evidence and telemetry

`ScalarStorageAudit` instruments actual final-pixel and algorithm-working-plane allocation sites, scoped per task. `ScalarMemoryTests.publicSharedStorageUsesOnlyTheRequiredFinalAllocation` checks zero final allocations for source encode/caller decode, exactly one for allocating decode, one 4*N encoder plane, shared owner identity, and exact encoded bytes after padded-storage decode. The source audit above establishes that no uninstrumented final-image handoff path enters the public operations. Public oracle tests additionally compare full codestream bytes with direct scalar encoding and verify public results through libjxl in both directions at 9, 10, 12, 14 and 16 bits.

`Examples/MemoryProbe` uses the public API in an ordinary, unsanitized build. Its process heap snapshots complement allocation-site instrumentation; they are neither peak-workspace measurements nor exact per-operation deltas. Never run this allocator probe under a sanitizer. The captured run at 256 × 256 observed 262720 → 410416 bytes around allocating decode, and 558272 → 558320 around caller-storage decode; the final image payload is 131072 bytes. These values are observations from one warmed local run, not portable thresholds.

Broader profiles, release performance qualification, long-duration fuzzing, platform adapters and native JPEG reconstruction remain separate migration/release gates. No merge, stable release or production cutover follows automatically from this scalar integration.

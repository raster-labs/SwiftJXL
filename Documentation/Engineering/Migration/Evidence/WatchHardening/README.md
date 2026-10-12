# Watch hardening qualification

The library fixes are in `257afcb` and `54a1d4d`; `1632246` changes only CLI capability/help text and its behavioural checks. No public library source changed after `54a1d4d`.

- Debug and optimised-build tests each passed 283 declarations/1,088 cases with no skips (`full-tests.json`).
- AddressSanitizer and ThreadSanitizer each passed 60 declarations/289 cases with no skips (`sanitizers.json`). The latter notes the subsequent CLI-only parent-source difference explicitly.
- All ten Apple library SDK targets passed; iOS/tvOS/visionOS 26.5 each passed nine runtime smoke checks. Watch arm64_32 and Intel macOS have compilation evidence, not native execution evidence. Temporary simulator devices were removed.
- Both CLI configurations passed 72 variants plus real 257-wide alpha preservation and 1025-wide rejection. The capability assertion failed on the old executable before the correction.
- Seven supplementary 600-second mutation campaigns passed after the Watch fixes. Two initial conformant-seed preflight attempts reached the unchanged 5-second API deadline during heavy concurrent work. Original and patched decoders both exhibited the resource rejection; all 73 seeds passed the later retries without changing limits, binary or corpus. Preserve those initial reports as well as the successful retries.

Historical one-hour mutation campaigns are retained separately under `../VarDCT/Mutations` and `../VarDCT/AnimationMutations`, with their original source revisions. These experiments are not coverage-guided fuzzing or security certification. No release, tag or production cutover follows from this evidence.

Exact commands, source/test/fixture/object/binary hashes, exit codes, raw logs, platform identities and scoped review findings are retained in the JSON records. `IntWidth.ll` shows the Watch compiler returning 32 for `Int.bitWidth`; it does not establish runtime testing on Watch.

# Modular fixture compiler compatibility — 14 October 2026

PR26 at `7a2d2d3` failed Swift 6.2 Linux compilation on both x86_64 and ARM64: the compiler could not type-check the grouped resource-limit test's compound `map` expression in reasonable time. Replace that expression with a loop and intermediate integer values. All 8,721 generated samples match the original Swift expression exactly; assertions and runtime sources are unchanged.

Focused debug and ThreadSanitizer each pass seven declarations / eleven argument cases on local Swift 6.4, with no failures or skips. All 178 other source/test hashes and the seven shared contract hashes are unchanged. Reuse the existing runtime oracle and performance evidence; this fixture-only change does not require new codec benchmarks. Hosted Swift 6.2 confirmation remains pending.

[Validation](validation.json) records exact commands, hashes and results. The [raw archive](raw-evidence.zip) contains both failed hosted job logs, the sample-equivalence probe and the local test commands/logs/XML. An initial obsolete local wrapper failed before tests because its earlier command file was absent; the successful wrapper reuses PR26's final command records.

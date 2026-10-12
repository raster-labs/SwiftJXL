Combined public VarDCT/header sanitiser qualification

ASan and TSan each passed 21 declarations / 130 cases, with no skips: five Core suites (20/128) and the public provider-finalisation cancellation test (1/2). This is selected affected-suite evidence, not full-suite or full interoperability qualification.

The frozen source includes root public API changes and the shared header refactor. All Sources still match the parent snapshot on completion. validation.json records exact source/test/fixture hashes, manifest selection, commands and log hashes. The retained scalar-oracle fixtures remain distinct from the unresolved original NEON comparison gate. No benchmark or external oracle process was run.

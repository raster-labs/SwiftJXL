# Modular candidate-limit evidence

`qualification.json` indexes the scoped results. `raw-evidence.zip` retains the exact build/test/probe commands, source and binary hashes, test logs/XML, raw timings, oracle checks and unsuccessful build attempts. Paths in archived scripts describe the original workspace and need adaptation on another machine. It excludes binaries, copied source trees and decoded images.

`baseline` is PR25 commit 7ec288c; `candidate` is this follow-up. `baseline-reuse.json` and `reused-oracle-report.json` identify earlier oracle data reused with source equivalence, without claiming a new baseline oracle run. `policy-regression.json` records the reproducible old fallback and corrected rejection. `validation-command-inputs` preserves the older command templates, not new test claims. Only final `limits-debug/release/asan/tsan` records establish the combined final source qualification; earlier compile/debug attempts remain diagnostic history.

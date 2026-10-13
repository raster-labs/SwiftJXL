# Retained Modular effort evidence

`qualification.json` is the readable index. `raw-evidence.zip` retains exact commands, source/binary hashes, raw samples, XML, logs, fixture-generation/build/measurement scripts, and the discarded decoder patch. Its paths are relative to the original `work/modular-effort` directory. Build metadata records the original absolute paths; adapt those paths when replaying elsewhere. The source fixtures and benchmark probe are retained in the repository.

Inside the archive, `baseline` means main 0a4abd3 and `candidate` means the retained effort-only implementation. `row-access` and `row-*` describe the reverted decoder experiment; their inherited `predecessor` key also means current main. `validation-command-inputs` preserves inputs used to construct the recorded test commands. Those inputs describe older runs and are not new qualification claims. The `prior-admission-audit.json` is a historical source audit; the current qualification index states what was addressed and what remains.

No compiled binary, copied source tree, decoded image or benchmark input image is archived. Commands and deterministic seeds reproduce them. Historical profiling and failed harness/cache attempts remain separate from accepted tests and controlled benchmarks. Only local macOS arm64 Swift 6.4 is qualified here; public effort remains 3.

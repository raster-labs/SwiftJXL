# CLI inspection and validation stage — 8 October 2026

## Scope and baseline

Owner-authorised next stage on `codex/swiftjxl-cli-validation`, based on public integration commit `0187ba28317ac6f990a8ab8698a7740f9db23fe6`, contract **0.10.0**, predecessor pin `57e81cb9e2411d1efac435b429a306a031744c1e`. This branch depends on PR #14; its unchanged head passed macOS on CI attempt 3, closing that PR’s eight-job CI gate. No main merge, release, production switch or predecessor modification is authorised by this stage.

`inspect` now reads bounded file/pipe input through `Decoder.inspect`; it does not claim pixel integrity. `validate` decodes the complete supported scalar frame through `Decoder.decode` and discards the in-memory pixels. Both report geometry/bit depth/profile, with an explicit JSON `pixelPayloadValidated` flag. Encoding/decoding file adapters, the standard image stream adapter and native JPEG reconstruction remain deferred. This is not full JPEG XL validation or completion of the entire migration.

## Provenance and implementation

The pinned predecessor's `Sources/JXLTool/Info.swift` was reviewed: its `info` command loads a whole file and reports broader container/JPEG/frame metadata through predecessor APIs. That command and its ArgumentParser dependency were not copied. The successor's command I/O, parser integration, report publication and tests are new Apache-2.0 implementation against the already-migrated public API. No additional codec algorithm source was relocated; `relocated-sources.json` and all seven shared contract documents remain unchanged. Predecessor support for arbitrary frame inspection or JPEG is not inferred for this command.

`Sources/SwiftJXLCLI/CommandIO.swift` bounds compressed input to 4 MiB, polls pipes at 25 ms intervals, checks cancellation/deadlines and publishes reports via a temporary sibling plus atomic link/rename. Existing output requires `--overwrite`; input aliases (including redirected stdin and hard links), symlinks and non-regular outputs reject. Failure leaves the prior report intact. Stdout cannot be rolled back after a partial write. POSIX pointer accesses stay within synchronous buffer borrows; no pointer escapes or unchecked concurrency annotation was introduced. The SIGINT callback is explicitly sendable and cancels the operation task.

Memory admission reserves 256 KiB for command/report/scratch overhead and conservative compressed-buffer growth, then passes the remaining budget to the public codec's aggregate accounting. `validate` uses the allocating decoder and never writes decoded pixels to disk. No pixel conversion, bit-depth reduction or metadata value logging is introduced. This is logical allocation admission, not a measured process RSS ceiling. One scalar worker is used; filesystem syscall latency remains controlled by the operating system. No codec hot path changed and no new throughput claim is made.

## Tests and reproduction

The fixtures are generated from a deterministic 7 × 5 sample formula by `Examples/CLIValidationFixtures`, using only public API calls. Two fixtures have 12/16 meaningful bits. A recorded single-bit mutation is selected for which header inspection succeeds but full decoding rejects malformed payload. There are no third-party/private input files. Fixture hashes and the mutation offset/mask are retained with the evidence.

```sh
swift run --package-path Examples/CLIValidationFixtures CLIValidationFixtures /new/fixtures
python3 Scripts/test-cli-payload.py --binary /built/swiftjxl-cli --fixtures /new/fixtures --output /new/payload-evidence
python3 Scripts/test-cli.py --binary /built/swiftjxl-cli --output /new/foundation-evidence
SWIFTJXL_ORACLE_BIN=/opt/homebrew/bin bash Scripts/validate.sh --checks debug,asan,tsan --jobs 2 --disable-package-sandbox --output /new/library-evidence
```

Local host: macOS / Xcode Swift 6.4, SwiftBuild, deployment floor 26.0. Sandbox-compatible builds use workspace cache/config/security paths. The qualification runner records complete command arrays, source hashes, toolchain versions and exit codes in `Evidence/CLI/library-report.json`. Final CLI builds additionally use each existing qualification scratch directory with `swift build --disable-sandbox --build-system swiftbuild --jobs 2`, plus `--sanitize address` or `--sanitize thread` as applicable. Final binary/script/fixture hashes are in each CLI report.

The first cancellation test exposed a signal-handler actor-isolation trap. An explicitly sendable callback fixed it; the process tests exercise Ctrl+C on both blocked input and blocked output. Final tests also cover malformed/truncated/oversized input, unsupported format/backend, invalid arguments, deadlines, low memory, quiet/verbose JSON separation, private paths, closed pipes, output aliasing and transaction cleanup. Failed exploratory runs remain in local work evidence; only final passing reports belong in the committed evidence directory.

The library qualification ran before two final CLI-only changes (rejecting excessive timeout values and detecting redirected-stdin output aliases). Library/codec source did not change afterward. Final CLI builds and process checks cover those changes in debug, ASan and TSan; the unchanged library qualification is not represented as a new run of the final CLI source.

## Validation boundary

Final local results: **96 payload process checks passed in each of debug, ASan and TSan** (288 invocations), plus **103 foundation/install/manual checks**. All exited 0. The unchanged library regression passed **59 declarations / 73 cases in each of debug, ASan and TSan**, with no failures or skips, including independent libjxl interoperability. The final manual also passed lint and staged installation/rendering. See committed evidence for command arrays, hashes, counts and exit statuses. GitHub CI now also runs payload process checks on the Swift 6.2/6.4 Linux x86/ARM debug/release matrix and macOS debug/ASan/TSan. Local release execution remains unexecuted. The first hosted macOS 26 / Swift 6.2 run passed all preceding checks but failed the cancellation test described below; the corrected test still requires hosted confirmation. PR #14's first two macOS attempts were cancelled before runner acquisition; attempt 3 passed at its unchanged head. Linux success and local macOS 6.4 checks do not substitute for the minimum-toolchain gate on this CLI branch. All required checks and explicit owner permission are required before main integration.

## Cancellation-test readiness correction

The first PR #15 CI run (`37762234971`, head `bf87fd3149c99d6d471100b2375b1dae3e5b8cfb`) passed all seven non-macOS jobs. Its macOS job acquired a runner and passed the build, library debug/ASan/TSan tests, foundation checks, and 96 debug / 96 ASan CLI checks. The TSan CLI test terminated with SIGINT (`-2`) during the stalled-input cancellation case instead of returning handled cancellation (`130`). No race-detector finding was reported in that failure.

The old harness sent SIGINT 0.2 seconds after process launch, without establishing that the CLI had installed its signal handler. The corrected harness enables existing verbose diagnostics and waits for the operation-start message on input cases or the report-ready message on blocked-output cases. The signal source is activated before the main task can emit these messages. Startup has a separate 10-second bound; the cancellation response must still complete within five seconds and return exactly 130. EOF before readiness and excessive diagnostics fail the test. Recorded readiness/response timings distinguish startup overhead from cancellation latency. No application or codec source, signal policy, exit expectation or required CI job is changed.

The controlled reproduction delays execution of the unchanged debug binary by 0.6 seconds: the old harness must fail with SIGINT termination; the corrected harness must pass all 96 cases. This establishes the timing defect independently of variable CI load; the precise startup timing of the original hosted failure was not captured. New reports are stored separately in `Evidence/CLI/Readiness`, preserving the original evidence. Hosted confirmation is required before closing the macOS gate.

Executed correction results: 96 cases passed in each unchanged debug/ASan/TSan binary with the revised harness. The controlled 0.6-second delayed-startup experiment reproduced the original SIGINT (-2) failure in the old harness and passed all 96 cases with the corrected harness. No codec rebuild or redundant library/oracle rerun was needed locally for this test-only change; hosted CI will validate the new head.

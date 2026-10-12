# Hosted CI repair

At `6cfe674`, seven hosted checks passed. The Apple SDK job compiled all ten profiles but rejected the two visionOS compiler identities. The macOS job exceeded its configured 45-minute limit during CLI sanitizer checks; a completed 283-test run was retained before cancellation. Neither is treated as a complete pass.

The native SwiftPM visionOS failure was reproduced locally: versioned input `arm64-apple-xros26.0` produced compiler target `arm64-apple-xros26.026.0`, with the same duplication for the simulator. The correction supplies versionless visionOS input to native SwiftPM, which then obtains the OS 26 deployment version from the package manifest. The original strict check still requires the exact architecture, OS version, simulator environment, SDK path and emitted module. No identity failure is ignored.

Before and after commands used `python3 Scripts/validate-apple-sdks.py --build-system native --profile visionos-device --profile visionos-simulator --output <evidence-directory>`. The original script exited 1; the corrected script exited 0. Reports retain exact paths, commands, toolchains, source/script/module hashes and logs. Both use local Swift 6.4; baseline Swift 6.2 remains a hosted gate. Runtime sources and tests are unchanged.

The macOS workflow is split into complete debug, address-sanitizer and thread-sanitizer jobs. Each retains serial test scheduling, original assertions and per-operation deadlines, plus every applicable CLI payload, VarDCT decode/encode and NRRD check. Each has a separate 45-minute runner budget. The original macOS check name is retained as an explicit aggregate gate and fails for failure, cancellation or skipped dependencies. No `continue-on-error` or test filter is added.

Local workflow validation parsed the YAML, syntax-checked all 32 shell blocks, verified both sanitizer variants retain all four CLI scripts, and executed the aggregate shell gate for all 16 combinations of success, failure, cancellation and skipped dependency results. Only two successful dependencies passed. All verification commands exited 0. Final hosted qualification of the corrected commit is pending.

## Thread-sanitizer job allowance follow-up

On `38dd95d`, all Apple SDK builds, macOS debug and ASan checks passed. The first TSan attempt hit the existing 30-second operation deadline in `nestedQuantisationAndGroupBoundaries`. A single unchanged retry passed that case in 28.544 seconds and the entire 283-declaration suite in 931.390 seconds. The retry then passed 104 CLI payload process checks before reaching the job's 45-minute overall cap later in CLI validation. The original timeout remains recorded; no deadline, assertion or test input was relaxed.

Only the TSan job allowance is now 75 minutes; ASan remains 45 minutes. Fixture generation and the four CLI scripts have separate named steps, retaining every original executable command and output report. YAML parsing, all 36 shell-block syntax checks, command-preservation comparison and all 16 aggregate-gate outcome combinations passed locally (exit 0). Runtime sources, tests, CLI scripts and operation limits are unchanged. Corrected-head hosted completion remains required. The retained JSON records identify both original attempts and acknowledge truncated hosted logs.

# Public VarDCT integration checkpoint

The bounded public sRGB 8/16-bit decoder shares one prepared header with Modular and writes directly into owning storage. It reports lossy fidelity and rejects unsupported interpretation/profile combinations. Full local debug with the pinned independent oracle enabled passed 230 declarations / 883 cases without skips. Affected ASan and TSan each passed 21 declarations / 130 cases. Raw logs and exact source/test hashes are retained here.

The CLI corpus uses the separately pinned scalar Float32 reference with explicit nearest-integer conversion. Its unchanged max-two-level/RMS-0.5 synthetic limits are not universal conformance bounds. Original NEON integer-oracle failures, the full official corpus, broader profiles, performance and platform gates remain separately open. No production cutover or stable release is implied.

The release CLI build passed. Debug and release each passed all 32 VarDCT CLI cases and the Modular exact-samples report regression. `cli-debug.json` and `cli-release.json` retain source, oracle, script and executable hashes.

# swiftjxl-cli: help, diagnostics and installation

Version **2.1.0-dev.2**; Swift 6.2 minimum with Swift 6.4 qualified / Swift 6, Apple OS minimum **26.0**. The CLI targets macOS and Linux; Linux execution remains a qualification requirement. No external parser package or sibling codec is required. Current commands provide help, version, executable capabilities, supported-header inspection and full supported-frame validation. Encode/decode file adapters and transcode remain unavailable (exit 4), without opening input, consuming stdin or creating output. Their help describes reserved syntax only.

```sh
swift run swiftjxl-cli --help
swift run swiftjxl-cli -h
swift run swiftjxl-cli help capabilities
swift run swiftjxl-cli capabilities --help
swift run swiftjxl-cli --version
swift run swiftjxl-cli capabilities --json
swift run swiftjxl-cli capabilities -vv
swift run swiftjxl-cli capabilities -verbose: 3
swift run swiftjxl-cli capabilities --verbose=+++++
```

Both global and command-local help include availability, examples, option ranges/defaults, streams, errors and manual discovery. No arguments also show help. Use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` with the qualified Xcode on macOS.

## Inspect and validate

```sh
swiftjxl-cli inspect -i image.jxl --json
swiftjxl-cli validate -i image.jxl -o report.json --json
cat image.jxl | swiftjxl-cli validate -i - --timeout 30
```

`inspect` reports supported headers and geometry without validating the pixel payload. `validate` decodes the entire supported frame in memory and discards its pixels. Neither is a general JPEG XL conformance validator. Both accept the public decoder's unsigned greyscale Modular profile: 8–16 meaningful bits, one frame/group, dimensions at most 1024, compressed input at most 4 MiB. Unsupported colour, transforms, animation or other profiles return 4. JSON includes `pixelPayloadValidated`, dimensions, bit depths and a metadata-presence flag; metadata values and paths are not reported.

Input is a regular file or pipe; `-` means stdin. Output defaults to stdout and is a text or `--json` report. File reports use a temporary sibling and atomic publication, refusing existing files unless `--overwrite` is explicit. Existing input aliases, symlinks and non-regular outputs are refused. Failed validation preserves the previous report. Standard output cannot be rolled back after a partial I/O failure. No intermediate pixel file is created.

`--input-format` accepts `jxl` or `jpeg-xl`. Backend is `automatic` or `scalar-cpu`; `accelerated` rejects. Copy policy is `require-sharing` by default or `allow-copy`; both use the existing public memory contract. `--threads` is a 1–8 worker ceiling; this scalar profile uses one worker. `--max-memory` is a positive aggregate byte ceiling (default 1073741824), reserving compressed-buffer growth, 256 KiB command overhead and the codec's admitted storage/workspace; it is not a process RSS limit. `--timeout` is positive finite seconds, at most 31536000 (default 120), covering cooperative input, codec and output checkpoints. Pipe readiness is checked every 25 ms; ordinary filesystem calls remain subject to operating-system scheduling. Ctrl+C returns 130. `--mode`, `--max-error` and `--output-format` do not apply.

CLI capabilities describe executable commands: `canInspect` and `canValidate` are true; `canEncode` and `canDecode` remain false until file adapters are implemented. Library capabilities are separate.

## Verbosity

| Level | Cumulative stderr diagnostics |
| --- | --- |
| 0 (default) | Errors only |
| 1 | Version/operation summary |
| 2 | Command stages |
| 3 | Capability/configuration details |
| 4 | Elapsed timing |
| 5 | Bounded execution trace |

`-v` increments, `-vv` through `-vvvvv` group increments, and `--verbose LEVEL`, `--verbose=LEVEL`, `-verbose: LEVEL` or `-verbose:LEVEL` set an explicit level. Digits 1..5 and `+`..`+++++` are equivalent. Bare `--verbose` / `-verbose` increment once. Options apply in order; exceeding 5 or supplying an invalid level returns 2. `--quiet` / `-q` conflicts with any positive verbosity. Errors still print in quiet mode. Help, version and capability output remain stdout data. Diagnostics never contaminate JSON or log payload bytes, metadata, raw addresses or input/output paths.

## Install or update the binary and UNIX manual

Run the installer from this source checkout. It builds the release executable and installs both the binary and matching manual every time; rerunning updates both. No administrator command runs automatically.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./Scripts/install-cli.sh --prefix "$HOME/.local"
"$HOME/.local/bin/swiftjxl-cli" --help
man -M "$HOME/.local/share/man" swiftjxl-cli
```

Default prefix is `/usr/local`; choose an absolute writable prefix. Add its `bin` directory to PATH. For ordinary `man swiftjxl-cli` lookup with a custom prefix, configure MANPATH to include `PREFIX/share/man` while retaining system defaults (for example `export MANPATH="$HOME/.local/share/man:${MANPATH:-}"`). Direct `man -M` needs no index refresh. The page is [ManPages/swiftjxl-cli.1](ManPages/swiftjxl-cli.1). A packaging recipe must install both `PREFIX/bin/swiftjxl-cli` (0755) and `PREFIX/share/man/man1/swiftjxl-cli.1` (0644).

`--destdir /absolute/staging` (or DESTDIR) stages those same prefix-relative locations for packaging. `--binary /absolute/built/swiftjxl-cli` avoids a rebuild and verifies `--version` against VERSION before writing. `--scratch-path` selects a build directory; `--disable-package-sandbox` is only an explicit workaround for nested sandbox restrictions. An existing destination symlink/directory is refused. Merely copying the executable does not install its manual.

## Exit codes and validation

Exit statuses: 0 success/help/version, 2 invalid usage, 3 malformed input, 4 unsupported feature/layout/backend/format, 5 resource/deadline, 6 input/output failure including closed pipes, 7 internal failure, 130 cancellation. No successful compression is inferred from a zero-exit capability query. Library errors cannot terminate the host application; exit handling exists only in this executable.

`Scripts/test-cli.py --binary /absolute/built/swiftjxl-cli --output /new/evidence/directory` checks the real executable, help, verbosity, JSON separation, invalid inputs, unavailable operations, closed pipes and staged manual install/update/rendering. [Qualification](Documentation/Engineering/OS27CLI/README.md) records exact executed commands and platform limits. `Scripts/test-cli-payload.py` exercises supported frames, malformed payloads, memory/deadline limits, stalled and broken pipes, Ctrl+C and atomic report publication. Synthetic inputs are generated by `Examples/CLIValidationFixtures`, using only the public API. See [this stage’s evidence](Documentation/Engineering/Migration/CLI_VALIDATION.md).

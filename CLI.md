# swiftjxl-cli: help, diagnostics and installation

Version **2.1.0-dev.2**; Swift 6.2 minimum with Swift 6.4 qualified / Swift 6, Apple OS minimum **26.0**. The CLI targets macOS and Linux; Linux execution remains a qualification requirement. No external parser package or sibling codec is required. Current commands provide help, version, executable capabilities, supported-header inspection and full supported-frame validation. Encode/decode support the explicit UInt16 NRRD and integer colour PNM/PAM profiles below. Native transcode now supports the bounded JPEG reconstruction profile below.

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

`inspect` reports supported headers and geometry without validating the pixel payload. `validate` decodes the entire supported frame in memory and discards its pixels. Neither is a general JPEG XL conformance validator. Both accept the public decoder's integer Modular profile: greyscale/RGB with optional alpha, 8–16 meaningful bits, one frame, grouped streams, RCT, simple palettes and Squeeze. CLI dimensions remain at most 1024 and compressed input at most 4 MiB. Unsupported colour interpretation, transforms, animation or other profiles return 4. JSON includes `pixelPayloadValidated`, dimensions, bit depths, colour/alpha interpretation, component count and a metadata-presence flag; metadata values and paths are not reported.

Input is a regular file or pipe; `-` means stdin. Output defaults to stdout and is a text or `--json` report. File reports use a temporary sibling and atomic publication, refusing existing files unless `--overwrite` is explicit. Existing input aliases, symlinks and non-regular outputs are refused. Failed validation preserves the previous report. Standard output cannot be rolled back after a partial I/O failure. No intermediate pixel file is created.

`--input-format` accepts `jxl` or `jpeg-xl`. Backend is `automatic` or `scalar-cpu`; `accelerated` rejects. Copy policy is `require-sharing` by default or `allow-copy`; both use the existing public memory contract. `--threads` is a 1–8 worker ceiling; this scalar profile uses one worker. `--max-memory` is a positive aggregate byte ceiling (default 1073741824), reserving compressed-buffer growth, 256 KiB command overhead and the codec's admitted storage/workspace; it is not a process RSS limit. `--timeout` is positive finite seconds, at most 31536000 (default 120), covering cooperative input, codec and output checkpoints. Pipe readiness is checked every 25 ms; ordinary filesystem calls remain subject to operating-system scheduling. Ctrl+C returns 130. `--mode`, `--max-error` and `--output-format` do not apply.

CLI capabilities describe executable commands: `canInspect` and `canValidate` are true; `canEncode` and `canDecode` are true for the NRRD and PNM/PAM profiles. Library capabilities are separate.

## Encode and decode through NRRD

```sh
swiftjxl-cli encode -i image.nrrd --input-format nrrd -o image.jxl
swiftjxl-cli decode -i image.jxl --output-format nrrd -o restored.nrrd
cat image.nrrd | swiftjxl-cli encode -i - --input-format nrrd | swiftjxl-cli decode -i - --output-format nrrd > restored.nrrd
```

Select `--input-format nrrd` for encode or `--output-format nrrd` for decode explicitly. The compressed endpoint is `jxl`/`jpeg-xl` by default; no filename extension reinterprets raw bytes. Encoding accepts only lossless mode (the default), with dimensions at most 1024; decoding accepts dimensions at most 1024. Input is capped at 4 MiB. Resource/backend/copy limits, atomic output and cancellation follow the preceding section. `--max-error` never applies; `--mode` applies only to encode. `--json` writes the final success report to stderr after binary publication; requested verbosity also uses stderr. A reporting failure after publication returns failure but cannot retract the payload. A broken binary output never prints success.

The [pinned and reviewed NRRD subset](Documentation/Engineering/Migration/NRRD_PROFILE.md) is attached NRRD0005, 2D greyscale, raw unsigned 16-bit samples, explicit little/big endian and x as fastest axis. This explicit input profile assigns the existing codec's D65/sRGB/default rendering intent. Header limits are 16 KiB total, 64 lines, 1024 bytes per line. Standard uint16 type aliases, LF/CRLF and comments are supported. Duplicate/missing fields, invalid counts, wrong payload lengths and unsupported fields reject. Detached references, URLs, compressed encodings, spatial metadata and custom keys are never followed or interpreted.

Plain NRRD uint16 cannot represent source-declared 8–15-bit precision or non-default rendering-intent metadata. Decode rejects those rather than silently widening precision or discarding interpretation. Colour, signed samples, animation and ICC remain unsupported. This profile is not a replacement for every predecessor image-file adapter.

Encoding retains the immutable NRRD input owner and exposes a bounded sample view directly to the public encoder. Decoding writes the NRRD header and borrowed decoded rows to the final destination; it creates no full-image serialisation array or intermediate pixel file. OS pipe/file copies still occur and are distinct from in-process storage sharing. Pinned pynrrd/NumPy and libjxl are test-only oracles, never runtime dependencies.

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

Diagnostic writes never wait for stderr to drain. If an optional diagnostic cannot be written, the command returns I/O failure (6). Final error messages are best effort: a full or closed stderr cannot prevent the original failure, deadline (5) or cancellation (130) exit status from being returned.

Exit statuses: 0 success/help/version, 2 invalid usage, 3 malformed input, 4 unsupported feature/layout/backend/format, 5 resource/deadline, 6 input/output failure including closed pipes, 7 internal failure, 130 cancellation. No successful compression is inferred from a zero-exit capability query. Library errors cannot terminate the host application; exit handling exists only in this executable.

`Scripts/test-cli.py --binary /absolute/built/swiftjxl-cli --output /new/evidence/directory` checks the real executable, help, verbosity, JSON separation, invalid inputs, unavailable operations, closed pipes and staged manual install/update/rendering. [Qualification](Documentation/Engineering/OS27CLI/README.md) records exact executed commands and platform limits. `Scripts/test-cli-payload.py` exercises supported frames, malformed payloads, memory/deadline limits, stalled and broken pipes, Ctrl+C and atomic report publication. Synthetic inputs are generated by `Examples/CLIValidationFixtures`, using only the public API. See [this stage’s evidence](Documentation/Engineering/Migration/CLI_VALIDATION.md).

## Native JPEG reconstruction

```sh
swiftjxl-cli transcode -i source.jpg --input-format jpeg --output-format jxl -o image.jxl
swiftjxl-cli transcode -i image.jxl --input-format jxl --output-format jpeg -o restored.jpg
```

Both formats are explicit (`jxl` and `jpeg-xl` are aliases). Lossless mode preserves the original JPEG bytes through quantised coefficients and reconstruction metadata; no pixel conversion or original-source fallback is used. Both directions stay in memory. CLI input/output is bounded to 4 MiB; dimensions are at most 2048 per side. The library permits up to 64 MiB compressed input/output under caller resource limits.

The qualified profile is 8-bit baseline/extended/progressive Huffman JPEG, greyscale or three components, common 444/422/420/440 sampling, and a single-pass DCT8 JPEG XL reconstruction frame. RGB/greyscale ICC profiles are preserved; other unsupported representations reject. This is not arbitrary JPEG XL-to-JPEG conversion. Standard APP/COM bytes, Exif/XMP, marker ordering, restart/padding/fill and tail details are preserved where the profile admits them. Independent compressed Exif/XMP boxes are resolved using bounded native Brotli.

`--mode lossless` is the default. Lossy/near-lossless, `--max-error`, quality and source-file fallback options do not select a substitute operation. Streams, limits, atomic final-file publication and error statuses follow the existing commands. `--json` writes the final `original-bitstream` fidelity report to stderr after successful binary publication. Capability reports expose `canTranscode`, `maximumTranscodeDimension` and explicit profile limits. Local integration evidence is in the native JPEG migration record; final hosted qualification and broader migration remain pending.

## Colour and alpha through PGM/PPM/PAM

Select `--input-format pnm` or `--output-format pnm` for standard binary P5 (greyscale), P6 (RGB), or P7 (PAM with an explicit GRAYSCALE, GRAYSCALE_ALPHA, RGB or RGB_ALPHA tuple type). The standard interpretation uses D65, BT.709 transfer and RGB primaries shared with sRGB. Alpha is straight, with linear opacity. Samples are never rescaled or colour-converted. See the official [PPM](https://netpbm.sourceforge.net/doc/ppm.html), [PGM](https://netpbm.sourceforge.net/doc/pgm.html) and [PAM](https://netpbm.sourceforge.net/doc/pam.html) specifications.

Use `pnm-srgb` on both import and export only when explicitly working with the common sRGB variant. The file syntax does not distinguish this variant: preserve that external interpretation when handing the file to another tool. Selecting the wrong output interpretation fails; it never silently converts samples. Premultiplied alpha, ICC, non-default rendering intent and other unrepresentable metadata also fail before output publication.

```sh
swiftjxl-cli encode -i colour.ppm --input-format pnm -o colour.jxl
swiftjxl-cli decode -i colour.jxl --output-format pnm -o restored.ppm
swiftjxl-cli encode -i srgb.pam --input-format pnm-srgb -o srgb.jxl
swiftjxl-cli decode -i srgb.jxl --output-format pnm-srgb -o restored.pam
```

One image is accepted, with dimensions at most 1024, 8–16 meaningful bits and MAXVAL exactly `2^bits-1`. Multi-byte samples are big endian. Other maxima, unknown tuple meanings, concatenated frames, trailing or truncated payloads and out-of-range samples reject. The P5/P6 raster follows exactly one whitespace delimiter after MAXVAL; whitespace or `#` in the raster is sample data. Header limits are 16 KiB, 64-byte numeric tokens, and for PAM 64 lines/1024 bytes per line. All existing command input, memory, deadline, pipe and atomic-output rules apply.

The encoder retains a sample view of the input Data. Output serialisation uses one row of at most 8192 bytes, included in the CLI overhead reservation; no second full image is created. Library BT.709 metadata is required semantics and survives `discardAncillary`. This profile extends CLI coverage; broader migration and release qualification remain open.

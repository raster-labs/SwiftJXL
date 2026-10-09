// SPDX-License-Identifier: Apache-2.0
import Foundation
import Dispatch
import SwiftJXL
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private let tool = "swiftjxl-cli"
private let version = "2.1.0-dev.2"
private let reserved = ["encode", "decode", "transcode"]
private let active = ["inspect", "validate"]
private let valueOptions: Set<String> = ["--input", "-i", "--output", "-o", "--input-format", "--output-format",
    "--mode", "--max-error", "--backend", "--copy-policy", "--threads", "--max-memory", "--timeout"]

private struct UsageError: Error { let message: String }
private struct Options {
    var command: String? = nil
    var help = false
    var version = false
    var json = false
    var quiet = false
    var verbosity = 0
    var codecOptions = false
    var values: [String: String] = [:]
    var overwrite = false
}

private func parse(_ args: [String]) throws -> Options {
    var options = Options()
    var index = 0
    var positionalOnly = false
    func level(_ value: String) throws -> Int {
        let number: Int?
        if !value.isEmpty && value.allSatisfy({ $0 == "+" }) { number = value.count }
        else if !value.isEmpty && value.utf8.allSatisfy({ (48...57).contains($0) }) { number = Int(value) }
        else { number = nil }
        guard let number, (1...5).contains(number) else {
            throw UsageError(message: "Verbosity must be 1 through 5, or + through +++++.")
        }
        return number
    }
    func consumeValue() throws -> String {
        guard index + 1 < args.count, args[index + 1] == "-" || !args[index + 1].hasPrefix("-") else {
            throw UsageError(message: "An option is missing its value. Use --help for syntax.")
        }
        index += 1
        return args[index]
    }
    while index < args.count {
        let arg = args[index]
        if !positionalOnly && arg == "--" { positionalOnly = true }
        else if !positionalOnly && ["-h", "--help"].contains(arg) { options.help = true }
        else if !positionalOnly && arg == "--version" { options.version = true }
        else if !positionalOnly && arg == "--json" { options.json = true }
        else if !positionalOnly && ["-q", "--quiet"].contains(arg) { options.quiet = true }
        else if !positionalOnly && ["-v", "--verbose", "-verbose"].contains(arg) {
            // An optional numeric/plus value sets the level. A bare flag increments it.
            if index + 1 < args.count,
               let first = args[index + 1].first, first.isNumber || first == "+" {
                index += 1; options.verbosity = try level(args[index])
            } else { options.verbosity += 1 }
        } else if !positionalOnly,
                  let prefix = ["--verbose=", "--verbose:", "-verbose=", "-verbose:"].first(where: { arg.hasPrefix($0) }) {
            let attached = String(arg.dropFirst(prefix.count))
            options.verbosity = try level(attached.isEmpty ? consumeValue() : attached)
        } else if !positionalOnly && arg.hasPrefix("-v") && arg.count > 2 && arg.dropFirst().allSatisfy({ $0 == "v" }) {
            options.verbosity += arg.count - 1
        } else if !positionalOnly && valueOptions.contains(arg) {
            let key = arg == "-i" ? "--input" : arg == "-o" ? "--output" : arg
            guard options.values[key] == nil else { throw UsageError(message: "Duplicate command option.") }
            options.values[key] = try consumeValue()
            options.codecOptions = true
        } else if !positionalOnly && arg == "--overwrite" { options.codecOptions = true; options.overwrite = true }
        else if !positionalOnly && arg.hasPrefix("-") {
            throw UsageError(message: "Unknown option. Use \(tool) --help.")
        } else if options.command == nil { options.command = arg }
        else if options.command == "help" && !options.help { options.command = arg; options.help = true }
        else { throw UsageError(message: "Unexpected positional argument. Use --input or --output for codec commands.") }
        guard options.verbosity <= 5 else { throw UsageError(message: "Verbosity exceeds the maximum level 5.") }
        index += 1
    }
    if options.command == "help" { options.command = nil; options.help = true }
    if options.command == "version" { options.command = nil; options.version = true }
    if let command = options.command, command != "capabilities" && !reserved.contains(command) && !active.contains(command) {
        throw UsageError(message: "Unknown command. Use \(tool) --help.")
    }
    if options.quiet && options.verbosity > 0 { throw UsageError(message: "--quiet and verbosity cannot be combined.") }
    if options.version && (options.command != nil || options.codecOptions || options.json) {
        throw UsageError(message: "--version cannot be combined with a command or command options.")
    }
    if options.codecOptions && (options.command == nil || options.command == "capabilities") {
        throw UsageError(message: "Input/output and codec options require a codec command.")
    }
    if options.json && options.command == nil { throw UsageError(message: "--json requires capabilities or a codec command.") }
    return options
}

private func help(_ command: String?) -> String {
    let common = """
    OPTIONS
      -h, --help                 Show this help; also: help [command].
      --version                  Show the development version.
      -v, -vv ... -vvvvv         Increase verbosity (maximum 5).
      --verbose LEVEL           Set verbosity to 1..5 or + through +++++.
      --verbose=LEVEL            Equivalent explicit form; -verbose: LEVEL is accepted.
      -q, --quiet                Suppress optional diagnostics; errors remain visible.

    VERBOSITY (stderr only; default 0)
      1 summary; 2 command stages; 3 capability details; 4 elapsed timing;
      5 bounded diagnostic trace. Levels are cumulative. Quiet conflicts with verbosity.
      Payload bytes, metadata, raw addresses and input/output paths are never logged.

    EXIT STATUS
      0 success; 2 invalid usage; 3 malformed input; 4 unsupported feature;
      5 resource/deadline; 6 I/O/storage failure (including a closed pipe);
      7 internal failure; 130 user cancellation.

    MANUAL
      man \(tool) (installed with the executable by Scripts/install-cli.sh).
    """
    if let command {
        if command == "capabilities" {
            return """
            USAGE: \(tool) capabilities [--json] [OPTIONS]

            Report executable command support without reading files.
            --json writes one JSON document to stdout; diagnostics stay on stderr.
            Inspect/validate support the bounded scalar JPEG XL profile. Encode/decode remain unavailable.

            \(common)

            EXAMPLES
              \(tool) capabilities --json
              \(tool) capabilities --verbose=+++
            """ + "\n"
        }
        if active.contains(command) {
            return """
            USAGE: \(tool) \(command) --input PATH [OPTIONS]

            \(command == "inspect" ? "Inspect supported headers and output geometry; pixel payload integrity is not checked." : "Decode the entire supported frame in memory to validate its pixel payload; discard pixels.")
            Supports a single-frame/group unsigned greyscale Modular JPEG XL profile,
            8..16 meaningful bits, dimensions <=1024, compressed input <=4194304 bytes.
            This is not a general JPEG XL conformance validator. Unsupported profiles return 4.

            COMMAND OPTIONS
              -i, --input PATH          Required regular file or pipe; '-' means stdin.
              -o, --output PATH         Final report file; default '-' means stdout.
              --input-format FORMAT    jxl or jpeg-xl; optional, bytes are always checked.
              --json                   Emit one structured report instead of readable text.
              --overwrite              Atomically replace an existing regular report file.
              --backend NAME           automatic (default), scalar-cpu; accelerated returns 4.
              --copy-policy POLICY     require-sharing (default) or allow-copy.
              --threads N              Worker ceiling 1..8; scalar implementation uses one.
              --max-memory BYTES       Positive aggregate ceiling; default 1073741824.
              --timeout SECONDS        Deadline >0..31536000 seconds, including pipe I/O; default 120.
            Mode, max-error and output-format do not apply to inspection/validation.
            No output is published after parsing, resource or validation failures.
            File reports use an atomic transaction; stdout cannot be rolled back after I/O failure.
            Ctrl-C cancels with exit 130. A stalled producer is bounded by --timeout.

            \(common)

            EXAMPLES
              \(tool) \(command) --input image.jxl --json
              cat image.jxl | \(tool) \(command) --input - --timeout 30
              \(tool) \(command) -i image.jxl -o report.json --json --overwrite
            """ + "\n"
        }
        return """
        USAGE: \(tool) \(command) [OPTIONS]

        UNAVAILABLE: \(command) is reserved for a future codec milestone (exit 4).
        No input is opened, no standard input is consumed and no output file is created.
        Help describes reserved syntax, not working compression or validation.

        RESERVED CODEC OPTIONS
          -i, --input PATH           Input file; '-' will mean standard input.
          -o, --output PATH          Final output; '-' will mean standard output.
          --input-format FORMAT     Explicit source format.
          --output-format FORMAT    Explicit target format.
          --mode MODE               lossless (default), near-lossless or lossy when supported.
          --max-error N             Supported near-lossless error in integer sample units.
          --backend NAME            Explicit supported backend.
          --copy-policy POLICY      require-sharing (default) or allow-copy.
          --threads N               Worker limit; --max-memory BYTES; --timeout SECONDS.
          --overwrite               Permit replacing final output only when implemented.
          --json                    Structured report; no binary stdout contamination.
        Command-specific applicability and value validation require codec implementation.

        \(common)
        """ + "\n"
    }
    return """
    \(tool) \(version) — JPEG XL
    USAGE: \(tool) [OPTIONS] <command> [OPTIONS]

    COMMANDS
      capabilities [--json]      Report executable command support.
      inspect, validate         Inspect headers or validate the supported scalar frame.
      help [command]             Show global or command-specific help.
      version                    Show the development version.
      \(reserved.joined(separator: ", "))
                                Reserved; codec algorithms are unavailable (exit 4).

    Requires Swift 6.2 or later to build; Apple OS baseline 26.0. CLI hosts: macOS/Linux.
    Inspection and validation are available. Encoding/decoding file adapters remain unavailable.

    \(common)

    EXAMPLES
      \(tool) -h
      \(tool) help capabilities
      \(tool) capabilities --json -vv
      \(tool) capabilities -verbose: 3
    """ + "\n"
}

private func write(_ text: String, to handle: FileHandle) throws {
    let data = Data(text.utf8)
    if handle.fileDescriptor == STDERR_FILENO {
        try CommandIO.writeDiagnostic(data)
    } else {
        try handle.write(contentsOf: data)
    }
}

@concurrent private func run() async throws -> Int32 {
    let start = ProcessInfo.processInfo.systemUptime
    let options: Options
    do { options = try parse(Array(CommandLine.arguments.dropFirst())) }
    catch let error as UsageError {
        try write("\(tool): \(error.message)\n", to: .standardError)
        return 2
    }
    if options.help || (options.command == nil && !options.version) {
        try write(help(options.command), to: .standardOutput); return 0
    }
    if options.version { try write("\(tool) \(version)\n", to: .standardOutput); return 0 }
    func diagnostic(_ level: Int, _ message: String) throws {
        if !options.quiet && options.verbosity >= level {
            try write("[\(level)] \(tool): \(message)\n", to: .standardError)
        }
    }
    try diagnostic(1, "development version \(version)")
    try diagnostic(2, "reporting \(options.command ?? "help")")
    if let command = options.command, active.contains(command) {
        return try await runPayload(command, options: options, start: start, diagnostic: diagnostic)
    }
    guard options.command == "capabilities" else {
        try write("\(tool): unsupported feature: CLI codec commands are not integrated; no input/output opened.\n", to: .standardError)
        return 4
    }
    // CLI file commands remain reserved even though the library scalar API is available.
    let encoder = CodecCapabilities.contractOnly
    let decoder = Decoder.capabilities
    let formats = Array(Set(encoder.formats + decoder.formats)).sorted()
    if options.json {
        let payload: [String: Any] = ["tool": tool, "version": version, "minimumAppleOS": "26.0",
            "canEncode": encoder.canEncode, "canDecode": false,
            "canInspect": decoder.canInspect, "canValidate": true, "formats": formats,
            "profile": "single-frame/group unsigned greyscale Modular; 8..16 bits; maximum dimension 1024",
            "maximumCompressedBytes": CommandIO.maximumInput]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
    } else {
        try write("\(tool) \(version)\nencode: \(encoder.canEncode)\ndecode: false\ninspect: \(decoder.canInspect)\nvalidate: true\nformats: \(formats.isEmpty ? "none" : formats.joined(separator: ", "))\n", to: .standardOutput)
    }
    try diagnostic(3, "advertised formats: \(formats.count); CLI capabilities; library scalar API is separately available")
    try diagnostic(4, "elapsed seconds: \(ProcessInfo.processInfo.systemUptime - start)")
    try diagnostic(5, "arguments validated; capability report emitted; no codec payload opened")
    return 0
}

private func status(for error: CodecError) -> Int32 {
    switch error.category {
    case .invalidArgument: 2
    case .malformedInput: 3
    case .unsupportedFormat, .unsupportedFeature, .incompatibleImageLayout, .backendUnavailable: 4
    case .resourceLimitExceeded: 5
    case .ioFailure, .storageUnavailable: 6
    case .internalFailure: 7
    }
}

@concurrent private func runPayload(_ command: String, options: Options, start: Double,
    diagnostic: (Int, String) throws -> Void) async throws -> Int32 {
    let values = options.values
    guard let input = values["--input"], !input.isEmpty else {
        throw CodecError(.invalidArgument, "--input is required.")
    }
    guard values["--mode"] == nil, values["--max-error"] == nil, values["--output-format"] == nil else {
        throw CodecError(.invalidArgument, "Mode, max-error and output-format do not apply to this command.")
    }
    let output = values["--output"] ?? "-"
    guard !output.isEmpty, !options.overwrite || output != "-" else {
        throw CodecError(.invalidArgument, "--overwrite requires an output file.")
    }
    if let format = values["--input-format"], !["jxl", "jpeg-xl"].contains(format) {
        throw CodecError(.unsupportedFormat, "Input format is unsupported.")
    }
    func integer(_ key: String, default defaultValue: Int) throws -> Int {
        guard let raw = values[key] else { return defaultValue }
        guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = Int(raw), number > 0 else {
            throw CodecError(.invalidArgument, "Expected a positive integer command limit.")
        }
        return number
    }
    let memory = try integer("--max-memory", default: ResourceLimits.default.maximumMemoryBytes)
    let threads = try integer("--threads", default: ResourceLimits.default.maximumWorkers)
    guard threads <= 8 else { throw CodecError(.invalidArgument, "Worker limit must be 1..8.") }
    let seconds: Double
    if let raw = values["--timeout"] {
        guard let value = Double(raw), value.isFinite, value > 0, value <= 31_536_000 else {
            throw CodecError(.invalidArgument, "Timeout must be positive, finite and at most 31536000 seconds.")
        }
        seconds = value
    } else { seconds = ResourceLimits.default.deadlineSeconds }
    let backend: ExecutionPolicy
    switch values["--backend"] ?? "automatic" {
    case "automatic": backend = .automatic
    case "scalar-cpu": backend = .scalarCPU
    case "accelerated": throw CodecError(.backendUnavailable, "Accelerated backend is unavailable.")
    default: throw CodecError(.invalidArgument, "Unknown backend.")
    }
    let copy: CopyPolicy
    switch values["--copy-policy"] ?? "require-sharing" {
    case "require-sharing": copy = .requireSharedStorage
    case "allow-copy": copy = .allowCopy
    default: throw CodecError(.invalidArgument, "Unknown copy policy.")
    }
    let io = CommandIO(deadline: .now.advanced(by: .seconds(seconds)), maximumMemoryBytes: memory)
    let data = try io.readInput(input)
    try io.checkpoint()
    // Retain room for input capacity/growth and report/scratch in addition to
    // the library's own input+pixel+workspace admission accounting.
    let available = memory - CommandIO.overhead - data.count * 2
    guard available > 0 else { throw CodecError(.resourceLimitExceeded, "Aggregate command memory limit exceeded.") }
    let limits = try ResourceLimits(maximumCompressedBytes: CommandIO.maximumInput,
        maximumPixels: 1024 * 1024, maximumDimension: 1024, maximumFrames: 1,
        maximumWorkers: threads, deadlineSeconds: max(io.remainingSeconds, Double.leastNonzeroMagnitude),
        maximumMemoryBytes: available)
    let decodeOptions = DecodeOptions(resourceLimits: limits, executionPolicy: backend, copyPolicy: copy)
    let decoder = try Decoder()
    let descriptor: ImageDescriptor
    let hasMetadata: Bool
    if command == "validate" {
        let decoded = try await decoder.decode(data, options: decodeOptions)
        descriptor = decoded.image.descriptor
        hasMetadata = !decoded.image.metadata.entries.isEmpty
    } else {
        let info = try decoder.inspect(data, options: decodeOptions)
        descriptor = info.descriptor
        hasMetadata = !info.metadata.entries.isEmpty
    }
    try io.checkpoint()
    let validated = command == "validate"
    let report: Data
    if options.json {
        let object: [String: Any] = ["tool": tool, "version": version, "operation": command,
            "format": "jpeg-xl", "profile": "scalar-greyscale-modular", "frameCount": 1,
            "width": descriptor.width, "height": descriptor.height,
            "sampleType": "unsigned-integer", "meaningfulBits": descriptor.meaningfulBits,
            "storageBits": descriptor.storageBits, "hasMetadata": hasMetadata,
            "pixelPayloadValidated": validated]
        report = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) + Data([10])
    } else {
        report = Data("JPEG XL: \(descriptor.width)x\(descriptor.height), unsigned greyscale, \(descriptor.meaningfulBits) meaningful bits, 1 frame\n\(validated ? "Supported scalar pixel payload validated." : "Supported headers inspected; pixel payload not validated.")\n".utf8)
    }
    try diagnostic(3, "supported scalar profile; one worker; memory and deadline limits enforced")
    try diagnostic(4, "elapsed seconds before report publication: \(ProcessInfo.processInfo.systemUptime - start)")
    try diagnostic(5, "bounded input processed; final report ready; no pixel file created")
    try io.publish(report, path: output, inputPath: input, overwrite: options.overwrite)
    return 0
}

// CLI process boundary only. Signal callbacks cancel the operation task;
// nonblocking stream polling and the codec's checkpoints observe cancellation.
_ = signal(SIGPIPE, SIG_IGN)
_ = signal(SIGINT, SIG_IGN)
let operation = Task { () -> Int32 in
    do { return try await run() }
    catch is CancellationError {
        try? write("\(tool): cancelled.\n", to: .standardError)
        return 130
    }
    catch let error as CodecError {
        try? write("\(tool): \(error.message)\n", to: .standardError)
        return status(for: error)
    }
    catch {
        try? write("\(tool): output I/O failure.\n", to: .standardError)
        return 6
    }
}
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
interrupt.setEventHandler { @Sendable in operation.cancel() }
interrupt.resume()
let result = await operation.value
interrupt.cancel()
exit(result)

// SPDX-License-Identifier: Apache-2.0
import Foundation
import SwiftJXL
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private let tool = "swiftjxl-cli"
private let version = "2.1.0-dev.2"
private let reserved = ["encode", "decode", "inspect", "validate", "transcode"]
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
            _ = try consumeValue() // Reserved syntax only: do not open or echo any payload/path.
            options.codecOptions = true
        } else if !positionalOnly && arg == "--overwrite" { options.codecOptions = true }
        else if !positionalOnly && arg.hasPrefix("-") {
            throw UsageError(message: "Unknown option. Use \(tool) --help.")
        } else if options.command == nil { options.command = arg }
        else if options.command == "help" && !options.help { options.command = arg; options.help = true }
        else { throw UsageError(message: "Unexpected positional argument. Use --input or --output for future codec commands.") }
        guard options.verbosity <= 5 else { throw UsageError(message: "Verbosity exceeds the maximum level 5.") }
        index += 1
    }
    if options.command == "help" { options.command = nil; options.help = true }
    if options.command == "version" { options.command = nil; options.version = true }
    if let command = options.command, command != "capabilities" && !reserved.contains(command) {
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
      0 success/help/version; 2 invalid usage; 4 unsupported codec operation;
      6 output I/O failure (including a closed pipe). Future codec errors additionally
      use 3 malformed input, 5 resource/deadline, 7 internal failure, 130 cancellation.

    MANUAL
      man \(tool) (installed with the executable by Scripts/install-cli.sh).
    """
    if let command {
        if command == "capabilities" {
            return """
            USAGE: \(tool) capabilities [--json] [OPTIONS]

            Report this library's current encode/decode/inspect support without reading files.
            --json writes one JSON document to stdout; diagnostics stay on stderr.
            Empty formats and false support values mean codec algorithms are unavailable.

            \(common)

            EXAMPLES
              \(tool) capabilities --json
              \(tool) capabilities --verbose=+++
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
      capabilities [--json]      Report actual library support (currently empty).
      help [command]             Show global or command-specific help.
      version                    Show the development version.
      \(reserved.joined(separator: ", "))
                                Reserved; codec algorithms are unavailable (exit 4).

    Requires Swift 6.2 or later to build; Apple OS baseline 26.0. CLI hosts: macOS/Linux.
    This development tool provides help/version/capabilities, not compression yet.

    \(common)

    EXAMPLES
      \(tool) -h
      \(tool) help capabilities
      \(tool) capabilities --json -vv
      \(tool) capabilities -verbose: 3
    """ + "\n"
}

private func write(_ text: String, to handle: FileHandle) throws {
    try handle.write(contentsOf: Data(text.utf8))
}

private func run() throws -> Int32 {
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
    guard options.command == "capabilities" else {
        try write("\(tool): unsupported feature: codec algorithms are not implemented; no input/output opened.\n", to: .standardError)
        return 4
    }
    let encoder = Encoder.capabilities
    let decoder = Decoder.capabilities
    let formats = Array(Set(encoder.formats + decoder.formats)).sorted()
    if options.json {
        let payload: [String: Any] = ["tool": tool, "version": version, "minimumAppleOS": "26.0",
            "canEncode": encoder.canEncode, "canDecode": decoder.canDecode,
            "canInspect": decoder.canInspect, "formats": formats]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
    } else {
        try write("\(tool) \(version)\nencode: \(encoder.canEncode)\ndecode: \(decoder.canDecode)\ninspect: \(decoder.canInspect)\nformats: \(formats.isEmpty ? "none" : formats.joined(separator: ", "))\n", to: .standardOutput)
    }
    try diagnostic(3, "advertised formats: \(formats.count); capability values read from the library")
    try diagnostic(4, "elapsed seconds: \(ProcessInfo.processInfo.systemUptime - start)")
    try diagnostic(5, "arguments validated; capability report emitted; no codec payload opened")
    return 0
}

// CLI process boundary only: a closed pipe is reported as exit 6, never SIGPIPE success.
_ = signal(SIGPIPE, SIG_IGN)
do { exit(try run()) }
catch {
    try? write("\(tool): output I/O failure.\n", to: .standardError)
    exit(6)
}

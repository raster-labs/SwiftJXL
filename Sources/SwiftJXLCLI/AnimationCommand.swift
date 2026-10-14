// SPDX-License-Identifier: Apache-2.0
import Foundation
import SwiftJXL
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private let timingKeys = ["--frame-duration", "--ticks-per-second", "--loop-count"]

func validateAnimationArguments(_ command: String, options: Options) throws {
    let values = options.values
    let encoding = options.animation || options.inputs.count > 1
    guard command == "encode" || (!encoding && !timingKeys.contains(where: { values[$0] != nil })) else {
        throw CodecError(.invalidArgument, "Multiple inputs and animation timing apply to encode only.")
    }
    guard encoding || !timingKeys.contains(where: { values[$0] != nil }) else {
        throw CodecError(.invalidArgument, "Timing requires multiple inputs or --animation.")
    }
    guard !options.allFrames || ["decode", "inspect", "validate"].contains(command),
          values["--frame"] == nil || command == "decode",
          !(options.allFrames && values["--frame"] != nil) else {
        throw CodecError(.invalidArgument, "Use --frame for decode, or --all-frames for decode/inspect/validate, exclusively.")
    }
    guard values["--max-frames"] == nil || encoding || options.allFrames || values["--frame"] != nil else {
        throw CodecError(.invalidArgument, "max-frames requires an animation operation.")
    }
    guard !options.inputs.contains(where: \.isEmpty), options.inputs.filter({ $0 == "-" }).count <= 1,
          options.inputs.count == 1 || !options.inputs.contains("-") else {
        throw CodecError(.invalidArgument, "Multi-input encoding requires named files.")
    }
    if command == "decode", options.allFrames {
        guard let output = values["--output"], output != "-", !output.isEmpty, !options.overwrite else {
            throw CodecError(.invalidArgument, "All-frame decoding requires a new output directory and does not allow overwrite.")
        }
    }
}

/// Retain only admitted owning frames. One deadline covers input, codec work
/// and output. All frames decode before publication, and metadata records exact
/// integer timing rather than approximating the rational clock with frame rate.
@concurrent func runAnimationCommand(_ command: String, options: Options,
    configuration: EncoderConfiguration, io: CommandIO,
    backend: ExecutionPolicy, copy: CopyPolicy, threads: Int) async throws -> Bool {
    let values = options.values
    let encoding = options.animation || options.inputs.count > 1
    guard encoding || options.allFrames || values["--frame"] != nil else { return false }
    func unsigned(_ text: String, positive: Bool = false) throws -> UInt32 {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let result = UInt32(text),
              !positive || result > 0 else { throw CodecError(.invalidArgument, "Invalid animation integer.") }
        return result
    }
    let frameLimit = try unsigned(values["--max-frames"] ?? "64", positive: true)
    guard frameLimit <= 256, options.inputs.count <= Int(frameLimit) else {
        throw CodecError(.resourceLimitExceeded, "Animation supports at most the requested limit, capped at 256 frames.")
    }
    func limits(retained: Int) throws -> ResourceLimits {
        let available = io.maximumMemoryBytes - CommandIO.overhead - retained
        guard available > 0 else { throw CodecError(.resourceLimitExceeded, "Animation command memory limit exceeded.") }
        return try ResourceLimits(maximumCompressedBytes: CommandIO.maximumInput,
            maximumPixels: 1024 * 1024 * Int(frameLimit), maximumDimension: 1024, maximumFrames: Int(frameLimit),
            maximumWorkers: threads, deadlineSeconds: max(io.remainingSeconds, Double.leastNonzeroMagnitude),
            maximumMemoryBytes: available)
    }
    let decoder = try Decoder(), output = values["--output"] ?? "-"
    if encoding {
        let durations = try (values["--frame-duration"] ?? "10").split(separator: ",", omittingEmptySubsequences: false)
            .map { try unsigned(String($0), positive: true) }
        guard durations.count == 1 || durations.count == options.inputs.count else {
            throw CodecError(.invalidArgument, "Frame-duration count must be one or match the input count.")
        }
        let clock = (values["--ticks-per-second"] ?? "100/1").split(separator: "/", omittingEmptySubsequences: false)
        guard clock.count == 2 else { throw CodecError(.invalidArgument, "ticks-per-second requires numerator/denominator.") }
        let timing = try AnimationEncodingOptions(ticksPerSecondNumerator: unsigned(String(clock[0]), positive: true),
            ticksPerSecondDenominator: unsigned(String(clock[1]), positive: true), loopCount: unsigned(values["--loop-count"] ?? "0"))
        let format = values["--input-format"] ?? ""
        var frames: [AnimationInputFrame] = [], retained = 0
        for (index, path) in options.inputs.enumerated() {
            try io.checkpoint()
            let readIO = CommandIO(deadline: io.deadline, maximumMemoryBytes: io.maximumMemoryBytes - retained)
            let data = try readIO.readInput(path)
            guard data.count <= (io.maximumMemoryBytes - CommandIO.overhead - retained) / 2 else {
                throw CodecError(.resourceLimitExceeded, "Animation input buffer exceeds remaining command memory.")
            }
            let remaining = try limits(retained: retained + data.count * 2)
            let image: Image
            if format == "nrrd" { image = try NRRD.parse(data, io: io).image(data, limits: remaining) }
            else if format == "jpeg-srgb" {
                image = try await decoder.decodeJPEG(data, interpretingAs: .srgb,
                    options: .init(resourceLimits: remaining, executionPolicy: backend, copyPolicy: copy)).image
            } else { image = try PNM.parse(data, io: io).image(data, srgb: format == "pnm-srgb", limits: remaining) }
            // Admit before multiplying/adding, including on 32-bit Watch builds.
            guard image.storage.byteCount <= (io.maximumMemoryBytes - CommandIO.overhead - retained) / 2 else {
                throw CodecError(.resourceLimitExceeded, "Retained animation input exceeds command memory.")
            }
            retained += image.storage.byteCount * 2
            frames.append(try AnimationInputFrame(image: image, durationTicks: durations.count == 1 ? durations[0] : durations[index]))
        }
        // Prevent replacing any source, including hard links to later frames.
        for path in options.inputs { try io.requireDistinctOutput(output, inputPath: path) }
        let result = try await Encoder(configuration: configuration).encodeAnimation(frames, animation: timing,
            options: .init(resourceLimits: limits(retained: retained), executionPolicy: backend, copyPolicy: copy))
        try io.publish(result.encoded.data, path: output, inputPath: options.inputs[0], overwrite: options.overwrite)
        if options.json {
            var report = timeline(result.timing, frames: frames.enumerated().map { ["index": $0.offset, "durationTicks": $0.element.durationTicks] })
            report["operation"] = "encode"; report["encodedBytes"] = result.encoded.data.count
            report["fidelity"] = configuration.mode == .lossless ? "exact-samples" : "lossy"
            try io.writeBytes(json(report), fd: STDERR_FILENO)
        }
        return true
    }
    guard let input = options.inputs.first, values["--input-format"] != "jpeg-srgb" else {
        throw CodecError(.invalidArgument, "Animation commands require JPEG XL input.")
    }
    let data = try io.readInput(input), bounded = try limits(retained: data.count * 2)
    let decodeOptions = DecodeOptions(resourceLimits: bounded, executionPolicy: backend, copyPolicy: copy)
    let format = values["--output-format"] ?? "pnm-srgb"
    if let raw = values["--frame"] {
        let index = try unsigned(raw)
        guard UInt64(index) <= UInt64(Int.max) else { throw CodecError(.invalidArgument, "Frame index exceeds the platform range.") }
        let result = try await decoder.decodeFrame(data, at: Int(index), options: decodeOptions)
        try requireRepresentable(result.decoded.image, format: format)
        try io.publish(path: output, inputPath: input, overwrite: options.overwrite) { fd in
            try writeFrame(result.decoded.image, format: format, fd: fd, io: io)
        }
        if options.json {
            try io.writeBytes(json(timeline(result.timing, frames: [["index": result.index, "startTick": result.startTick,
                "durationTicks": result.durationTicks]])), fd: STDERR_FILENO)
        }
        return true
    }
    let info = try decoder.inspectFrames(data, options: decodeOptions)
    let entries: [[String: Any]] = info.frames.map { ["index": $0.index, "startTick": $0.startTick,
        "durationTicks": $0.durationTicks, "width": $0.image.descriptor.width, "height": $0.image.descriptor.height,
        "meaningfulBits": $0.image.descriptor.meaningfulBits] }
    var report = timeline(info.timing, frames: entries)
    report["pixelPayloadValidated"] = command != "inspect"
    report["operation"] = command
    if command == "inspect" {
        try io.publish(json(report), path: output, inputPath: input, overwrite: options.overwrite)
        return true
    }
    // The first inspection is not retained during codec allocation except for
    // bounded scalar descriptors/timing. Charge a conservative per-frame bound.
    let decoded = try await decoder.decodeAll(data, options: .init(resourceLimits: limits(retained: data.count * 2 + info.frames.count * 65536),
        executionPolicy: backend, copyPolicy: copy))
    if command == "validate" {
        try io.publish(json(report), path: output, inputPath: input, overwrite: options.overwrite)
    } else {
        for frame in decoded.frames { try requireRepresentable(frame.decoded.image, format: format) }
        let suffix = format == "nrrd" ? "nrrd" : "pam"
        try io.publishDirectory(path: output) { directory in
            var names: [String] = []
            for frame in decoded.frames {
                let name = String(format: "frame-%06d.%@", frame.index, suffix)
                try io.publish(path: directory + "/" + name, inputPath: input, overwrite: false) { fd in
                    try writeFrame(frame.decoded.image, format: format, fd: fd, io: io)
                }
                names.append(name)
            }
            try io.publish(json(report), path: directory + "/timing.json", inputPath: input, overwrite: false)
            return names + ["timing.json"]
        }
        if options.json { try io.writeBytes(json(report), fd: STDERR_FILENO) }
    }
    return true
}

private func timeline(_ timing: AnimationTiming?, frames: [[String: Any]]) -> [String: Any] {
    var report: [String: Any] = ["format": "jpeg-xl", "frameCount": frames.count, "frames": frames]
    if let timing {
        report["ticksPerSecondNumerator"] = timing.ticksPerSecondNumerator
        report["ticksPerSecondDenominator"] = timing.ticksPerSecondDenominator
        report["loopCount"] = timing.loopCount; report["totalTicks"] = timing.totalTicks
    }
    return report
}
private func json(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) + Data([10])
}
private func requireRepresentable(_ image: Image, format: String) throws {
    if format == "nrrd" { try NRRD.requireRepresentable(image.descriptor, metadata: image.metadata) }
    else { try PNM.requireRepresentable(image.descriptor, metadata: image.metadata, srgb: format == "pnm-srgb") }
}
private func writeFrame(_ image: Image, format: String, fd: Int32, io: CommandIO) throws {
    if format == "nrrd" { try NRRD.write(image, fd: fd, io: io) }
    else { try PNM.write(image, srgb: format == "pnm-srgb", fd: fd, io: io) }
}

extension CommandIO {
    func requireDistinctOutput(_ output: String, inputPath: String) throws {
        guard output != "-" else { return }
        var target = stat(), source = stat()
        if stat(output, &target) == 0, stat(inputPath, &source) == 0,
           target.st_dev == source.st_dev, target.st_ino == source.st_ino {
            throw CodecError(.ioFailure, "Output aliases an animation source.")
        }
    }
    /// All payloads are staged first. The destination is created exclusively;
    /// on failure only entries created by this transaction are removed. Existing
    /// directories/files are never replaced, including a concurrent creation.
    func publishDirectory(path: String, body: (String) throws -> [String]) throws {
        try checkpoint()
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        var status = stat()
        guard lstat(target, &status) != 0, errno == ENOENT else {
            throw CodecError(.ioFailure, "Animation output directory already exists or is unavailable.")
        }
        let temporary = URL(fileURLWithPath: target).deletingLastPathComponent()
            .appendingPathComponent(".swiftjxl-frames-\(UUID().uuidString)").path
        guard mkdir(temporary, 0o700) == 0 else { throw CodecError(.ioFailure, "Cannot stage animation output.") }
        defer { try? FileManager.default.removeItem(atPath: temporary) }
        let names = try body(temporary)
        try checkpoint()
        guard mkdir(target, 0o700) == 0 else { throw CodecError(.ioFailure, "Cannot exclusively create animation output directory.") }
        var published: [String] = [], complete = false
        defer {
            if !complete {
                for file in published { _ = unlink(file) }
                _ = rmdir(target)
            }
        }
        for name in names {
            try checkpoint()
            guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
                throw CodecError(.internalFailure, "Invalid staged frame name.")
            }
            let final = target + "/" + name
            guard link(temporary + "/" + name, final) == 0 else { throw CodecError(.ioFailure, "Cannot publish animation frame.") }
            published.append(final)
        }
        try checkpoint()
        complete = true
    }
}

// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Whole-operation limits; individual codec stages receive only the remaining
/// capacity after all still-retained owners have been admitted.
package struct JPEGNativePolicy: Sendable {
    package let compressed: Int, coefficients: Int, workspace: Int, memory: Int
    package let metadata: Int, dimension: Int, pixels: Int, nesting: Int, icc: Int
    package let deadline: ContinuousClock.Instant
    package init(compressed: Int, coefficients: Int, workspace: Int, memory: Int,
                 metadata: Int, dimension: Int, pixels: Int, nesting: Int, icc: Int = 4 * 1024 * 1024,
                 deadline: ContinuousClock.Instant) throws {
        guard [compressed, coefficients, workspace, memory, metadata, dimension, pixels, nesting, icc].allSatisfy({ $0 > 0 }) else {
            throw JPEGEntropyError.resourceLimit
        }
        self.compressed = min(compressed, 64 * 1024 * 1024)
        self.coefficients = min(coefficients, 64 * 1024 * 1024)
        self.workspace = workspace; self.memory = memory; self.metadata = min(metadata, 8 * 1024 * 1024)
        self.dimension = min(dimension, 2048); self.pixels = min(pixels, 2048 * 2048)
        self.nesting = min(nesting, 32); self.icc = min(icc, 4 * 1024 * 1024); self.deadline = deadline
    }
    package func checkpoint() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw JPEGEntropyError.resourceLimit }
    }
}

package struct JPEGNativeResult: Sendable {
    package let data: Data
    /// Known compressed-buffer assembly copies; coefficient transformations are
    /// algorithm workspace, not a full-pixel or legacy-adapter handoff copy.
    package let containerCopyBytes: Int
}

package enum JPEGNativeTranscode {
    package static func encode(_ source: Data, policy: JPEGNativePolicy) throws -> JPEGNativeResult {
        var operation = try NativeOperation(source: source, policy: policy)
        return try operation.encode()
    }
    package static func reconstruct(_ source: Data, policy: JPEGNativePolicy) throws -> JPEGNativeResult {
        var operation = try NativeOperation(source: source, policy: policy)
        return try operation.reconstruct()
    }
}

private struct NativeOperation {
    let source: Data
    let policy: JPEGNativePolicy
    var retained = 0
    let inputBound: Int

    init(source: Data, policy: JPEGNativePolicy) throws {
        try policy.checkpoint()
        guard source.count <= policy.compressed, source.count <= policy.memory / 2 else { throw JPEGEntropyError.resourceLimit }
        self.source = source; self.policy = policy; inputBound = source.count * 2
        // Container/marker inventory is capped at 4096 entries. Also retain a
        // separate allowance for Brotli dictionary/context tables after decode.
        try reserve(2 * 1024 * 1024)
    }
    func available() throws -> Int {
        try policy.checkpoint()
        let result = min(policy.workspace - retained, policy.memory - inputBound - retained)
        guard result > 0 else { throw JPEGEntropyError.resourceLimit }
        return result
    }
    mutating func reserve(_ bytes: Int) throws {
        guard bytes >= 0, bytes <= (try available()) else { throw JPEGEntropyError.resourceLimit }
        retained += bytes
    }
    func copy(_ range: Range<Int>) -> Data {
        source.subdata(in: (source.startIndex + range.lowerBound)..<(source.startIndex + range.upperBound))
    }
    func multiply(_ count: Int, _ stride: Int) throws -> Int { try ScalarOperationBudget.product(count, stride) }
    func metadataPolicy() throws -> JBRDPolicy {
        try JBRDPolicy(maximumInputBytes: min(policy.compressed, 4 * 1024 * 1024),
            maximumPayloadBytes: policy.metadata, maximumMemoryBytes: available(),
            deadline: policy.deadline)
    }
    func bridgePolicy(remainingMetadataBytes: Int? = nil) throws -> JPEGBridgePolicy {
        try JPEGBridgePolicy(maximumCoefficientBytes: policy.coefficients, maximumMemoryBytes: available(),
            maximumDimension: policy.dimension, maximumPixels: policy.pixels, maximumNestingDepth: policy.nesting,
            maximumICCBytes: min(policy.icc, max(1, remainingMetadataBytes ?? policy.metadata)),
            deadline: policy.deadline)
    }
    func dimensions(_ width: Int, _ height: Int) throws {
        guard width > 0, height > 0, width <= policy.dimension, height <= policy.dimension,
              width <= policy.pixels / height else { throw JPEGEntropyError.resourceLimit }
    }
    mutating func retainMetadata(_ box: JBRDBox) throws {
        try reserve(multiply(box.markerOrder.count, 1024)); try reserve(multiply(box.paddingBits.count, 4))
        for scan in box.scanInfo {
            try reserve(multiply(scan.resetPoints.count, 32)); try reserve(multiply(scan.extraZeroRuns.count, 32))
        }
        for group in [box.appData, box.comData, box.interMarkerData, [box.tailData]] {
            for bytes in group { try reserve(multiply(bytes.count, 4)) }
        }
        try reserve(16 * 1024)
    }
    mutating func encode() throws -> JPEGNativeResult {
        // Inspect dimensions and ancillary bytes before coefficient allocation.
        var segments = try JPEGSegmentReader(source, maximumInputBytes: policy.compressed, deadline: policy.deadline)
        var frame: JPEGFrameLayout?, ancillary = 0, adobe: UInt8?
        var iccFragments: [Int: Range<Int>] = [:], iccCount = 0, iccBytes = 0
        while let segment = try segments.next() {
            try policy.checkpoint()
            if (0xc0...0xc2).contains(segment.markerByte) {
                guard frame == nil else { throw JPEGEntropyError.unsupported }
                let value = try JPEGFrameLayout(data: source, segment: segment, maximumCoefficientBytes: policy.coefficients)
                try dimensions(value.width, value.height); frame = value
            }
            ancillary = try ScalarOperationBudget.sum(ancillary, segment.payloadRange.count + segment.fillRange.count)
            guard ancillary <= policy.metadata else { throw JPEGEntropyError.resourceLimit }
            if segment.markerByte == 0xe2 || segment.markerByte == 0xee {
                let range = segment.payloadRange
                func begins(_ prefix: [UInt8]) -> Bool {
                    range.count >= prefix.count && prefix.enumerated().allSatisfy { source[source.startIndex + range.lowerBound + $0.offset] == $0.element }
                }
                if segment.markerByte == 0xe2, begins(Array("ICC_PROFILE\0".utf8)) {
                    guard range.count >= 14 else { throw JPEGEntropyError.malformed }
                    let index = Int(source[source.startIndex + range.lowerBound + 12])
                    let count = Int(source[source.startIndex + range.lowerBound + 13])
                    guard index > 0, index <= count, iccFragments[index] == nil,
                          iccCount == 0 || iccCount == count else { throw JPEGEntropyError.malformed }
                    let body = (range.lowerBound + 14)..<range.upperBound
                    guard body.count <= policy.icc - iccBytes else { throw JPEGEntropyError.resourceLimit }
                    iccBytes += body.count; iccCount = count; iccFragments[index] = body
                }
                if segment.markerByte == 0xee, begins(Array("Adobe".utf8)) {
                    guard range.count == 12, adobe == nil else { throw JPEGEntropyError.unsupported }
                    adobe = source[source.startIndex + range.lowerBound + 11]
                    guard adobe == 0 || adobe == 1 else { throw JPEGEntropyError.unsupported }
                }
            }
        }
        guard let frame, let tail = segments.trailingRange else { throw JPEGEntropyError.malformed }
        guard tail.count <= policy.metadata - ancillary else { throw JPEGEntropyError.resourceLimit }
        var iccProfile: Data?
        if iccCount > 0 {
            guard iccFragments.count == iccCount else { throw JPEGEntropyError.malformed }
            try reserve(multiply(iccBytes, 4))
            var bytes = Data(); bytes.reserveCapacity(iccBytes)
            for index in 1...iccCount {
                try policy.checkpoint()
                guard let range = iccFragments[index] else { throw JPEGEntropyError.malformed }
                bytes.append(copy(range))
            }
            guard bytes.count >= 128, bytes.prefix(4).reduce(0, { ($0 << 8) | Int($1) }) == bytes.count,
                  bytes[36..<40] == Data("acsp".utf8) else { throw JPEGEntropyError.malformed }
            guard bytes[16..<20] == Data((frame.components.count == 1 ? "GRAY" : "RGB ").utf8) else {
                throw JPEGEntropyError.unsupported
            }
            iccProfile = bytes
        }
        let decoded = try JPEGCoefficientDecoder.decode(source, policy: JPEGCoefficientPolicy(
            maximumInputBytes: policy.compressed, maximumCoefficientBytes: policy.coefficients,
            maximumMemoryBytes: available(), deadline: policy.deadline))
        try reserve(multiply(frame.coefficientCount, 8))
        try reserve(multiply(decoded.padding.count, 128)); try reserve(multiply(decoded.scans.count, 1024))
        for scan in decoded.scans {
            try reserve(multiply(scan.resetPoints.count, 32)); try reserve(multiply(scan.extraZeroRuns.count, 32))
        }
        let metadata = try JPEGReconstructionMetadata.encode(decoded, policy: metadataPolicy())
        guard Set(metadata.box.components.map(\.quantIdx)).count == metadata.box.quant.count else {
            throw JPEGEntropyError.unsupported
        }
        try retainMetadata(metadata.box); try reserve(multiply(metadata.bundle.count, 2))
        let rgb = frame.components.map(\.id) == [82, 71, 66]
        let colour: ColorTransform = adobe == 0 || (adobe == nil && rgb) ? .none : .yCbCr
        let view = try JPEGBridgeCoefficients(frame: frame, coefficients: decoded.coefficients,
            quantisation: decoded.quantisation, colourTransform: colour, policy: bridgePolicy())
        let codestream = try JPEGBridgeFrameWriter.write(view, maximumOutputBytes: policy.compressed, iccProfile: iccProfile, policy: bridgePolicy())
        try reserve(multiply(codestream.count, 2))
        let size = try ScalarOperationBudget.sum(48, ScalarOperationBudget.sum(metadata.bundle.count, codestream.count))
        guard size <= policy.compressed else { throw JPEGEntropyError.resourceLimit }
        try reserve(multiply(size, 2))
        var output = Data([0,0,0,12,0x4a,0x58,0x4c,0x20,0x0d,0x0a,0x87,0x0a,
                           0,0,0,20,0x66,0x74,0x79,0x70,0x6a,0x78,0x6c,0x20,0,0,0,0,0x6a,0x78,0x6c,0x20])
        output.reserveCapacity(size)
        for (type, bytes) in [("jbrd", metadata.bundle), ("jxlc", codestream)] {
            let n = UInt32(bytes.count + 8)
            output.append(contentsOf: [UInt8(truncatingIfNeeded: n >> 24), UInt8(truncatingIfNeeded: n >> 16),
                UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)])
            output.append(contentsOf: type.utf8)
            for offset in stride(from: 0, to: bytes.count, by: 4096) {
                try policy.checkpoint(); output.append(bytes[(bytes.startIndex + offset)..<(bytes.startIndex + min(offset + 4096, bytes.count))])
            }
        }
        try policy.checkpoint()
        return JPEGNativeResult(data: output, containerCopyBytes: metadata.bundle.count + codestream.count)
    }
    mutating func reconstruct() throws -> JPEGNativeResult {
        guard case .iso(let boxes) = try parseJXLContainer(source, checkpoint: policy.checkpoint) else {
            throw JPEGEntropyError.unsupported
        }
        guard let fileType = boxes.first, fileType.payloadRange.count >= 12,
              fileType.payloadRange.count % 4 == 0 else { throw JPEGEntropyError.malformed }
        guard fileType.payloadRange.count <= policy.metadata else { throw JPEGEntropyError.resourceLimit }
        try reserve(multiply(fileType.payloadRange.count, 2))
        let typeBytes = copy(fileType.payloadRange)
        var compatible = false
        for offset in stride(from: 8, to: typeBytes.count, by: 4) {
            if offset & 4095 == 0 { try policy.checkpoint() }
            if typeBytes[offset..<(offset + 4)] == Data("jxl ".utf8) { compatible = true }
        }
        guard typeBytes.prefix(4) == Data("jxl ".utf8), typeBytes[4..<8] == Data([0,0,0,0]),
              compatible else {
            throw JPEGEntropyError.unsupported
        }
        let levels = boxes.filter { $0.type == "jxll" }
        guard levels.count <= 1 else { throw JPEGEntropyError.malformed }
        if let level = levels.first {
            guard level.payloadRange.count == 1, [UInt8(5), 10].contains(source[source.startIndex + level.payloadRange.lowerBound]) else {
                throw JPEGEntropyError.malformed
            }
        }
        let reconstruction = boxes.filter { $0.type == "jbrd" }
        guard reconstruction.count == 1 else { throw JPEGEntropyError.malformed }
        // Every copied compressed byte is admitted before extraction.
        try reserve(multiply(source.count, 4))
        let bundle = copy(reconstruction[0].payloadRange)
        let parsed = try JBRDBoxReader.read(bundle, policy: metadataPolicy())
        try reserve(parsed.reservedBytes)
        var external = JBRDExternalMetadata()
        var ancillaryBytes = try ScalarOperationBudget.sum(bundle.count, typeBytes.count)
        guard ancillaryBytes <= policy.metadata else { throw JPEGEntropyError.resourceLimit }
        for box in boxes where !["ftyp", "jbrd", "jxlc", "jxlp", "jxll"].contains(box.type) {
            try policy.checkpoint()
            var type = box.type, payload = copy(box.payloadRange)
            if type == "brob" {
                guard payload.count >= 4 else { throw JPEGEntropyError.malformed }
                type = String(decoding: payload.prefix(4), as: UTF8.self)
                let expected: Int
                if type == "Exif" {
                    let sizes = parsed.box.appMarkerType.indices.filter { parsed.box.appMarkerType[$0] == .exif }.map { parsed.box.appData[$0].count - 9 }
                    guard let size = sizes.first, size >= 0, sizes.allSatisfy({ $0 == size }) else { throw JPEGEntropyError.malformed }
                    expected = size + 4 // TIFF-offset prefix; qualified form has offset zero.
                } else if type == "xml " {
                    let sizes = parsed.box.appMarkerType.indices.filter { parsed.box.appMarkerType[$0] == .xmp }.map { parsed.box.appData[$0].count - 32 }
                    guard let size = sizes.first, size >= 0, sizes.allSatisfy({ $0 == size }) else { throw JPEGEntropyError.malformed }
                    expected = size
                } else { throw JPEGEntropyError.unsupported }
                guard expected <= policy.metadata - ancillaryBytes else { throw JPEGEntropyError.resourceLimit }
                payload = try BrotliDecoder.decode(Data(payload.dropFirst(4)), expectedOutputSize: expected,
                    policy: BrotliPolicy(maximumInputBytes: policy.compressed, maximumOutputBytes: expected,
                        maximumMemoryBytes: available(), deadline: policy.deadline))
                try reserve(multiply(payload.count, 4))
            }
            ancillaryBytes = try ScalarOperationBudget.sum(ancillaryBytes, payload.count)
            guard ancillaryBytes <= policy.metadata else { throw JPEGEntropyError.resourceLimit }
            switch type {
            case "Exif":
                guard external.exifTIFF == nil, payload.count >= 4 else { throw JPEGEntropyError.malformed }
                let offset = payload.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
                guard offset <= payload.count - 4 else { throw JPEGEntropyError.malformed }
                external.exifTIFF = Data(payload.dropFirst(4 + offset))
            case "xml ":
                guard external.xmp == nil else { throw JPEGEntropyError.malformed }
                external.xmp = payload
            default: throw JPEGEntropyError.unsupported
            }
        }
        let codestream = try extractCodestream(from: boxes, in: source, checkpoint: policy.checkpoint)
        let frame = try JPEGBridgeFrameReader.read(codestream,
            policy: bridgePolicy(remainingMetadataBytes: policy.metadata - ancillaryBytes))
        for plane in frame.coefficients { try reserve(multiply(plane.count, 8)) }
        external.iccProfile = frame.iccProfile
        if let icc = frame.iccProfile {
            guard icc.count <= policy.metadata - ancillaryBytes else { throw JPEGEntropyError.resourceLimit }
            try reserve(multiply(icc.count, 2))
        }
        let metadata = try JBRDBoxReader.readResolved(bundle, external: external, policy: metadataPolicy())
        try retainMetadata(metadata)
        let resolved = try frame.resolve(metadata)
        let result = try JPEGReconstructionWriter.write(coefficients: frame.coefficients, metadata: resolved,
            policy: JPEGReconstructionPolicy(maximumOutputBytes: policy.compressed, maximumCoefficientBytes: policy.coefficients,
                maximumMemoryBytes: available(), deadline: policy.deadline))
        try policy.checkpoint()
        return JPEGNativeResult(data: result, containerCopyBytes: bundle.count + codestream.count)
    }
}

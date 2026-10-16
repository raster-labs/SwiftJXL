// SPDX-License-Identifier: Apache-2.0
// Expected samples come from deterministic synthetic T.81 source construction,
// not this decoder. See Scripts/TestSupport/jpeg-extended-fixtures.py.
import Foundation
import Testing
import SwiftJXL
@testable import SwiftJXLCore

struct JPEGExtendedPixelTests {
    struct Fixture: Decodable {
        let name: String
        let width: Int
        let height: Int
        let precision: Int
        let channels: Int
        let samples: [UInt16]
        let interpretation: String
        let fidelity: String
        let orientation: Int?
    }
    func file(_ name: String, _ ext: String = "jpg") throws -> Data {
        try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "JPEGExtended")))
    }
    func fixtures() throws -> [Fixture] { try JSONDecoder().decode([Fixture].self, from: file("manifest", "json")) }
    func samples(_ image: Image) throws -> [UInt16] {
        let d = image.descriptor
        return try image.storage.withUnsafeBytes { bytes in
            var result: [UInt16] = []
            for y in 0..<d.height { for x in 0..<d.width { for c in d.components.indices {
                guard let plane = d.planes.first(where: { $0.components.contains(c) }),
                      let index = plane.components.firstIndex(of: c) else { throw CodecError(.internalFailure, "Missing test plane") }
                let p = plane.offset + y * plane.rowBytes + x * plane.pixelStride + index * plane.sampleStride
                let v: UInt16
                if d.storageBits == 8 { v = UInt16(bytes[p]) }
                else if d.byteOrder == .bigEndian { v = UInt16(bytes[p]) * 256 + UInt16(bytes[p+1]) }
                else { v = UInt16(bytes[p]) + UInt16(bytes[p+1]) * 256 }
                result.append(v)
            } } }
            return result
        }
    }
    @Test func extendedSyntheticSamplesAndCallerStorage() async throws {
        let decoder = try Decoder()
        for fixture in try fixtures() {
            let interpretation: JPEGPixelInterpretation = fixture.interpretation == "srgb" ? .srgb : .embedded(orientation: .preserve)
            let input = try file(fixture.name)
            let info = try decoder.inspectJPEG(input, interpretingAs: interpretation)
            #expect(info.descriptor.meaningfulBits == fixture.precision)
            let result = try await decoder.decodeJPEG(input, interpretingAs: interpretation)
            #expect(try samples(result.image) == fixture.samples, "Fixture \(fixture.name)")
            #expect(result.report.fidelity == (fixture.fidelity == "lossless" ? .exactSamples : .lossy))
            #expect(result.image.descriptor.storageBits == (fixture.precision <= 8 ? 8 : 16))
            #expect(result.report.pixelAllocationCount == 1 && result.report.copyEvents.isEmpty)
            let d = result.image.descriptor
            for order in [ByteOrder.littleEndian, .bigEndian] {
                var planes: [PlaneDescriptor] = [], end = 6
                for c in d.components.indices {
                    let row = d.width * 4 + 8
                    let capacity = end + row * d.height + 4
                    planes.append(try PlaneDescriptor(width: d.width, height: d.height, components: [c], offset: end,
                        sampleStride: 2, pixelStride: 4, rowBytes: row, byteCount: capacity))
                    end = capacity + 6
                }
                let descriptor = try ImageDescriptor(width: d.width, height: d.height, storageBits: 16,
                    meaningfulBits: d.meaningfulBits, byteOrder: order, components: d.components, colour: d.colour,
                    planes: planes, iccProfile: d.iccProfile)
                let owner = try ImageDestination.allocate(descriptor: descriptor)
                let audit = ScalarStorageAudit()
                let into = try await ScalarStorageAudit.$current.withValue(audit) {
                    try await decoder.decodeJPEG(input, interpretingAs: interpretation, into: owner)
                }
                if fixture.name.hasPrefix("sof3-") {
                    #expect(audit.snapshot.workingPlaneBytes == fixture.width * fixture.channels * MemoryLayout<Int>.stride)
                    #expect(audit.snapshot.finalPixelAllocations == 0)
                }
                #expect(try samples(into.image) == fixture.samples)
                #expect(into.image.storage.allocationID == owner.storage.allocationID)
                #expect(into.report.pixelAllocationCount == 0 && into.report.copyEvents.isEmpty)
            }
        }
    }
    @Test func embeddedColourAndExplicitOrientation() async throws {
        let decoder = try Decoder()
        for fixture in try fixtures() where fixture.interpretation != "srgb" {
            let input = try file(fixture.name)
            do { _ = try decoder.inspectJPEG(input, interpretingAs: .srgb); Issue.record("Silently overrode embedded interpretation") }
            catch let error as CodecError { #expect(error.category == .unsupportedFeature) }
            let preserved = try await decoder.decodeJPEG(input, interpretingAs: .embedded(orientation: .preserve),
                options: .init(metadataPolicy: .discardAncillary))
            let applied = try await decoder.decodeJPEG(input, interpretingAs: .embedded(orientation: .apply),
                options: .init(metadataPolicy: .discardAncillary))
            if let orientation = fixture.orientation {
                #expect(preserved.image.metadata.entries["jpeg.orientation"] == Data([UInt8(orientation)]))
                #expect(preserved.image.metadata.requiredKeys.contains("jpeg.exif"))
                #expect(applied.image.metadata.entries["jpeg.orientation"] == Data([1]))
                let expected: [UInt16]
                switch orientation {
                case 1: expected = [1,2,3,4,5,6]
                case 2: expected = [3,2,1,6,5,4]
                case 3: expected = [6,5,4,3,2,1]
                case 4: expected = [4,5,6,1,2,3]
                case 5: expected = [1,4,2,5,3,6]
                case 6: expected = [4,1,5,2,6,3]
                case 7: expected = [6,3,5,2,4,1]
                default: expected = [3,6,2,5,1,4]
                }
                #expect(try samples(applied.image) == expected)
                #expect(applied.image.descriptor.width == (orientation >= 5 ? 2 : 3))
                if orientation > 1 {
                    #expect(applied.image.metadata.entries["jpeg.sourceExif"] == preserved.image.metadata.entries["jpeg.exif"])
                    #expect(applied.image.metadata.requiredKeys.contains("jpeg.sourceExif"))
                } else {
                    #expect(applied.image.metadata == preserved.image.metadata)
                    #expect(applied.image.metadata.entries["jpeg.sourceExif"] == nil)
                }
            } else {
                #expect(preserved.image.descriptor.iccProfile == (try file("gray", "icc")))
                #expect(applied.image.descriptor.iccProfile == preserved.image.descriptor.iccProfile)
                let limits = try ResourceLimits(maximumICCBytes: 1)
                do { _ = try decoder.inspectJPEG(input, interpretingAs: .embedded(orientation: .preserve), options: .init(resourceLimits: limits)); Issue.record("Ignored ICC bound") }
                catch let error as CodecError { #expect(error.category == .resourceLimitExceeded) }
            }
        }
        do { _ = try decoder.inspectJPEG(file("sof3-p12-predictor1-pt0"), interpretingAs: .embedded(orientation: .preserve)); Issue.record("Invented embedded colour") }
        catch let error as CodecError { #expect(error.category == .unsupportedFeature) }
    }
    @Test func malformedExtendedHeadersAndPrecisionReject() async throws {
        let decoder = try Decoder()
        let valid = try file("sof3-p16-predictor4-pt0")
        // SOF precision, sampling and selector; each SOS predictor/point transform.
        var mutations: [Data] = [try file("malformed-out-of-range", "invalid")]
        for (offset, byte) in [(6, UInt8(1)), (13, UInt8(0x21)), (14, UInt8(1))] {
            var m = valid; m[offset] = byte; mutations.append(m)
        }
        var reader = try JPEGSegmentReader(valid)
        while let segment = try reader.next() {
            guard segment.markerByte == 0xda else { continue }
            for (offset, byte) in [(segment.payloadRange.upperBound - 3, UInt8(0)),
                                   (segment.payloadRange.upperBound - 1, UInt8(16)),
                                   (segment.payloadRange.lowerBound + 2, UInt8(1))] {
                var m = valid; m[offset] = byte; mutations.append(m)
            }
        }
        for input in mutations {
            do { _ = try await decoder.decodeJPEG(input, interpretingAs: .srgb); Issue.record("Accepted malformed extended JPEG") }
            catch let error as CodecError { #expect([.malformedInput, .unsupportedFeature].contains(error.category)) }
        }
        let dct = try file("dct12-False-0-0")
        do {
            _ = try JPEGCoefficientDecoder.decode(dct, policy: .init())
            Issue.record("Broadened reversible transcode precision implicitly")
        } catch JPEGFrameError.unsupported {}
        let limits = try ResourceLimits(maximumMetadataBytes: 32)
        do { _ = try decoder.inspectJPEG(file("exif-6-True"), interpretingAs: .embedded(orientation: .apply), options: .init(resourceLimits: limits)); Issue.record("Ignored Exif bound") }
        catch let error as CodecError { #expect(error.category == .resourceLimitExceeded) }
    }
    @Test func malformedMetadataRestartsAndCancelledPublication() async throws {
        let decoder = try Decoder()
        let exif = try file("exif-6-True"), icc = try file("icc-gray")
        var cases: [(Data, JPEGPixelInterpretation)] = []
        for source in [exif, icc] {
            var reader = try JPEGSegmentReader(source)
            while let segment = try reader.next() {
                let r = segment.payloadRange
                if segment.markerByte == 0xe1 {
                    // Invalid orientation and a cyclic next-IFD pointer.
                    var badOrientation = source; badOrientation[r.lowerBound + 24] = 9
                    cases.append((badOrientation, .embedded(orientation: .apply)))
                    var cycle = source; cycle[r.lowerBound + 40] = 8
                    cases.append((cycle, .embedded(orientation: .preserve)))
                    var offset = source
                    for p in (r.lowerBound + 10)..<(r.lowerBound + 14) { offset[p] = 255 }
                    cases.append((offset, .embedded(orientation: .preserve)))
                }
                if segment.markerByte == 0xe2 {
                    var badCount = source; badCount[r.lowerBound + 13] = 0
                    cases.append((badCount, .embedded(orientation: .preserve)))
                    let duplicate = source.prefix(2) + source[segment.markerRange.lowerBound..<r.upperBound] + source.dropFirst(2)
                    cases.append((duplicate, .embedded(orientation: .preserve)))
                }
            }
        }
        var restart = try file("sof3-p12-predictor4-pt0")
        if let p = restart.indices.dropLast().first(where: { restart[$0] == 255 && restart[$0+1] == 0xd0 }) {
            restart[p+1] = 0xd1; cases.append((restart, .srgb))
        } else { Issue.record("Generator omitted restart boundary") }
        for (source, interpretation) in cases {
            do { _ = try await decoder.decodeJPEG(source, interpretingAs: interpretation); Issue.record("Accepted malformed metadata or restart") }
            catch let error as CodecError { #expect([.malformedInput, .resourceLimitExceeded, .unsupportedFeature].contains(error.category)) }
        }
        let input = try file("sof3-p16-predictor4-pt0")
        let descriptor = try decoder.inspectJPEG(input, interpretingAs: .srgb).descriptor
        let destination = try ImageDestination.allocate(descriptor: descriptor)
        let cancelled = Task {
            try await decoder.decodeJPEG(input, interpretingAs: .srgb, into: destination,
                options: .init(progress: { update in
                    if update.phase == .completed { withUnsafeCurrentTask { $0?.cancel() } }
                }))
        }
        do { _ = try await cancelled.value; Issue.record("Published cancelled high precision JPEG") }
        catch is CancellationError {}
        do { _ = try destination.write { _ in }; Issue.record("Reused invalidated destination") }
        catch let error as CodecError { #expect(error.category == .storageUnavailable) }
    }

    @Test func callerAllocationAndProfileAreAdmittedBeforeJPEGParsing() async throws {
        let decoder = try Decoder()
        for embedded in [false, true] {
            let source = try file(embedded ? "icc-gray" : "sof3-p12-predictor1-pt0")
            let interpretation: JPEGPixelInterpretation = embedded ? .embedded(orientation: .preserve) : .srgb
            let descriptor = try decoder.inspectJPEG(source, interpretingAs: interpretation).descriptor
            for malformed in [false, true] {
                // Retained caller capacity, not merely required raster bytes,
                // counts together with compressed input and the caller's ICC.
                let owner = try OwnedImageStorage(byteCount: 128 * 1024)
                let destination = try ImageDestination(descriptor: descriptor, storage: owner)
                var input = source
                if malformed { input[0] = 0 } // parsing would otherwise fail first
                let limit = owner.byteCount + input.count + (descriptor.iccProfile?.count ?? 0) - 1
                let limits = try ResourceLimits(maximumMemoryBytes: limit)
                do {
                    _ = try await decoder.decodeJPEG(input, interpretingAs: interpretation, into: destination,
                        options: .init(resourceLimits: limits))
                    Issue.record("JPEG parsing ignored retained caller storage/profile")
                } catch let error as CodecError { #expect(error.category == .resourceLimitExceeded) }
                // Pre-parse admission never starts destination mutation. Its
                // reserved owner remains usable under a sufficient budget.
                let retry = try await decoder.decodeJPEG(source, interpretingAs: interpretation, into: destination)
                #expect(retry.image.storage.allocationID == owner.allocationID)
                #expect(retry.report.pixelAllocationCount == 0 && retry.report.copyEvents.isEmpty)
            }
        }
    }

    @Test func parserWorkspacePrecedesICCFragmentCollection() throws {
        let profile = try file("gray", "icc"), source = try file("sof3-p12-predictor1-pt0")
        var fragments = Data(), firstFragment = Data()
        for index in 1...255 {
            var payload = Data("ICC_PROFILE\0".utf8)
            payload.append(contentsOf: [UInt8(index), 255])
            payload.append(profile[((index - 1) * profile.count / 255)..<(index * profile.count / 255)])
            let length = payload.count + 2
            let fragment = Data([255, 0xe2, UInt8(length >> 8), UInt8(length & 255)]) + payload
            fragments.append(fragment)
            if index == 1 { firstFragment = fragment }
        }
        let valid = Data(source.prefix(2)) + fragments + source.dropFirst(2)
        // The duplicate is reached only after all 255 range records have been
        // collected. Its error distinguishes early admission from late denial.
        let duplicate = Data(source.prefix(2)) + fragments + firstFragment + source.dropFirst(2)
        let decoder = try Decoder(), interpretation = JPEGPixelInterpretation.embedded(orientation: .preserve)
        #expect(try decoder.inspectJPEG(valid, interpretingAs: interpretation).descriptor.iccProfile == profile)
        do { _ = try decoder.inspectJPEG(duplicate, interpretingAs: interpretation); Issue.record("Accepted duplicate ICC fragment") }
        catch let error as CodecError { #expect(error.category == .malformedInput) }
        for input in [valid, duplicate] {
            let limits = [try ResourceLimits(maximumWorkspaceBytes: 64 * 1024 - 1),
                try ResourceLimits(maximumMemoryBytes: input.count + 64 * 1024 - 1)]
            for limit in limits {
                do {
                    _ = try decoder.inspectJPEG(input, interpretingAs: interpretation, options: .init(resourceLimits: limit))
                    Issue.record("Collected ICC fragments before parser admission")
                } catch let error as CodecError { #expect(error.category == .resourceLimitExceeded) }
            }
        }
        let budget = try ScalarOperationBudget(retainedBytes: valid.count, maximumWorkspaceBytes: 1024 * 1024,
            maximumMemoryBytes: 2 * 1024 * 1024, maximumDecodedBytes: 1024 * 1024,
            maximumCompressedBytes: 1024 * 1024, deadline: .now.advanced(by: .seconds(30)))
        let frame = try JPEGPixelFrame(valid, budget: budget, maximumDimension: 2048, maximumPixels: 2048 * 2048,
            maximumMetadataBytes: 1024 * 1024, maximumICCBytes: 1024 * 1024, maximumNestingDepth: 32,
            embeddedInterpretation: true, discardAncillary: false)
        // Moving the fixed allowance earlier must not double-charge it.
        #expect(budget.reservedWorkspaceBytes == 64 * 1024 + profile.count * 3
            + frame.frame.width * frame.frame.components.count * 32)
    }

    @Test func eightBitDCTScratchRemainsByteSized() async throws {
        let input = try Data(contentsOf: #require(Bundle.module.url(forResource: "420", withExtension: "jpg", subdirectory: "JPEG")))
        var reader = try JPEGSegmentReader(input), frame: JPEGFrameLayout?
        while let segment = try reader.next() {
            if (0xc0...0xc2).contains(segment.markerByte) {
                frame = try JPEGFrameLayout(data: input, segment: segment, maximumCoefficientBytes: 64 * 1024 * 1024)
            }
        }
        let geometry = try #require(frame), decoder = try Decoder()
        let destination = try ImageDestination.allocate(descriptor: decoder.inspectJPEG(input, interpretingAs: .srgb).descriptor)
        let audit = ScalarStorageAudit()
        let value = try await ScalarStorageAudit.$current.withValue(audit) {
            try await decoder.decodeJPEG(input, interpretingAs: .srgb, into: destination)
        }
        #expect(audit.snapshot.workingPlaneBytes == geometry.coefficientCount)
        #expect(audit.snapshot.finalPixelAllocations == 0 && value.report.pixelAllocationCount == 0)
    }

    @Test func ancillaryDiscardSummaryPreservesRequiredInterpretation() async throws {
        struct Summary: Decodable {
            struct Item: Decodable, Equatable {
                let kind: String
                let count: Int
                let payloadBytes: Int
            }
            let version: Int
            let items: [Item]
        }
        func marker(_ code: UInt8, _ payload: Data) -> Data {
            let n = payload.count + 2
            return Data([255, code, UInt8(n >> 8), UInt8(n & 255)]) + payload
        }
        let iccSource = try file("icc-gray"), exifSource = try file("exif-6-True")
        var reader = try JPEGSegmentReader(exifSource), exif: Data?
        while let segment = try reader.next() {
            if segment.markerByte == 0xe1 { exif = Data(exifSource[segment.payloadRange]) }
        }
        let exifPayload = try #require(exif)
        let app = marker(0xe3, Data([1,2,3])) + marker(0xe3, Data([4,5,6,7]))
        let comments = marker(0xfe, Data([8,9,10,11,12]))
        var input = Data(iccSource.prefix(2))
        input.append(marker(0xe1, exifPayload)); input.append(app); input.append(comments)
        input.append(iccSource.dropFirst(2)); input.append(contentsOf: [13,14])
        let decoder = try Decoder(), interpretation = JPEGPixelInterpretation.embedded(orientation: .preserve)
        do { _ = try decoder.inspectJPEG(input, interpretingAs: interpretation); Issue.record("Default preservation dropped ancillary data") }
        catch let error as CodecError { #expect(error.category == .unsupportedFeature) }
        let options = DecodeOptions(metadataPolicy: .discardAncillary)
        let info = try decoder.inspectJPEG(input, interpretingAs: interpretation, options: options)
        let allocated = try await decoder.decodeJPEG(input, interpretingAs: interpretation, options: options)
        let destination = try ImageDestination.allocate(descriptor: info.descriptor)
        let into = try await decoder.decodeJPEG(input, interpretingAs: interpretation, into: destination, options: options)
        #expect(info.metadata == allocated.image.metadata && into.image.metadata == info.metadata)
        #expect(try samples(into.image) == [1,2,3,4,5,6])
        #expect(into.image.storage.allocationID == destination.storage.allocationID)
        #expect(info.descriptor.iccProfile == (try file("gray", "icc")))
        #expect(info.metadata.entries["jpeg.exif"] == exifPayload)
        #expect(info.metadata.entries["jpeg.orientation"] == Data([6]))
        #expect(info.metadata.requiredKeys == ["jpeg.exif", "jpeg.orientation"])
        let data = try #require(info.metadata.entries["jpeg.discardedAncillary"])
        let summary = try JSONDecoder().decode(Summary.self, from: data)
        #expect(summary.version == 1)
        #expect(summary.items == [Summary.Item(kind: "APP3", count: 2, payloadBytes: 7),
                                 Summary.Item(kind: "COM", count: 1, payloadBytes: 5),
                                 Summary.Item(kind: "trailingData", count: 1, payloadBytes: 2)])
        // Enough for every input metadata payload, but not for the additional
        // retained summary. Its bytes and key must share the metadata ceiling.
        let limit = (try file("gray", "icc").count) + 28 + exifPayload.count + 14
        let limited = DecodeOptions(resourceLimits: try ResourceLimits(maximumMetadataBytes: limit), metadataPolicy: .discardAncillary)
        do { _ = try decoder.inspectJPEG(input, interpretingAs: interpretation, options: limited); Issue.record("Discard report escaped metadata bound") }
        catch let error as CodecError { #expect(error.category == .resourceLimitExceeded) }
        let unchanged = try decoder.inspectJPEG(iccSource, interpretingAs: interpretation, options: options)
        #expect(unchanged.metadata.entries["jpeg.discardedAncillary"] == nil)
    }

}

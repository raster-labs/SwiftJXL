// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
@testable import SwiftJXLCore

struct JBRDTests {
    private struct Expected: Decodable {
        struct Scan: Decodable { let count: Int; let ss: UInt32; let se: UInt32; let ah: UInt32; let al: UInt32 }
        struct Quant: Decodable { let precision: UInt32; let index: UInt32 }
        struct Huffman: Decodable { let slot: Int; let counts: [UInt32]; let values: [UInt32] }
        let markers: [UInt8]
        let appLengths: [Int]
        let comLengths: [Int]
        let interLengths: [Int]
        let tailLength: Int
        let scans: [Scan]
        let quantisation: [Quant]
        let huffman: [Huffman]
        let brotliOffset: Int
        let hasZeroPadding: Bool
    }
    private func fixture(_ name: String, _ ext: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "JBRD"))
        return try Data(contentsOf: url)
    }

    @Test(arguments: ["gray", "444", "422", "420", "440", "progressive", "restart", "metadata-tail", "fill-marker",
                      "progressive-edge", "progressive-restart", "progressive-422", "progressive-440",
                      "progressive-dc-refine", "sequential-multiscan", "zero-padding"])
    func independentBundlesMatchOriginalJPEGFields(_ name: String) throws {
        let data = try fixture(name, "jbrd")
        let expected = try JSONDecoder().decode(Expected.self, from: fixture(name, "json"))
        let parsed = try JBRDBoxReader.read(data, policy: JBRDPolicy())
        let box = parsed.box
        let reencoded = try JBRDBoxWriter.write(box, policy: JBRDPolicy())
        #expect(reencoded == data.prefix(expected.brotliOffset))
        #expect(box.markerOrder.filter { $0 != 0xff } == expected.markers)
        #expect(box.appData.map(\.count) == expected.appLengths)
        #expect(box.comData.map(\.count) == expected.comLengths)
        #expect(box.interMarkerData.map(\.count) == expected.interLengths)
        #expect(box.tailData.count == expected.tailLength)
        #expect(box.quant.map(\.index) == expected.quantisation.map(\.index))
        #expect(box.quant.map(\.precision) == expected.quantisation.map(\.precision))
        #expect(box.scanInfo.count == expected.scans.count)
        for (scan, reference) in zip(box.scanInfo, expected.scans) {
            #expect(scan.numComponents == reference.count)
            #expect(scan.ss == reference.ss && scan.se == reference.se && scan.ah == reference.ah && scan.al == reference.al)
        }
        #expect(box.huffmanCode.count == expected.huffman.count)
        for (table, reference) in zip(box.huffmanCode, expected.huffman) {
            #expect(table.slotId == reference.slot)
            #expect(Array(table.values.dropLast()) == reference.values)
            var counts = Array(table.counts.dropFirst())
            let last = try #require(counts.lastIndex(where: { $0 > 0 })); counts[last] -= 1
            #expect(counts == reference.counts)
        }
        #expect(box.hasZeroPaddingBit == expected.hasZeroPadding)
        if expected.hasZeroPadding { #expect(box.paddingBits.contains(0)) }
        #expect(parsed.brotliRange == expected.brotliOffset..<data.count)
        let raw = try fixture(name, "raw")
        #expect(parsed.expectedBrotliBytes == raw.count)
        let resolved = try parsed.resolvingPayload(raw, policy: JBRDPolicy())
        let parts = resolved.appData + resolved.comData + resolved.interMarkerData + [resolved.tailData]
        #expect(parts.reduce(into: Data()) { $0.append($1) } == raw)
    }

    @Test func headerTruncationsAndMutationsDoNotTrap() throws {
        let data = try fixture("progressive", "jbrd")
        let parsed = try JBRDBoxReader.read(data, policy: JBRDPolicy())
        for n in 0...parsed.brotliRange.lowerBound {
            #expect(throws: (any Error).self) { try JBRDBoxReader.read(Data(data.prefix(n)), policy: JBRDPolicy()) }
        }
        for index in 0..<parsed.brotliRange.lowerBound {
            var changed = data; changed[index] ^= 0x80
            do { _ = try JBRDBoxReader.read(changed, policy: JBRDPolicy(maximumMemoryBytes: 8 * 1024 * 1024)) }
            catch { /* Mutations may be valid or throw; none may trap. */ }
        }
    }

    @Test func limitsAndCancellationBeforePublication() throws {
        let data = try fixture("progressive", "jbrd")
        let policies = try [JBRDPolicy(maximumInputBytes: 1), JBRDPolicy(maximumPayloadBytes: 1),
                            JBRDPolicy(maximumMemoryBytes: 1), JBRDPolicy(maximumMarkers: 1),
                            JBRDPolicy(deadline: .now.advanced(by: .seconds(-1)))]
        for policy in policies {
            #expect(throws: JBRDError.self) { try JBRDBoxReader.read(data, policy: policy) }
        }
        let calls = Mutex(0)
        let policy = try JBRDPolicy(checkpoint: {
            let n = calls.withLock { $0 += 1; return $0 }
            if n == 10 { throw CancellationError() }
        })
        #expect(throws: CancellationError.self) { try JBRDBoxReader.read(data, policy: policy) }
        let zero = try fixture("zero-padding", "jbrd")
        #expect(throws: JBRDError.self) { try JBRDBoxReader.read(zero, policy: JBRDPolicy(maximumPaddingBits: 1)) }
    }

    @Test func metadataIdentityLengthAndSurplusAreRejected() throws {
        let parsed = try JBRDBoxReader.read(fixture("metadata-tail", "jbrd"), policy: JBRDPolicy())
        let raw = try fixture("metadata-tail", "raw")
        var variants = [Data(raw.dropLast()), raw + Data([0])]
        var wrongMarker = raw; wrongMarker[0] = 0xe1; variants.append(wrongMarker)
        var wrongSize = raw; wrongSize[1] ^= 1; variants.append(wrongSize)
        for value in variants {
            #expect(throws: JBRDError.self) { try parsed.resolvingPayload(value, policy: JBRDPolicy()) }
        }
    }

    @Test func externalMetadataMustFitExactly() throws {
        let exif = Data([0x49, 0x49, 42, 0, 8, 0, 0, 0]), xmp = Data("<x/>".utf8), icc = Data([1, 2, 3, 4, 5])
        let box = JBRDBox(appData: [Data(count: 17), Data(count: 36), Data(count: 19), Data(count: 20)],
            appMarkerType: [.exif, .xmp, .icc, .icc], markerOrder: [0xe1, 0xe1, 0xe2, 0xe2, 0xd9])
        let bundle = JBRDParsedBundle(box: box, brotliRange: 0..<1, expectedBrotliBytes: 0, reservedBytes: 4096)
        let external = JBRDExternalMetadata(exifTIFF: exif, xmp: xmp, iccProfile: icc)
        let result = try bundle.resolvingPayload(Data(), external: external, policy: JBRDPolicy())
        #expect(result.appData[0].suffix(8) == exif)
        #expect(result.appData[1].suffix(4) == xmp)
        #expect(result.appData[2][15] == 1 && result.appData[3][15] == 2)
        #expect(result.appData[2][16] == 2 && result.appData[3][16] == 2)
        #expect(Data(result.appData[2].suffix(2)) + result.appData[3].suffix(3) == icc)
        for missing in [JBRDExternalMetadata(), .init(exifTIFF: exif, xmp: xmp, iccProfile: icc.dropLast()),
                        .init(exifTIFF: exif, xmp: xmp, iccProfile: icc + Data([6])),
                        .init(exifTIFF: exif.dropLast(), xmp: xmp, iccProfile: icc)] {
            #expect(throws: JBRDError.self) { try bundle.resolvingPayload(Data(), external: missing, policy: JBRDPolicy()) }
        }
    }

    @Test func invalidWriterShapesAndEventLimitsThrow() throws {
        let parsed = try JBRDBoxReader.read(fixture("progressive", "jbrd"), policy: JBRDPolicy())
        let mutations: [(inout JBRDBox) -> Void] = [
            { $0.appData[0] = Data() }, { $0.appMarkerType.removeLast() },
            { $0.huffmanCode[0].counts = [] }, { $0.scanInfo[0].components = [] },
            { $0.components[0].id = UInt32.max }, { $0.components[1].id = $0.components[0].id },
            { $0.scanInfo[0].resetPoints = [5, 4] }, { $0.markerOrder[0] = 0x10 },
            { $0.scanInfo[0].components[0].compIdx = 3 },
            { $0.scanInfo[1].ss = 63; $0.scanInfo[1].se = 0 },
            { $0.paddingBits = [1]; $0.hasZeroPaddingBit = false },
            { $0.paddingBits = [2]; $0.hasZeroPaddingBit = true },
            { $0.scanInfo[0].extraZeroRuns = [.init(blockIdx: 0, numExtraZeroRuns: 5)] }
        ]
        for mutation in mutations {
            var box = parsed.box; mutation(&box)
            #expect(throws: (any Error).self) { try JBRDBoxWriter.write(box, policy: JBRDPolicy()) }
        }
        var withEvents = parsed.box
        withEvents.scanInfo[0].resetPoints = [0, 1]
        let encoded = try JBRDBoxWriter.write(withEvents, policy: JBRDPolicy()) + Data([6])
        #expect(throws: JBRDError.self) { try JBRDBoxReader.read(encoded, policy: JBRDPolicy(maximumEvents: 1)) }
        #expect(throws: JBRDError.self) { try JBRDBoxWriter.write(withEvents, policy: JBRDPolicy(maximumEvents: 1)) }
    }

    @Test func slicedInputAndConcurrentReads() async throws {
        var owner = Data([7, 7, 7]) + (try fixture("progressive", "jbrd"))
        let data = owner.dropFirst(3); owner.removeAll()
        let expected = try JBRDBoxReader.read(data, policy: JBRDPolicy()).box
        try await withThrowingTaskGroup(of: JBRDBox.self) { group in
            for _ in 0..<4 { group.addTask { try JBRDBoxReader.read(data, policy: JBRDPolicy()).box } }
            for try await box in group { #expect(box == expected) }
        }
    }
}

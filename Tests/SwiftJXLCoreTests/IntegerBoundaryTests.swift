// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

/// Wire-level regressions also run on 64-bit hosts; the same guards must precede
/// every narrowing conversion when this source is built for Watch arm64_32.
struct IntegerBoundaryTests {
    private let highValues: [UInt32] = [0x7fff_ffff, 0x8000_0000, .max]

    private func writeSection(_ value: UInt32, contexts: Int, to writer: inout BitWriter) throws {
        let header = EntropySectionHeader(lz77: .disabled, contextMap: .trivial(numContexts: contexts),
            usePrefixCode: true, logAlphaSize: 15, uintConfigs: [HybridUintConfig(splitExponent: 0)])
        let book = MultiClusterCodebook(huffmanTables: [try PrefixCodeTable(lengths: [UInt8](repeating: 6, count: 64))],
            ansCounts: [], alphabetSizes: [64])
        try header.write(to: &writer, numContexts: contexts)
        try book.write(to: &writer, header: header)
        try TokenStreamWriter(header: header, codebook: book).writeToken(context: 0, value: value, to: &writer)
    }

    @Test func oversizedOrderEndsRejectBeforeNarrowingOrAddition() throws {
        for value in highValues {
            var toc = BitWriter()
            try writeSection(value, contexts: 8, to: &toc)
            var tocReader = BitReader(toc.finishToData())
            #expect(throws: TOCPermutationError.invalidEnd(end: UInt64(value) + 1, size: 64)) {
                _ = try decodeTOCPermutation(from: &tocReader, size: 64, skip: 1)
            }
            var order = BitWriter()
            try order.writeU32(1, distributions: (.literal(0x5f), .literal(0x13), .literal(0), .bits(13)))
            try writeSection(value, contexts: 8, to: &order)
            var orderReader = BitReader(order.finishToData())
            let budget = try ScalarOperationBudget(retainedBytes: 0, maximumWorkspaceBytes: 1024 * 1024,
                maximumMemoryBytes: 1024 * 1024, maximumDecodedBytes: 1024 * 1024,
                maximumCompressedBytes: 1024 * 1024, deadline: .now.advanced(by: .seconds(10)))
            #expect(throws: VarDCTError.invalidTransform) {
                _ = try VarDCTOrders.read(from: &orderReader, usedBuckets: [0], budget: budget)
            }
        }
    }

    @Test func oversizedContextMapTokenPreservesErrorValue() throws {
        for value in highValues {
            var writer = BitWriter()
            writer.writeBit(false) // Full context map.
            writer.writeBit(false) // No move-to-front transform.
            try writeSection(value, contexts: 1, to: &writer)
            var reader = BitReader(writer.finishToData())
            #expect(throws: ContextMapError.clusterIndexOutOfRange(index: Int64(value), max: 255)) {
                _ = try ContextMap.read(numContexts: 3, from: &reader)
            }
        }
    }

    private func lz77Stream(distance: UInt32, baseLength: UInt32 = 0) throws -> Data {
        let config = HybridUintConfig(splitExponent: 0)
        let header = EntropySectionHeader(lz77: LZ77Config(enabled: true, lengthUintConfig: config),
            contextMap: .trivial(numContexts: 2), usePrefixCode: true, logAlphaSize: 15, uintConfigs: [config])
        let table = try PrefixCodeTable(lengths: [UInt8](repeating: 9, count: 512))
        let book = MultiClusterCodebook(huffmanTables: [table], ansCounts: [], alphabetSizes: [512])
        var writer = BitWriter()
        try header.write(to: &writer, numContexts: 1)
        try book.write(to: &writer, header: header)
        try table.encode(1, to: &writer) // Seed history with one literal.
        let length = config.encode(baseLength), dist = config.encode(distance)
        try table.encode(Int(length.token + 224), to: &writer)
        writer.write(bits: length.extraNBits, value: length.extraBits)
        try table.encode(Int(dist.token), to: &writer)
        writer.write(bits: dist.extraNBits, value: dist.extraBits)
        return writer.finishToData()
    }

    @Test func lz77RejectsUnrepresentableAndWrappedZeroDistances() throws {
        for raw in highValues {
            var reader = BitReader(try lz77Stream(distance: raw))
            let header = try EntropySectionHeader.read(from: &reader, numContexts: 1)
            let book = try MultiClusterCodebook.read(from: &reader, header: header)
            var tokens = TokenStreamReader(header: header, codebook: book)
            #expect(try tokens.readToken(context: 0, from: &reader) == 1)
            do {
                _ = try tokens.readToken(context: 0, from: &reader)
                Issue.record("Invalid LZ77 distance was accepted")
            } catch TokenStreamReaderError.lz77InvalidDistance(let distance, let size) {
                #expect(distance == raw &+ 1)
                #expect(size == 1)
            }
        }
    }

    @Test func lz77RejectsOverflowingLength() throws {
        var reader = BitReader(try lz77Stream(distance: 0, baseLength: .max))
        let header = try EntropySectionHeader.read(from: &reader, numContexts: 1)
        let book = try MultiClusterCodebook.read(from: &reader, header: header)
        var tokens = TokenStreamReader(header: header, codebook: book)
        #expect(try tokens.readToken(context: 0, from: &reader) == 1)
        do {
            _ = try tokens.readToken(context: 0, from: &reader)
            Issue.record("Overflowing LZ77 length was accepted")
        } catch TokenStreamReaderError.lz77InvalidLength { }
    }

    private func variable(_ input: UInt32) -> [UInt8] {
        var value = input, bytes: [UInt8] = []
        repeat {
            let byte = UInt8(value & 127); value >>= 7
            bytes.append(byte | (value == 0 ? 0 : 128))
        } while value != 0
        return bytes
    }

    private func profileStream(outputSize: UInt32, commands: [UInt8], payload: [UInt8]) -> [UInt8] {
        var encoded = variable(outputSize)
        encoded.append(contentsOf: variable(UInt32(commands.count)))
        encoded.append(contentsOf: commands)
        encoded.append(contentsOf: [UInt8](repeating: 0, count: 128))
        encoded.append(contentsOf: payload)
        return encoded
    }

    @Test func iccRejectsOversizedOutputBeforeAdmission() throws {
        for value in highValues {
            #expect(throws: JPEGEntropyError.resourceLimit) {
                _ = try ICCStream.unpredict(variable(value) + [0], maximumBytes: 512,
                    admit: { _ in Issue.record("Oversized output reached allocation admission") }, checkpoint: {})
            }
        }
    }

    @Test func iccPredictionRetainsUnsigned32BitProfileWords() throws {
        let seed: [UInt8] = [0,0,0,0, 0x80,0,0,0, 0xff,0xff,0xff,0xff, 0xff,0xff,0xff,0xfe]
        let expected: [[UInt8]] = [[0xff,0xff,0xff,0xfe], [0xff,0xff,0xff,0xfd], [0x7f,0xff,0xff,0xfd]]
        for order in 0..<3 {
            let commands: [UInt8] = [0,1,16,4,UInt8(3 + order * 4),4]
            let encoded = profileStream(outputSize: 148, commands: commands, payload: seed + [0,0,0,0])
            let profile = try ICCStream.unpredict(encoded, maximumBytes: 512, checkpoint: {})
            #expect(profile.suffix(4) == Data(expected[order]))
        }
    }

    @Test func iccTagWordsRetainHighBitsAndRejectDerivedOverflow() throws {
        let commands: [UInt8] = [2,0xc1] + variable(0x8000_0000) + variable(0x8000_0000) + [0]
        let encoded = profileStream(outputSize: 144, commands: commands, payload: Array("test".utf8))
        #expect(try ICCStream.unpredict(encoded, maximumBytes: 512, checkpoint: {}).suffix(8)
            == Data([0x80,0,0,0,0x80,0,0,0]))
        // A second implicit tag starts at 2^32, which cannot be written as a tag word.
        let overflowCommands = Array(commands.dropLast()) + [1,0]
        let overflow = profileStream(outputSize: 156, commands: overflowCommands, payload: Array("testtest".utf8))
        #expect(throws: ICCStreamError.malformed) {
            _ = try ICCStream.unpredict(overflow, maximumBytes: 512, checkpoint: {})
        }
    }
}

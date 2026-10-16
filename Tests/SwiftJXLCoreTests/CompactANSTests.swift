// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

struct CompactANSTests {
    @Test func reciprocalDivisionMatchesHardwareForEveryANSFrequency() {
        var seed: UInt32 = 0x9e3779b9
        var corrections = 0
        for rawFrequency in 1...4096 {
            let frequency = UInt32(rawFrequency)
            let reciprocal = ANSReciprocalDivision.reciprocal(frequency)
            var values: [UInt32] = [0, 1, .max, .max - 1, 65535, 65536]
            let quotients: [UInt32] = [0, 1, 2, 65535, 65536, UInt32.max / frequency]
            for quotient in quotients {
                let boundary = UInt64(quotient) * UInt64(frequency)
                for delta in [-1, 0, 1] {
                    let value = Int64(boundary) + Int64(delta)
                    if value >= 0 && value <= Int64(UInt32.max) { values.append(UInt32(value)) }
                }
            }
            for _ in 0..<32 {
                seed = seed &* 1664525 &+ 1013904223
                values.append(seed)
            }
            for value in values {
                let estimate = (UInt64(value) * reciprocal) >> 32
                if estimate * UInt64(frequency) > UInt64(value) { corrections += 1 }
                let result = ANSReciprocalDivision.divide(value, frequency: frequency, reciprocal: reciprocal)
                #expect(result.quotient == value / frequency)
                #expect(result.remainder == value % frequency)
            }
        }
        #expect(corrections > 0)
    }

    private func code() throws -> (EntropySectionHeader, MultiClusterCodebook) {
        let distribution = try ANSDistribution(rawFrequencies:
            [UInt32](repeating: 1, count: HybridUintConfig.raw4.maxToken + 1))
        var bits = BitWriter()
        let wire = try SpecANSDistribution.writeHistogram(
            distribution.frequencies.map(Int32.init), to: &bits)
        let header = EntropySectionHeader(lz77: .disabled,
            contextMap: .trivial(numContexts: 1), usePrefixCode: false,
            logAlphaSize: max(5, Int(ceilLog2(UInt32(wire.count)))), uintConfigs: [.raw4])
        return (header, MultiClusterCodebook(huffmanTables: [], ansCounts: [wire], alphabetSizes: [wire.count]))
    }

    @Test(arguments: [0, 1, 255, 256, 257, 4097, 196608])
    func compactOutputMatchesBufferedWriterAndDecoder(_ count: Int) throws {
        let (header, codebook) = try code()
        var seed: UInt32 = 20261013
        let values = (0..<count).map { index -> UInt32 in
            seed = seed &* 1664525 &+ 1013904223
            return index < 32 ? (UInt32(1) << index) - 1 : seed
        }
        var buffered = try ANSTokenStreamWriter(header: header, codebook: codebook)
        for value in values { try buffered.writeToken(context: 0, value: value) }
        var expected = BitWriter(), actual = BitWriter()
        // Exercise a non-byte-aligned section start as well as token boundaries.
        expected.write(bits: 3, value: 5); actual.write(bits: 3, value: 5)
        try buffered.finish(to: &expected)
        let compact = try ANSTokenStreamWriter(header: header, codebook: codebook)
        var symbols = values.map { UInt16(HybridUintConfig.raw4.tokenOnly($0)) }
        try compact.finishSingleCluster(symbols: &symbols, replay: { emit in
            for value in values { try emit(value) }
        }, to: &actual)
        #expect(actual.bitCount == expected.bitCount)
        let bytes = actual.finishToData()
        #expect(bytes == expected.finishToData())
        var reader = BitReader(bytes)
        #expect(try reader.read(bits: 3) == 5)
        var stream = TokenStreamReader(header: header, codebook: codebook)
        for value in values { #expect(try stream.readToken(context: 0, from: &reader) == value) }
        // Empty streams have not initialised the reader's state.
        if !values.isEmpty { try stream.finish() }
    }

    @Test(arguments: [0, 1, 255, 256, 4097])
    func chunkedCostMatchesEmittedRefillBits(_ count: Int) throws {
        let (header, codebook) = try code()
        let values = (0..<count).map { UInt32($0) &* 2654435761 }
        let symbols = values.map { UInt16(HybridUintConfig.raw4.tokenOnly($0)) }
        let middle = count / 2
        let chunks = [Array(symbols[..<middle]), [], Array(symbols[middle...])]
        var stream = try ANSTokenStreamWriter(header: header, codebook: codebook)
        for value in values { try stream.writeToken(context: 0, value: value) }
        var bits = BitWriter()
        try stream.finish(to: &bits)
        let extra = values.reduce(0) { $0 + HybridUintConfig.raw4.encode($1).extraNBits }
        let refills = try stream.refillWordCount(singleClusterChunks: chunks)
        #expect(bits.bitCount == 32 + 16 * refills + extra)
        #expect(try stream.refillWordCount(symbols: symbols) == refills)
        #expect(throws: ANSTokenStreamWriterError.self) {
            _ = try stream.refillWordCount(symbols: [0], clusters: [])
        }
        #expect(throws: ANSTokenStreamWriterError.self) {
            _ = try stream.refillWordCount(symbols: [0], clusters: [1])
        }
    }

    @Test func compactWriterRejectsMismatchedReplayCount() throws {
        let (header, codebook) = try code()
        let stream = try ANSTokenStreamWriter(header: header, codebook: codebook)
        for count in [0, 2] {
            var symbols: [UInt16] = [0], bits = BitWriter()
            #expect(throws: ANSTokenStreamWriterError.self) {
                try stream.finishSingleCluster(symbols: &symbols,
                    replay: { emit in for _ in 0..<count { try emit(0) } }, to: &bits)
            }
        }
    }

    @Test func compactWriterEnforcesCancelledAndLatchedOutputLimits() throws {
        let (header, codebook) = try code()
        let stream = try ANSTokenStreamWriter(header: header, codebook: codebook)
        let cancellation = ScalarOperationCancellation()
        let budget = try ScalarOperationBudget(retainedBytes: 0, maximumWorkspaceBytes: 1 << 20,
            maximumMemoryBytes: 1 << 20, maximumDecodedBytes: 1, maximumCompressedBytes: 1,
            deadline: .now.advanced(by: .seconds(30)), cancellation: cancellation)
        let work = ScalarEncodingWork(budget: budget, writerByteLimit: 1)
        ScalarEncodingWork.$current.withValue(work) {
            var bits = BitWriter()
            #expect(throws: ScalarModularError.self) {
                var symbols = [UInt16](repeating: UInt16(HybridUintConfig.raw4.tokenOnly(.max)), count: 513)
                try stream.finishSingleCluster(symbols: &symbols,
                    replay: { emit in for _ in 0..<513 { try emit(.max) } }, to: &bits)
            }
        }
        cancellation.cancel()
        ScalarEncodingWork.$current.withValue(ScalarEncodingWork(budget: budget, writerByteLimit: 1)) {
            var bits = BitWriter()
            #expect(throws: CancellationError.self) {
                var symbols: [UInt16] = []
                try stream.finishSingleCluster(symbols: &symbols, replay: { _ in }, to: &bits)
            }
        }
    }
}

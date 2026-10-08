// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

struct ScalarLimitTests {
    private func fixture() throws -> Data {
        try SpecModularEncoder.encodeGrayscale16(width: 7, height: 5,
            bitsPerSample: 12, pixelsInt32: (0..<35).map { Int32($0 * 113) }, effort: 3)
    }

    @Test func admissionLimitsRespectExactBoundaries() throws {
        let data = try fixture()
        let exact = try ScalarDecodePolicy(maximumCompressedBytes: data.count,
            maximumPixels: 35, maximumDimension: 7)
        #expect(try ScalarModularDecoder.decode(data, policy: exact).pixels.count == 35)
        let policies = try [
            ScalarDecodePolicy(maximumCompressedBytes: data.count - 1),
            ScalarDecodePolicy(maximumPixels: 34),
            ScalarDecodePolicy(maximumDimension: 6)
        ]
        for policy in policies {
            #expect(throws: ScalarModularError.self) {
                try ScalarModularDecoder.prepare(data, policy: policy)
            }
        }
    }

    @Test func expiredDeadlineRejectsBeforeParsing() throws {
        let policy = try ScalarDecodePolicy(deadline: ContinuousClock.now.advanced(by: .seconds(-1)))
        #expect(throws: ScalarModularError.self) {
            try ScalarModularDecoder.prepare(Data(), policy: policy)
        }
        var reader = BitReader(Data([0]), deadline: policy.deadline)
        #expect(throws: ScalarModularError.self) { try reader.readBit() }
    }

    @Test func preparedFrameRetainsOperationDeadline() async throws {
        let data = try fixture()
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        let frame = try ScalarModularDecoder.prepare(data, policy: ScalarDecodePolicy(deadline: deadline))
        try await ContinuousClock().sleep(until: deadline)
        var destination = [UInt8](repeating: 0xa5, count: 70)
        let layout = try ScalarPlaneLayout(width: 7, height: 5, rowBytes: 14)
        _ = destination.withUnsafeMutableBytes { raw in
            #expect(throws: ScalarModularError.self) { try frame.decode(into: raw, layout: layout) }
        }
        #expect(destination == [UInt8](repeating: 0xa5, count: 70))
    }

    @Test func nestingCeilingRejectsBeforeEnteringExtraLevel() throws {
        var reader = BitReader(Data(), maximumNestingDepth: 1)
        try reader.enterNesting()
        #expect(throws: ScalarModularError.self) { try reader.enterNesting() }
        reader.leaveNesting()
        try reader.enterNesting()
    }

    @Test func invalidLimitsRejectAndLargeLimitsCannotExpandProfile() throws {
        #expect(throws: ScalarModularError.self) { try ScalarDecodePolicy(maximumPixels: 0) }
        #expect(throws: ScalarModularError.self) { try ScalarDecodePolicy(maximumNestingDepth: -1) }
        let policy = try ScalarDecodePolicy(maximumCompressedBytes: Int.max,
            maximumPixels: Int.max, maximumDimension: Int.max, maximumNestingDepth: Int.max)
        #expect(policy.maximumCompressedBytes == 4 * 1024 * 1024)
        #expect(policy.maximumPixels == 1024 * 1024)
        #expect(policy.maximumDimension == 1024)
        #expect(policy.maximumNestingDepth == 32)
    }
    @Test func largeAlphabetIsRejectedBeforeItsTableIsParsed() throws {
        var writer = BitWriter()
        try writer.writeVarLenUint16(65535)
        let data = writer.finishToData()
        var reader = BitReader(data, maximumEntropyTableBytes: 1024 * 1024)
        let header = EntropySectionHeader(lz77: .disabled,
            contextMap: .trivial(numContexts: 1), usePrefixCode: true,
            logAlphaSize: 15, uintConfigs: [.raw4])
        // No table body exists. Resource rejection must precede its parsing
        // and allocation, rather than falling through to an EOF failure.
        #expect(throws: ScalarModularError.self) {
            try MultiClusterCodebook.read(from: &reader, header: header)
        }
    }

    @Test func tableReservationsAccumulateAndCheckOverflow() throws {
        var reader = BitReader(Data(), maximumEntropyTableBytes: 12)
        try reader.reserveEntropyTableBytes(8)
        try reader.reserveEntropyTableBytes(4)
        #expect(throws: ScalarModularError.self) { try reader.reserveEntropyTableBytes(1) }
        #expect(throws: ScalarModularError.self) { try reader.reserveEntropyTableBytes(Int.max) }
        #expect(throws: ScalarModularError.self) { try reader.reserveEntropyTableBytes(-1) }
    }

}

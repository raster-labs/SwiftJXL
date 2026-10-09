// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
@testable import SwiftJXLCore

struct JPEGCoefficientTests {
    private struct Oracle: Decodable {
        struct Component: Decodable {
            let id: UInt8
            let width: Int
            let height: Int
            let quantisation: [UInt16]
            let coefficients: [Int32]
        }
        let width: Int
        let height: Int
        let components: [Component]
    }

    private func fixture(_ name: String, extension ext: String = "jpg") throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "JPEG"))
        return try Data(contentsOf: url)
    }

    @Test(arguments: ["gray", "444", "422", "420", "440", "progressive", "restart", "metadata-tail", "fill-marker",
                      "progressive-edge", "progressive-restart", "progressive-422", "progressive-440",
                      "progressive-dc-refine", "sequential-multiscan"])
    func allVisibleCoefficientsMatchIndependentLibjpeg(_ name: String) throws {
        let data = try fixture(name)
        let result = try JPEGCoefficientDecoder.decode(data, policy: JPEGCoefficientPolicy())
        let oracle = try JSONDecoder().decode(Oracle.self, from: fixture(name, extension: "json"))
        #expect(result.source == data)
        #expect(result.frame.width == oracle.width && result.frame.height == oracle.height)
        #expect(result.coefficients.count == oracle.components.count)
        for ci in oracle.components.indices {
            let expected = oracle.components[ci], geometry = result.frame.components[ci]
            #expect(geometry.id == expected.id)
            #expect(geometry.visibleBlocksWide == expected.width && geometry.visibleBlocksHigh == expected.height)
            #expect(result.quantisation[ci] == expected.quantisation)
            var visible: [Int32] = []
            for n in 0..<geometry.singleComponentBlockCount {
                let base = try geometry.storageIndex(forSingleComponentBlock: n) * 64
                visible.append(contentsOf: result.coefficients[ci][base..<(base + 64)])
            }
            #expect(visible == expected.coefficients)
        }
    }

    @Test func everyProgressivePrefixFailsWithoutPublishingCoefficients() throws {
        let data = try fixture("progressive")
        for n in 0..<data.count {
            #expect(throws: (any Error).self) {
                try JPEGCoefficientDecoder.decode(Data(data.prefix(n)), policy: JPEGCoefficientPolicy())
            }
        }
    }

    @Test func resourceAdmissionAndPaddingLimits() throws {
        let data = try fixture("progressive")
        let policies = try [JPEGCoefficientPolicy(maximumInputBytes: 10),
                            JPEGCoefficientPolicy(maximumCoefficientBytes: 100),
                            JPEGCoefficientPolicy(maximumMemoryBytes: 100),
                            JPEGCoefficientPolicy(maximumPaddingRecords: 1),
                            JPEGCoefficientPolicy(deadline: .now.advanced(by: .seconds(-1)))]
        for policy in policies {
            #expect(throws: (any Error).self) { try JPEGCoefficientDecoder.decode(data, policy: policy) }
        }
    }

    @Test func mutatedInputRemainsBoundedAndCannotTrap() throws {
        let data = try fixture("progressive")
        for index in stride(from: 0, to: data.count, by: 13) {
            for bit in 0..<8 {
                var changed = data; changed[index] ^= 1 << bit
                do {
                    let result = try JPEGCoefficientDecoder.decode(changed,
                        policy: JPEGCoefficientPolicy(maximumCoefficientBytes: 1024 * 1024,
                                                      maximumMemoryBytes: 16 * 1024 * 1024))
                    #expect(result.coefficients.reduce(0) { $0 + $1.count } == result.frame.coefficientCount)
                    #expect(result.source == changed)
                } catch {
                    // Mutations may remain valid, or throw. None may trap or publish a partial result.
                }
            }
        }
    }

    @Test func cancellationDuringCoefficientWorkThrowsBeforePublication() throws {
        let calls = Mutex(0)
        let policy = try JPEGCoefficientPolicy(checkpoint: {
            let n = calls.withLock { $0 += 1; return $0 }
            if n == 50 { throw CancellationError() }
        })
        let data = try fixture("progressive")
        #expect(throws: CancellationError.self) { try JPEGCoefficientDecoder.decode(data, policy: policy) }
        #expect(calls.withLock { $0 } == 50)
    }

    @Test func wrongRestartSequenceRejects() throws {
        var data = try fixture("restart")
        let marker = try #require(data.range(of: Data([0xff, 0xd0])))
        data[marker.lowerBound + 1] = 0xd3
        #expect(throws: JPEGEntropyError.malformed) {
            try JPEGCoefficientDecoder.decode(data, policy: JPEGCoefficientPolicy())
        }
    }

    @Test func nonCanonicalPaddingIsRetained() throws {
        var found = false
        for name in ["gray", "444", "422", "420", "440"] {
            var data = try fixture(name)
            let reference = try JPEGCoefficientDecoder.decode(data, policy: JPEGCoefficientPolicy())
            let padding = try #require(reference.padding.last)
            if padding.bitCount == 0 || data[padding.offset - 1] == 0 { continue }
            data[padding.offset - 1] &= 0xfe
            let result = try JPEGCoefficientDecoder.decode(data, policy: JPEGCoefficientPolicy())
            #expect(result.coefficients == reference.coefficients)
            #expect(result.padding.last?.bits == padding.bits & 0xfe)
            #expect(result.padding.last != reference.padding.last)
            found = true
            break
        }
        #expect(found)
    }

    @Test func invalidHuffmanTreesAndBitRequestsThrow() throws {
        for first in [0, 2, 255] {
            let counts = [first] + Array(repeating: 0, count: 15)
            #expect(throws: JPEGEntropyError.malformed) {
                try JPEGHuffmanTable(counts: counts, symbols: Array(repeating: 0, count: first))
            }
        }
        var reader = try JPEGEntropyReader(data: Data([0]), range: 0..<1, checkpoint: {})
        for n in [-1, 17, Int.max] {
            #expect(throws: JPEGEntropyError.malformed) { try reader.bits(n) }
        }
        #expect(throws: JPEGEntropyError.malformed) {
            try JPEGEntropyReader(data: Data([0]), range: -1..<1, checkpoint: {})
        }
    }

    @Test func slicedLifetimeAndConcurrentOperations() async throws {
        var owner = Data([7, 7, 7]) + (try fixture("progressive"))
        let slice = owner.dropFirst(3)
        owner.removeAll()
        let expected = try JPEGCoefficientDecoder.decode(slice, policy: JPEGCoefficientPolicy()).coefficients
        try await withThrowingTaskGroup(of: [[Int32]].self) { group in
            for _ in 0..<4 {
                group.addTask { try JPEGCoefficientDecoder.decode(slice, policy: JPEGCoefficientPolicy()).coefficients }
            }
            for try await actual in group { #expect(actual == expected) }
        }
    }

    @Test func stuffedEntropyReaderChecksWorkAtOddOffsets() throws {
        let calls = Mutex(0)
        let data = Data([7]) + Data((0..<12000).flatMap { _ in [UInt8(0xff), 0] })
        var reader = try JPEGEntropyReader(data: data, range: 1..<data.count, checkpoint: {
            let n = calls.withLock { $0 += 1; return $0 }
            if n == 2 { throw CancellationError() }
        })
        #expect(throws: CancellationError.self) {
            for _ in 0..<12000 { _ = try reader.bits(8) }
        }
    }

    @Test func cancelledOperationHasNoResult() async throws {
        let data = try fixture("progressive")
        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: CancellationError.self) {
                try JPEGCoefficientDecoder.decode(data, policy: JPEGCoefficientPolicy())
            }
        }.value
    }
}

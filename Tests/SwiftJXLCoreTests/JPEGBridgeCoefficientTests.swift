// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
@testable import SwiftJXLCore

private let bridgeFixtures = ["gray", "444", "422", "420", "440", "progressive", "restart",
    "metadata-tail", "fill-marker", "progressive-edge", "progressive-restart", "progressive-422",
    "progressive-440", "progressive-dc-refine", "sequential-multiscan"]

struct JPEGBridgeCoefficientTests {
    private struct Oracle: Decodable {
        struct Component: Decodable {
            let width: Int, height: Int
            let quantisation: [UInt16]
            let coefficients: [Int32]
        }
        let components: [Component]
    }
    private func fixture(_ name: String, extension ext: String = "jpg") throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "JPEG"))
        return try Data(contentsOf: url)
    }
    private func decoded(_ name: String = "gray") throws -> JPEGDecodedCoefficients {
        try JPEGCoefficientDecoder.decode(fixture(name), policy: JPEGCoefficientPolicy())
    }
    private func bridge(_ input: JPEGDecodedCoefficients, transform: ColorTransform = .yCbCr,
                        policy: JPEGBridgePolicy? = nil) throws -> JPEGBridgeCoefficients {
        try JPEGBridgeCoefficients(frame: input.frame, coefficients: input.coefficients,
            quantisation: input.quantisation, colourTransform: transform, policy: policy ?? JPEGBridgePolicy())
    }

    @Test(arguments: bridgeFixtures)
    func visibleBridgeBlocksMatchIndependentCoefficients(_ name: String) throws {
        let input = try decoded(name), view = try bridge(input)
        let oracle = try JSONDecoder().decode(Oracle.self, from: fixture(name, extension: "json"))
        let order = oracle.components.count == 1 ? [0, 0, 0] : [1, 0, 2]
        var scratch = [Int32](repeating: 42, count: 64)
        for c in 0..<3 {
            let layout = view.channels[c], expected = oracle.components[order[c]]
            #expect(layout.visibleBlocksWide == expected.width && layout.visibleBlocksHigh == expected.height)
            for y in 0..<expected.height {
                for x in 0..<expected.width {
                    try view.readBlock(channel: c, block: y * layout.blocksWide + x, into: &scratch)
                    for j in 0..<8 {
                        for i in 0..<8 {
                            let expectedValue: Int32 = layout.jpegComponent == nil ? 0
                                : expected.coefficients[(y * expected.width + x) * 64 + i * 8 + j]
                            #expect(scratch[j * 8 + i] == expectedValue)
                        }
                    }
                }
            }
            for y in 0..<8 {
                for x in 0..<8 { #expect(view.quantisation[c * 64 + y * 8 + x] == Int32(expected.quantisation[x * 8 + y])) }
            }
            #expect(view.dcQuantisation[c] == 2040 / Float(expected.quantisation[0]))
        }
        #expect(abs(view.quantisationDenominator - Float(1.0 / 2040.0)) < 1e-9)
        let expectedModes: (UInt32, UInt32, UInt32)
        let y = input.frame.components[0]
        let mode: UInt32 = y.horizontalSampling == 2 ? (y.verticalSampling == 2 ? 1 : 2) : (y.verticalSampling == 2 ? 3 : 0)
        expectedModes = (0, mode, 0)
        #expect(view.chromaSubsampling == YCbCrChromaSubsampling(y: expectedModes.0, cb: expectedModes.1, cr: expectedModes.2))
    }

    @Test(arguments: bridgeFixtures)
    func bridgePreservesPaddingForByteExactReconstruction(_ name: String) throws {
        let input = try decoded(name), view = try bridge(input)
        var restored = input.coefficients.map { [Int32](repeating: 0, count: $0.count) }
        var scratch = [Int32](repeating: 0, count: 64)
        for c in 0..<3 {
            let channel = view.channels[c]
            guard let ci = channel.jpegComponent else { continue }
            for b in 0..<(channel.blocksWide * channel.blocksHigh) {
                try view.readBlock(channel: c, block: b, into: &scratch)
                for y in 0..<8 {
                    for x in 0..<8 { restored[ci][b * 64 + x * 8 + y] = scratch[y * 8 + x] }
                }
            }
        }
        #expect(restored == input.coefficients)
        let metadata = try JPEGReconstructionMetadata.encode(input, policy: JBRDPolicy()).box
        #expect(try JPEGReconstructionWriter.write(coefficients: restored, metadata: metadata,
            policy: JPEGReconstructionPolicy()) == input.source)
    }

    @Test(arguments: ["gray", "444"])
    func noColourTransformUsesExactDCOffsetAndZeroGreyChroma(_ name: String) throws {
        let input = try decoded(name), view = try bridge(input, transform: .none)
        var scratch = [Int32](repeating: 0, count: 64)
        for c in 0..<3 {
            let channel = view.channels[c]
            for b in 0..<(channel.blocksWide * channel.blocksHigh) {
                try view.readBlock(channel: c, block: b, into: &scratch)
                if let ci = channel.jpegComponent {
                    #expect(scratch[0] == input.coefficients[ci][b * 64] + 1024 / Int32(input.quantisation[ci][0]))
                    #expect(scratch[1] == input.coefficients[ci][b * 64 + 8])
                } else { #expect(scratch.allSatisfy { $0 == 0 }) }
            }
        }
    }

    @Test func retainedBuffersShareStorageAndSurviveSourceMutationAndRelease() throws {
        let view: JPEGBridgeCoefficients = try {
            let input = try decoded("420")
            var owners = input.coefficients
            let view = try JPEGBridgeCoefficients(frame: input.frame, coefficients: owners,
                quantisation: input.quantisation, policy: JPEGBridgePolicy())
            for ci in owners.indices {
                #expect(owners[ci].withUnsafeBufferPointer { original in
                    view.sourceCoefficients[ci].withUnsafeBufferPointer { retained in
                        original.baseAddress == retained.baseAddress
                    }
                })
            }
            let original = view.sourceCoefficients[0][0]
            owners[0][0] = original + 1
            #expect(view.sourceCoefficients[0][0] == original)
            return view
        }()
        var scratch = [Int32](repeating: 0, count: 64)
        try view.readBlock(channel: 1, block: 0, into: &scratch)
        #expect(scratch[0] == view.sourceCoefficients[0][0])
    }

    @Test func admissionMalformedOwnersAndUnsupportedTransforms() throws {
        let input = try decoded("420")
        let bytes = input.frame.coefficientCount * 4
        let view = try bridge(input, policy: JPEGBridgePolicy(maximumCoefficientBytes: bytes,
                                                             maximumMemoryBytes: 2 * bytes + 16384))
        #expect(view.admittedBytes == 2 * bytes + 16384)
        for policy in try [JPEGBridgePolicy(maximumCoefficientBytes: bytes - 1),
                           JPEGBridgePolicy(maximumMemoryBytes: view.admittedBytes - 1),
                           JPEGBridgePolicy(deadline: .now.advanced(by: .seconds(-1)))] {
            #expect(throws: JPEGEntropyError.resourceLimit) { try bridge(input, policy: policy) }
        }
        for transform in [ColorTransform.none, .xyb] {
            #expect(throws: JPEGEntropyError.unsupported) { try bridge(input, transform: transform) }
        }
        var brokenQuant = input.quantisation; brokenQuant[0][0] = 0
        for quant in [brokenQuant, [], [[UInt16](repeating: 1, count: 63)]] {
            #expect(throws: JPEGEntropyError.malformed) {
                try JPEGBridgeCoefficients(frame: input.frame, coefficients: input.coefficients,
                    quantisation: quant, policy: JPEGBridgePolicy())
            }
        }
        var brokenCoefficients = input.coefficients; brokenCoefficients[0].removeLast()
        #expect(throws: JPEGEntropyError.malformed) {
            try JPEGBridgeCoefficients(frame: input.frame, coefficients: brokenCoefficients,
                quantisation: input.quantisation, policy: JPEGBridgePolicy())
        }
    }

    @Test func invalidBlockRequestsAndDCOverflowCannotTrapOrWriteScratch() throws {
        let input = try decoded()
        var coefficients = input.coefficients; coefficients[0][0] = Int32.max
        let view = try JPEGBridgeCoefficients(frame: input.frame, coefficients: coefficients,
            quantisation: input.quantisation, colourTransform: .none, policy: JPEGBridgePolicy())
        for (channel, block, count) in [(1, 0, 64), (-1, 0, 64), (3, 0, 64),
                                      (1, -1, 64), (1, Int.max, 64), (1, 0, 63)] {
            var scratch = [Int32](repeating: 17, count: count)
            #expect(throws: JPEGEntropyError.malformed) { try view.readBlock(channel: channel, block: block, into: &scratch) }
            #expect(scratch.allSatisfy { $0 == 17 })
        }
    }

    @Test func cancellationBeforePublicationAndDuringBlockWork() throws {
        let input = try decoded()
        for threshold in [1, 2, 5] {
            let calls = Mutex(0)
            let policy = try JPEGBridgePolicy(checkpoint: {
                if calls.withLock({ $0 += 1; return $0 }) == threshold { throw CancellationError() }
            })
            #expect(throws: CancellationError.self) {
                let view = try bridge(input, policy: policy)
                var scratch = [Int32](repeating: 0, count: 64)
                for _ in 0..<5 { try view.readBlock(channel: 1, block: 0, into: &scratch) }
            }
            #expect(calls.withLock { $0 } == threshold)
        }
    }

    @Test func concurrentOwnersAndTaskCancellation() async throws {
        let view = try bridge(decoded("progressive"))
        try await withThrowingTaskGroup(of: Int32.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    var scratch = [Int32](repeating: 0, count: 64)
                    try view.readBlock(channel: 1, block: 0, into: &scratch)
                    return scratch[0]
                }
            }
            for try await dc in group { #expect(dc == view.sourceCoefficients[0][0]) }
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var scratch = [Int32](repeating: 0, count: 64)
            try view.readBlock(channel: 1, block: 0, into: &scratch)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

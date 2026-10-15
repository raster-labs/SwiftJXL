// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

struct VarDCTEncoderPreparationTests {
    private func budget(_ maximum: Int = 1024 * 1024) throws -> ScalarOperationBudget {
        try ScalarOperationBudget(retainedBytes: 0, maximumWorkspaceBytes: maximum,
            maximumMemoryBytes: maximum, maximumDecodedBytes: maximum,
            maximumCompressedBytes: maximum, deadline: .now.advanced(by: .seconds(30)))
    }
    @Test func eightBitConversionMatchesUncachedArithmeticExactly() throws {
        let operation = try budget()
        let table = try VarDCTEncoderPreparation.EightBitConversion(grayscale: true, budget: operation)
        #expect(operation.reservedWorkspaceBytes == 256 * (MemoryLayout<Double>.stride + MemoryLayout<(Float, Float, Float)>.stride))
        for sample in 0..<256 {
            let v = Double(sample) / Double(255)
            let linear = v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            #expect(table.linear[sample].bitPattern == linear.bitPattern)
            let p = try DefaultOpsin.forward((linear, linear, linear))
            #expect(table.grayscale[sample].0.bitPattern == Float(p.X).bitPattern)
            #expect(table.grayscale[sample].1.bitPattern == Float(p.Y).bitPattern)
            #expect(table.grayscale[sample].2.bitPattern == Float(p.B).bitPattern)
        }
        let rgbBudget = try budget()
        let rgb = try VarDCTEncoderPreparation.EightBitConversion(grayscale: false, budget: rgbBudget)
        #expect(rgb.grayscale.isEmpty)
        #expect(rgbBudget.reservedWorkspaceBytes == 256 * MemoryLayout<Double>.stride)
        #expect(rgb.linear.map(\.bitPattern) == table.linear.map(\.bitPattern))
        #expect(throws: ScalarModularError.self) {
            try VarDCTEncoderPreparation.EightBitConversion(grayscale: true, budget: budget(1))
        }
        let cancellation = ScalarOperationCancellation()
        let cancelled = try ScalarOperationBudget(retainedBytes: 0, maximumWorkspaceBytes: 4096,
            maximumMemoryBytes: 4096, maximumDecodedBytes: 4096, maximumCompressedBytes: 4096,
            deadline: .now.advanced(by: .seconds(30)), cancellation: cancellation)
        cancellation.cancel()
        #expect(throws: CancellationError.self) {
            try VarDCTEncoderPreparation.EightBitConversion(grayscale: true, budget: cancelled)
        }
        #expect(cancelled.reservedWorkspaceBytes == 0)
    }

    @Test func lookupStillRejectsOutOfRangePaddedSixteenBitStorage() throws {
        // Meaningful eight-bit samples may reside in padded 16-bit containers.
        // The source check must precede a lookup even on the grayscale fast path.
        for grayscale in [false, true] { for littleEndian in [false, true] {
            let channels = grayscale ? 1 : 3
            let layouts = try (0..<channels).map { try ModularChannelLayout(width: 1, height: 1,
                offset: $0 * 2, rowBytes: channels * 2 + 3, pixelStride: channels * 2,
                storageBits: 16, littleEndian: littleEndian) }
            var input = Data(repeating: 0, count: channels * 2 + 3)
            input[littleEndian ? 1 : 0] = 1 // 256, greater than the meaningful maximum.
            do {
                _ = try input.withUnsafeBytes {
                    try VarDCTPixelEncoder.encode($0, layouts: layouts, bitsPerSample: 8,
                        grayscale: grayscale, alphaAssociated: nil, distance: 1,
                        gaborish: true, budget: budget(32 * 1024 * 1024))
                }
                Issue.record("Out-of-range sample unexpectedly reached conversion lookup")
            } catch ScalarModularError.invalidInput(let message) {
                #expect(message == "Source sample exceeds meaningful precision")
            }
        } }
    }

    @Test func scopedPrefilterMatchesOriginalScalarBitsAtMirroredEdges() throws {
        func reference(_ input: [Float], _ width: Int, _ height: Int) -> [Float] {
            let g: [Float] = [-0.09495815671340026, -0.041031725066768575,
                0.013710004822696948, 0.006510206083837737, -0.0014789063378272242]
            let normalise = Float(1 / (1 + Double(4 * (g[0] + g[1] + g[2] + g[4] + 2 * g[3]))))
            let w = g.map { $0 * normalise }
            func mirror(_ coordinate: Int, _ size: Int) -> Int {
                if size == 1 { return 0 }
                if coordinate < 0 { return -coordinate - 1 }
                if coordinate >= size { return size - 1 - (coordinate - size) }
                return coordinate
            }
            var output = [Float](repeating: 0, count: input.count)
            for y in 0..<height { for x in 0..<width {
                func p(_ dx: Int, _ dy: Int) -> Float { input[mirror(y + dy, height) * width + mirror(x + dx, width)] }
                let axis1 = p(-1,0) + p(1,0) + p(0,-1) + p(0,1)
                let diag1 = p(-1,-1) + p(1,-1) + p(-1,1) + p(1,1)
                let axis2 = p(-2,0) + p(2,0) + p(0,-2) + p(0,2)
                let knight = p(-2,-1) + p(-2,1) + p(2,-1) + p(2,1) + p(-1,-2) + p(1,-2) + p(-1,2) + p(1,2)
                let corner = p(-2,-2) + p(2,-2) + p(-2,2) + p(2,2)
                output[y * width + x] = normalise * p(0,0) + w[0] * axis1 + w[1] * diag1 + w[2] * axis2 + w[3] * knight + w[4] * corner
            } }
            return output
        }
        for (width, height) in [(1,1),(1,7),(7,1),(2,2),(2,7),(7,2),(17,9),(257,3)] {
            let input: [Float] = (0..<(width * height)).map { (index: Int) -> Float in
                Float((index * 173 + 19) % 1021 - 510) / 127
            }
            let actual = try VarDCTEncoderPreparation.inverseGaborish(input, width: width, height: height, budget: budget())
            let expected = reference(input, width, height)
            #expect(actual.map(\.bitPattern) == expected.map(\.bitPattern))
        }
    }

    @Test func borrowedQuantisationMatchesArrayReferenceAndRejectsInvalidSamples() throws {
        let distances: [Float] = [0.1, 0.5, 1, 3, 25]
        let amplitudes: [Float] = [0, 0.0005, 0.005, 0.05, 0.5]
        var sawIntermediate = false
        for distance in distances {
            let maximum = Int32(min(Float(48), max(6, (24 / max(distance, 0.5)).rounded())))
            for amplitude in amplitudes { for seed in [0, 1, 17] {
                var channels: [[Float]] = []
                for channel in 0..<3 {
                    var samples: [Float] = []
                    for index in 0..<64 {
                        let value = (index * 113 + channel * 29 + seed) % 257 - 128
                        samples.append(Float(value) * amplitude)
                    }
                    channels.append(samples)
                }
                let reference = try VarDCTEncoderPreparation.quantisation(channels, distance: distance)
                let actual = try channels.flatMap { $0 }.withUnsafeBufferPointer {
                    try VarDCTEncoderPreparation.quantisation($0, distance: distance)
                }
                #expect(actual == reference)
                if amplitude == 0 { #expect(actual == 5) }
                if actual > 5 && actual < maximum { sawIntermediate = true }
            } }
        }
        #expect(sawIntermediate)
        let invalidDistances: [Float] = [0, -1, .infinity, .nan]
        for distance in invalidDistances {
            #expect(throws: VarDCTError.invalidTransform) {
                try [Float](repeating: 0, count: 192).withUnsafeBufferPointer {
                    try VarDCTEncoderPreparation.quantisation($0, distance: distance)
                }
            }
        }
        for count in [0, 191, 193] {
            #expect(throws: VarDCTError.invalidTransform) {
                try [Float](repeating: 0, count: count).withUnsafeBufferPointer {
                    try VarDCTEncoderPreparation.quantisation($0, distance: 1)
                }
            }
        }
        for index in [0, 63, 64, 191] {
            var patch = [Float](repeating: 0, count: 192); patch[index] = .nan
            #expect(throws: VarDCTError.nonFiniteSample) {
                try patch.withUnsafeBufferPointer { try VarDCTEncoderPreparation.quantisation($0, distance: 1) }
            }
        }
    }

    @Test func pinnedIndependentPrefilter() throws {
        let url = try #require(Bundle.module.url(forResource: "inverse-gaborish", withExtension: "f32", subdirectory: "VarDCT/Encoder"))
        let oracle = try Data(contentsOf: url)
        var offset = 0
        for (width,height) in [(1,1),(2,3),(7,5),(8,8),(17,9)] {
            for pattern in 0..<3 { for c in 0..<3 {
                let input: [Float] = (0..<(width * height)).map { i in
                    let x = i % width, y = i / width
                    return pattern == 0 ? 0.375 : pattern == 1 ? (x == 0 && y == 0 ? 1 : 0) : Float((x * 17 + y * 11 + c * 7) % 29 - 14) / 31
                }
                let actual = try VarDCTEncoderPreparation.inverseGaborish(input, width: width, height: height, budget: budget())
                for value in actual {
                    let bits = oracle.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
                    let expected = Float(bitPattern: UInt32(littleEndian: bits)); offset += 4
                    #expect(abs(value - expected) <= 0.000002 + 0.000002 * abs(expected))
                }
            } }
        }
        #expect(offset == oracle.count)
    }
    @Test func invalidPrefilterAndAdmission() throws {
        #expect(throws: VarDCTError.invalidTransform) { try VarDCTEncoderPreparation.inverseGaborish([], width: 0, height: 1, budget: budget()) }
        #expect(throws: VarDCTError.invalidTransform) { try VarDCTEncoderPreparation.inverseGaborish([0], width: 2, height: 2, budget: budget()) }
        #expect(throws: VarDCTError.nonFiniteSample) { try VarDCTEncoderPreparation.inverseGaborish([.nan], width: 1, height: 1, budget: budget()) }
        #expect(throws: (any Error).self) { try VarDCTEncoderPreparation.inverseGaborish([0], width: 1, height: 1, budget: budget(1)) }
    }
    @Test func adaptiveQuantisationAnchors() throws {
        let smooth = [[Float]](repeating: [Float](repeating: 0.25, count: 64), count: 3)
        #expect(try VarDCTEncoderPreparation.quantisation(smooth, distance: 1) == 5)
        let alternating: [Float] = (0..<64).map { $0 % 2 == 0 ? 0 : 0.5 }
        let patch = [alternating,alternating,alternating]
        #expect(try VarDCTEncoderPreparation.quantisation(patch, distance: 1) == 24)
        #expect(try VarDCTEncoderPreparation.quantisation(patch, distance: 4) == 6)
        #expect(try VarDCTEncoderPreparation.quantisation(patch, distance: 0.5) == 48)
    }
}

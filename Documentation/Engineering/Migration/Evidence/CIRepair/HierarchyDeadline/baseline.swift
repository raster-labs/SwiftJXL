// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

struct VarDCTHierarchicalAnalysisTests {
    private func budget(_ maximum: Int = 256 * 1024 * 1024) throws -> ScalarOperationBudget {
        try ScalarOperationBudget(retainedBytes: 0, maximumWorkspaceBytes: maximum,
            maximumMemoryBytes: maximum, maximumDecodedBytes: maximum,
            maximumCompressedBytes: maximum, deadline: .now.advanced(by: .seconds(30)))
    }
    private func fixture(_ name: String, _ suffix: String) throws -> Data {
        try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: suffix,
            subdirectory: "VarDCT/EncoderLarge")))
    }
    @Test(arguments: [16,32,64])
    func uniformRegionsSelectLargeTransforms(_ size: Int) throws {
        let operation = try budget(), planes = [[Float]](repeating: [Float](repeating: 0.375, count: size * size), count: 3)
        let result = try VarDCTHierarchicalAnalysis.analyse(planes, width: size, height: size,
            scale: 5111, distance: 1, adaptiveQuantisation: false, budget: operation)
        #expect(result.transforms.count == 1)
        #expect(result.transforms.first?.identifier == (size == 16 ? 4 : size == 32 ? 5 : 18))
        #expect(result.ac.allSatisfy { $0.allSatisfy { $0 == 0 } })
    }
    @Test func nestedQuantisationAndGroupBoundaries() throws {
        let width = 264, height = 65, bx = (width + 7) / 8, by = (height + 7) / 8
        // First cell in each 64×64 region is smooth, later cells are highly
        // textured. Their local adaptive QFs differ; the chosen nested leaves
        // must still inherit the enclosing region's first-cell QF.
        var planes = [[Float]](repeating: [Float](repeating: 0, count: width * height), count: 3)
        for y in 0..<height { for x in 0..<width {
            let value: Float = x % 64 < 8 && y % 64 < 8 ? 0.3 : Float((x * 17 + y * 13) % 31) / 40
            planes[0][y * width + x] = value / 8
            planes[1][y * width + x] = value
            planes[2][y * width + x] = value * 1.4
        } }
        let operation = try budget()
        let result = try VarDCTHierarchicalAnalysis.analyse(planes, width: width, height: height,
            scale: 5111, distance: 1, adaptiveQuantisation: true, budget: operation)
        let map = try VarDCTStrategyMap.read(result.strategies + result.quantisation.map { $0 - 1 },
            count: result.transforms.count, width: bx, height: by, budget: operation)
        #expect(map.transforms == result.transforms)
        #expect(result.ac.allSatisfy { $0.count == bx * by * 64 })
        #expect(map.indices.allSatisfy { $0 >= 0 })
        for transform in result.transforms {
            #expect(transform.x % 32 + transform.cellsX <= 32)
            #expect(transform.y % 32 + transform.cellsY <= 32)
        }
        let firstPatch = [[Float]](repeating: [Float](repeating: 0, count: 64), count: 3).enumerated().map { c, _ in
            [Float](repeating: c == 0 ? 0.3 / 8 : c == 1 ? 0.3 : 0.3 * 1.4, count: 64)
        }
        let firstQF = try VarDCTEncoderPreparation.quantisation(firstPatch, distance: 1)
        for transform in result.transforms where transform.x < 32 && transform.y < 8 {
            #expect(transform.quantisation == UInt32(firstQF))
        }
    }
    @Test(arguments: [4,5,6,7,8,9,10,11,18,19,20])
    func everyLargeWriterStrategyMatchesIndependentScalar(_ id: Int) throws {
        let operation = try budget(), plan = try VarDCTLargeAnalysis(identifier: id, budget: operation)
        let width = plan.columns, height = plan.rows, bx = width / 8, by = height / 8, cells = bx * by, count = width * height
        let input = Data(count: count * 6)
        let layouts = try (0..<3).map { try ModularChannelLayout(width: width, height: height, offset: $0 * 2,
            rowBytes: width * 6, pixelStride: 6, storageBits: 16, littleEndian: true) }
        let order = try VarDCTOrders.natural(width: max(bx,by), height: min(bx,by), budget: operation)
        var dc = [[Int32]](repeating: [Int32](repeating: 0, count: cells), count: 3)
        var ac = [[Int32]](repeating: [Int32](repeating: 0, count: count), count: 3)
        for i in 0..<cells { dc[1][i] = Int32(360 + 3 * (i % bx) + 2 * (i / bx)) }
        for c in 0..<3 { for k in stride(from: cells, to: count, by: 13) { ac[c][order[k]] = Int32((k + c) % 7 - 3) } }
        let transform = VarDCTStrategyMap.Transform(identifier: id, x: 0, y: 0, cellsX: bx, cellsY: by,
            quantisation: 5, coefficientOffset: 0)
        let coefficients = VarDCTPixelEncoder.Coefficients(width: width, height: height, blocksX: bx, blocksY: by,
            bits: 16, grayscale: false, hasAlpha: false, globalScale: 5111, quantAC: [5], strategies: [Int32(id)],
            gaborish: false, dcSmoothing: false, dc: dc, ac: ac, transforms: [transform])
        let encoded = try input.withUnsafeBytes { bytes in
            try ScalarEncodingWork.$current.withValue(.init(budget: operation, writerByteLimit: 1024 * 1024)) {
                try VarDCTFrameWriter(coefficients: coefficients,
                    source: VarDCTBorrowedSource(bytes: bytes, layouts: layouts, maximum: 65535),
                    budget: operation, limit: 1024 * 1024).write()
            }
        }
        #expect(try encoded == fixture("writer-\(id)", "jxl"))
        let envelope = try VarDCTFrameEnvelope.read(encoded, budget: budget())
        var decoded = Data(count: input.count)
        try decoded.withUnsafeMutableBytes { try VarDCTPixelDecoder.decode(envelope, into: $0, layouts: layouts) }
        let reference = try fixture("writer-\(id)", "scalar")
        #expect(reference.count == count * 12)
        var peak = 0, squared = 0.0
        for i in 0..<(count * 3) {
            let raw = reference.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self) }
            let expected = Int((min(1, max(0, Double(Float(bitPattern: UInt32(littleEndian: raw))))) * 65535).rounded())
            let actual = Int(decoded[i * 2]) | Int(decoded[i * 2 + 1]) << 8
            let difference = abs(actual - expected); peak = max(peak,difference); squared += Double(difference * difference)
        }
        #expect(peak <= 2)
        #expect(sqrt(squared / Double(count * 3)) <= 0.5)
    }
    @Test func invalidAndExhaustedSearch() throws {
        #expect(throws: (any Error).self) {
            try VarDCTHierarchicalAnalysis.analyse([], width: 16, height: 16, scale: 5111,
                distance: 1, adaptiveQuantisation: true, budget: budget())
        }
        #expect(throws: (any Error).self) {
            try VarDCTHierarchicalAnalysis.analyse([[Float]](repeating: [Float](repeating: 0, count: 256), count: 3),
                width: 16, height: 16, scale: 5111, distance: 1, adaptiveQuantisation: true, budget: budget(1024))
        }
    }
}

// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

struct VarDCTHierarchicalAnalysisTests {
    private func budget(_ maximum: Int = 256 * 1024 * 1024,
                        deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(30)),
                        cancellation: ScalarOperationCancellation? = nil) throws -> ScalarOperationBudget {
        try ScalarOperationBudget(retainedBytes: 0, maximumWorkspaceBytes: maximum,
            maximumMemoryBytes: maximum, maximumDecodedBytes: maximum,
            maximumCompressedBytes: maximum, deadline: deadline, cancellation: cancellation)
    }
    private func fixture(_ name: String, _ suffix: String) throws -> Data {
        try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: suffix,
            subdirectory: "VarDCT/EncoderLarge")))
    }
    @Test func normalisedStrategyShapesShareDecoderNaturalScans() throws {
        let operation = try budget()
        var writer = BitWriter()
        try writer.writeU32(0, distributions: (.literal(0x5f), .literal(0x13), .literal(0), .bits(13)))
        var reader = BitReader(writer.finishToData())
        // Decoder bucket geometry is an independent mapping from strategy IDs;
        // small strategies even use two distinct buckets for one natural scan.
        let decoded = try VarDCTOrders.read(from: &reader, usedBuckets: Set(0...8), budget: operation)
        var byShape: [Int: [Int]] = [:]
        for id in 0...20 {
            let rows: Int, columns: Int
            if [4,5,6,7,8,9,10,11,18,19,20].contains(id) {
                let plan = try VarDCTLargeAnalysis(identifier: id, budget: operation)
                rows = plan.rows; columns = plan.columns
            } else { rows = 8; columns = 8 }
            let transform = VarDCTStrategyMap.Transform(identifier: id, x: 0, y: 0,
                cellsX: columns / 8, cellsY: rows / 8, quantisation: 5, coefficientOffset: 0)
            let reference = try #require(decoded[transform.orderBucket])
            let natural = try VarDCTOrders.natural(width: max(rows, columns) / 8,
                height: min(rows, columns) / 8, budget: operation)
            #expect(reference.count == 3 && reference.allSatisfy { $0 == natural })
            let key = max(rows, columns) * 64 + min(rows, columns)
            if let prior = byShape[key] { #expect(prior == natural) }
            else { byShape[key] = natural }
        }
        #expect(byShape.count == 8)
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
    private func texturedPlanes(width: Int, height: Int) -> [[Float]] {
        // A smooth first cell and textured later cells give different local
        // adaptive QFs, exposing accidental re-quantisation of nested leaves.
        var planes = [[Float]](repeating: [Float](repeating: 0, count: width * height), count: 3)
        for y in 0..<height { for x in 0..<width {
            let value: Float = x % 64 < 8 && y % 64 < 8 ? 0.3 : Float((x * 17 + y * 13) % 31) / 40
            planes[0][y * width + x] = value / 8
            planes[1][y * width + x] = value
            planes[2][y * width + x] = value * 1.4
        } }
        return planes
    }
    private func checkStrategyMap(_ result: VarDCTHierarchicalAnalysis.Result,
                                  width: Int, height: Int, budget: ScalarOperationBudget) throws {
        let bx = (width + 7) / 8, by = (height + 7) / 8
        let map = try VarDCTStrategyMap.read(result.strategies + result.quantisation.map { $0 - 1 },
            count: result.transforms.count, width: bx, height: by, budget: budget)
        #expect(map.transforms == result.transforms)
        #expect(result.ac.allSatisfy { $0.count == bx * by * 64 })
        #expect(map.indices.count == bx * by)
        #expect(map.indices.allSatisfy { $0 >= 0 && $0 < result.transforms.count })
        for (index, transform) in result.transforms.enumerated() {
            #expect(transform.x % 32 + transform.cellsX <= 32)
            #expect(transform.y % 32 + transform.cellsY <= 32)
            for y in transform.y..<(transform.y + transform.cellsY) {
                for x in transform.x..<(transform.x + transform.cellsX) {
                    #expect(map.indices[y * bx + x] == index)
                }
            }
        }
    }
    @Test func nestedLeavesInheritRegionQuantisation() throws {
        // One full search region isolates QF inheritance. Group boundaries are
        // checked separately below, avoiding four duplicate textured searches
        // inside a single 30-second correctness-test operation under TSan.
        let width = 64, height = 64, planes = texturedPlanes(width: width, height: height)
        let operation = try budget()
        let result = try VarDCTHierarchicalAnalysis.analyse(planes, width: width, height: height,
            scale: 5111, distance: 1, adaptiveQuantisation: true, budget: operation)
        try checkStrategyMap(result, width: width, height: height, budget: operation)
        var firstPatch = [[Float]](repeating: [Float](repeating: 0, count: 64), count: 3)
        var laterPatch = firstPatch
        for channel in 0..<3 {
            for sample in 0..<64 {
                let rowOffset = (sample / 8) * width
                let column = sample % 8
                firstPatch[channel][sample] = planes[channel][rowOffset + column]
                laterPatch[channel][sample] = planes[channel][rowOffset + 8 + column]
            }
        }
        let firstQF = try VarDCTEncoderPreparation.quantisation(firstPatch, distance: 1)
        let laterQF = try VarDCTEncoderPreparation.quantisation(laterPatch, distance: 1)
        #expect(firstQF < laterQF)
        #expect(result.transforms.count > 1)
        #expect(result.transforms.allSatisfy { $0.quantisation == UInt32(firstQF) })
    }
    @Test(arguments: [false, true])
    func groupBoundariesAndPartialCells(_ vertical: Bool) throws {
        // Cross the 256-pixel AC-group boundary in both orientations, including
        // a partial final cell in the other dimension. Keep each independent
        // operation under the same deadline as every other hierarchy test.
        let width = vertical ? 17 : 264, height = vertical ? 264 : 17
        let operation = try budget()
        let result = try VarDCTHierarchicalAnalysis.analyse(texturedPlanes(width: width, height: height),
            width: width, height: height, scale: 5111, distance: 1,
            adaptiveQuantisation: true, budget: operation)
        try checkStrategyMap(result, width: width, height: height, budget: operation)
        #expect(result.transforms.contains { vertical ? $0.y == 32 : $0.x == 32 })
        #expect(result.transforms.contains { vertical ? $0.x == 2 : $0.y == 2 })
    }
    @Test func expiredAndCancelledSearchRejectBeforeWorkspaceAdmission() throws {
        let planes = [[Float]](repeating: [Float](repeating: 0.375, count: 256), count: 3)
        let expired = try budget(deadline: .now.advanced(by: .seconds(-1)))
        do {
            _ = try VarDCTHierarchicalAnalysis.analyse(planes, width: 16, height: 16,
                scale: 5111, distance: 1, adaptiveQuantisation: true, budget: expired)
            Issue.record("Expired search unexpectedly succeeded")
        } catch ScalarModularError.resourceLimit {}
        #expect(expired.reservedWorkspaceBytes == 0)
        let cancellation = ScalarOperationCancellation(), cancelled = try budget(cancellation: cancellation)
        cancellation.cancel()
        #expect(throws: CancellationError.self) {
            try VarDCTHierarchicalAnalysis.analyse(planes, width: 16, height: 16,
                scale: 5111, distance: 1, adaptiveQuantisation: true, budget: cancelled)
        }
        #expect(cancelled.reservedWorkspaceBytes == 0)
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
    @Test func packedSelectedCoefficientsMatchSeparateChannelAnalysis() throws {
        let width = 17, height = 9, bx = (width + 7) / 8, operation = try budget()
        let planes = texturedPlanes(width: width, height: height)
        let result = try VarDCTHierarchicalAnalysis.analyse(planes, width: width, height: height,
            scale: 5111, distance: 1, adaptiveQuantisation: false, budget: operation)
        let small = try VarDCTSmallAnalysis(budget: operation)
        let scales = [4096.0,512,256].map { Double(5111) * 17 * $0 / 65536 }
        for transform in result.transforms {
            let rows = transform.cellsY * 8, columns = transform.cellsX * 8
            let count = rows * columns, covered = count / 64
            let weights = try VarDCTQuantWeights.make(identifier: transform.identifier,
                rows: rows, columns: columns, budget: operation)
            let order = try VarDCTOrders.natural(width: max(rows, columns) / 8,
                height: min(rows, columns) / 8, budget: operation)
            for c in 0..<3 {
                var patch = [Float](repeating: 0, count: count)
                for y in 0..<rows { for x in 0..<columns {
                    let source = min(height - 1, transform.y * 8 + y) * width + min(width - 1, transform.x * 8 + x)
                    patch[y * columns + x] = c == 2 ? planes[2][source] - planes[1][source] : planes[c][source]
                } }
                let low: [Float], coefficients: [Float]
                if covered > 1 {
                    let analysed = try VarDCTLargeAnalysis(identifier: transform.identifier, budget: operation).apply(patch)
                    low = analysed.dc; coefficients = analysed.coefficients
                } else {
                    coefficients = try small.apply(patch, identifier: transform.identifier)
                    low = [coefficients[0]]
                }
                for y in 0..<transform.cellsY { for x in 0..<transform.cellsX {
                    let expected = Int32((Double(low[y * transform.cellsX + x]) * scales[c]).rounded())
                    #expect(result.dc[c][(transform.y + y) * bx + transform.x + x] == expected)
                } }
                var expected = [Int32](repeating: 0, count: count)
                for k in covered..<count {
                    let position = order[k]
                    expected[position] = Int32((Double(coefficients[position]) * Double(weights[c * count + position])
                        * Double(5111) / 65536 * Double(transform.quantisation)).rounded())
                }
                #expect(Array(result.ac[c][transform.coefficientOffset..<(transform.coefficientOffset + count)]) == expected)
            }
        }
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

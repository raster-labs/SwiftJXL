// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Adapted from JXLSwift VarDCT/{ACStrategy,ACStrategyImage}.swift at
// 57e81cb9e2411d1efac435b429a306a031744c1e. Copyright (c) 2026 Raster-Lab.
// JPEG XL Project Authors retain BSD-3-Clause; see libjxl-LICENSE.txt.
import Foundation

/// Validated raster coverage for all 27 JPEG XL transform identifiers. Parsing
/// a shape does not imply that its reconstruction kernel is implemented.
package struct VarDCTStrategyMap: Sendable {
    package struct Transform: Sendable, Equatable {
        package let identifier: Int
        package let x: Int, y: Int, cellsX: Int, cellsY: Int
        package let quantisation: UInt32
        package let coefficientOffset: Int
        package var coveredCells: Int { cellsX * cellsY }
        package var orderBucket: Int { VarDCTStrategyMap.orderBuckets[identifier] }
    }
    package let width: Int, height: Int
    package let transforms: [Transform]
    /// Transform index for every cell, including covered non-origin cells.
    package let indices: [Int]
    package let coefficientCount: Int
    private static let widths = [1,1,1,1,2,4,1,2,1,4,2,4,1,1,1,1,1,1,8,4,8,16,8,16,32,16,32]
    private static let heights = [1,1,1,1,2,4,2,1,4,1,4,2,1,1,1,1,1,1,8,8,4,16,16,8,32,32,16]
    private static let orderBuckets = [0,1,1,1,2,3,4,4,5,5,6,6,1,1,1,1,1,1,7,8,8,9,10,10,11,12,12]

    package static func read(_ values: [Int32], count: Int, width: Int, height: Int,
                             groupBlocks: Int = 32, budget: ScalarOperationBudget) throws -> Self {
        try budget.checkpoint()
        guard width > 0, height > 0, width <= 2048, height <= 2048,
              groupBlocks >= 32, groupBlocks <= 128, groupBlocks & (groupBlocks - 1) == 0,
              count > 0, count <= width * height, values.count == count * 2 else {
            throw VarDCTError.invalidTransform
        }
        let cells = width * height
        try budget.reserveWorkspace(ScalarOperationBudget.sum(
            ScalarOperationBudget.product(cells, MemoryLayout<Int>.stride),
            ScalarOperationBudget.product(count, 2 * MemoryLayout<Transform>.stride)))
        var indices = [Int](repeating: -1, count: cells), transforms: [Transform] = []
        transforms.reserveCapacity(count)
        var offset = 0
        for y in 0..<height { for x in 0..<width {
            if x & 31 == 0 { try budget.checkpoint() }
            if indices[y * width + x] >= 0 { continue }
            let i = transforms.count
            guard i < count, (0...26).contains(values[i]) else { throw VarDCTError.invalidTransform }
            let id = Int(values[i]), sx = widths[id], sy = heights[id]
            guard sx <= width - x, sy <= height - y,
                  x % groupBlocks + sx <= groupBlocks, y % groupBlocks + sy <= groupBlocks else {
                throw VarDCTError.invalidTransform
            }
            // QF is normatively clamped before adding one. Widening avoids
            // overflow for Int32 extrema; this is not sample clipping.
            let q = UInt32(1 + max(0, min(values[count + i], 255)))
            for yy in y..<(y + sy) { for xx in x..<(x + sx) {
                guard indices[yy * width + xx] == -1 else { throw VarDCTError.invalidTransform }
                indices[yy * width + xx] = i
            } }
            transforms.append(.init(identifier: id, x: x, y: y, cellsX: sx, cellsY: sy,
                quantisation: q, coefficientOffset: offset))
            offset += sx * sy * 64
        } }
        guard transforms.count == count, offset == cells * 64 else { throw VarDCTError.invalidTransform }
        return Self(width: width, height: height, transforms: transforms, indices: indices, coefficientCount: offset)
    }
}

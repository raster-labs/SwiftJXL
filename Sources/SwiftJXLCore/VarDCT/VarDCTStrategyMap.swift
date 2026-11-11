// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Raster Images Private Limited

import Foundation

/// Decodes and validates the VarDCT `AcStrategy` and adaptive quantisation block map (ISO/IEC 18181-1 §9.3.3, Table 42).
package struct VarDCTStrategyMap: Sendable, Equatable {
    package struct Transform: Sendable, Equatable {
        package let identifier: Int
        package let x: Int
        package let y: Int
        package let cellsX: Int
        package let cellsY: Int
        package let quantisation: UInt32
        package let coefficientOffset: Int

        package var coveredCells: Int {
            cellsX * cellsY
        }

        package var orderBucket: Int {
            VarDCTStrategyMap.orderBucket(for: identifier)
        }

        package init(
            identifier: Int,
            x: Int,
            y: Int,
            cellsX: Int,
            cellsY: Int,
            quantisation: UInt32,
            coefficientOffset: Int
        ) {
            self.identifier = identifier
            self.x = x
            self.y = y
            self.cellsX = cellsX
            self.cellsY = cellsY
            self.quantisation = quantisation
            self.coefficientOffset = coefficientOffset
        }
    }

    /// Block coverage `(cellsX, cellsY)` in 8x8 units for `AcStrategy` IDs `0...26` per ISO/IEC 18181-1 §9.3.3 Table 42.
    package static let blockDimensions: [(cellsX: Int, cellsY: Int)] = [
        (1, 1),   // 0: DCT8x8
        (1, 1),   // 1: HORNUSS
        (1, 1),   // 2: DCT2x2
        (1, 1),   // 3: DCT4x4
        (2, 2),   // 4: DCT16x16
        (4, 4),   // 5: DCT32x32
        (1, 2),   // 6: DCT16x8
        (2, 1),   // 7: DCT8x16
        (1, 4),   // 8: DCT32x8
        (4, 1),   // 9: DCT8x32
        (2, 4),   // 10: DCT32x16
        (4, 2),   // 11: DCT16x32
        (1, 1),   // 12: DCT4x8
        (1, 1),   // 13: DCT8x4
        (1, 1),   // 14: AFV0
        (1, 1),   // 15: AFV1
        (1, 1),   // 16: AFV2
        (1, 1),   // 17: AFV3
        (8, 8),   // 18: DCT64x64
        (4, 8),   // 19: DCT64x32
        (8, 4),   // 20: DCT32x64
        (16, 16), // 21: DCT128x128
        (8, 16),  // 22: DCT128x64
        (16, 8),  // 23: DCT64x128
        (32, 32), // 24: DCT256x256
        (16, 32), // 25: DCT256x128
        (32, 16), // 26: DCT128x256
    ]

    package static func dimensions(for identifier: Int) -> (cellsX: Int, cellsY: Int)? {
        guard blockDimensions.indices.contains(identifier) else { return nil }
        return blockDimensions[identifier]
    }

    package static func orderBucket(for identifier: Int) -> Int {
        switch identifier {
        case 0, 1, 2, 3, 12, 13: return 0
        case 14, 15, 16, 17: return 1
        case 4: return 2
        case 5: return 3
        case 6, 7: return 4
        case 8, 9: return 5
        case 10, 11: return 6
        case 18: return 7
        case 19, 20: return 8
        case 21: return 9
        case 22, 23: return 10
        case 24: return 11
        case 25, 26: return 12
        default: return 0
        }
    }

    package let width: Int
    package let height: Int
    package let transforms: [Transform]
    package let indices: [Int]
    package let coefficientCount: Int

    package static func read(
        _ values: [Int32],
        count: Int,
        width: Int,
        height: Int,
        budget: ScalarOperationBudget
    ) throws -> Self {
        try budget.checkpoint()
        guard width > 0, height > 0, count > 0 else {
            throw ScalarModularError.invalidInput("Invalid VarDCT strategy map dimensions")
        }
        let (totalCells, cellsOverflow) = width.multipliedReportingOverflow(by: height)
        let (doubleCount, countOverflow) = count.multipliedReportingOverflow(by: 2)
        let (totalCoeffs, coeffsOverflow) = totalCells.multipliedReportingOverflow(by: 64)
        guard !cellsOverflow, !countOverflow, !coeffsOverflow,
              count <= totalCells,
              values.count >= doubleCount else {
            throw ScalarModularError.invalidInput("Invalid VarDCT strategy map counts")
        }

        try budget.reserveWorkspace(
            ScalarOperationBudget.sum(
                ScalarOperationBudget.product(totalCells, MemoryLayout<Int>.stride),
                ScalarOperationBudget.product(count, MemoryLayout<Transform>.stride)
            )
        )

        var indices = [Int](repeating: -1, count: totalCells)
        var transforms: [Transform] = []
        transforms.reserveCapacity(count)

        var scan = 0
        var coefficientOffset = 0
        var coveredCells = 0

        for i in 0..<count {
            if (i & 255) == 0 { try budget.checkpoint() }
            while scan < totalCells && indices[scan] != -1 {
                scan += 1
            }
            guard scan < totalCells else {
                throw ScalarModularError.invalidInput("VarDCT strategy count exceeds uncovered blocks")
            }
            let x = scan % width
            let y = scan / width
            let id = Int(values[i])
            guard let (cellsX, cellsY) = dimensions(for: id),
                  x + cellsX <= width,
                  y + cellsY <= height else {
                throw ScalarModularError.invalidInput("Invalid or out-of-bounds VarDCT strategy")
            }

            for dy in 0..<cellsY {
                let rowBase = (y + dy) * width + x
                for dx in 0..<cellsX {
                    guard indices[rowBase + dx] == -1 else {
                        throw ScalarModularError.invalidInput("Overlapping VarDCT strategy blocks")
                    }
                    indices[rowBase + dx] = i
                }
            }

            let rawQ = Int64(values[count + i]) + 1
            let clampedQ = UInt32(min(256, max(1, rawQ)))
            transforms.append(
                Transform(
                    identifier: id,
                    x: x,
                    y: y,
                    cellsX: cellsX,
                    cellsY: cellsY,
                    quantisation: clampedQ,
                    coefficientOffset: coefficientOffset
                )
            )
            let blockCells = cellsX * cellsY
            coveredCells += blockCells
            coefficientOffset += blockCells * 64
        }

        guard coveredCells == totalCells, coefficientOffset == totalCoeffs else {
            throw ScalarModularError.invalidInput("Incomplete VarDCT strategy map coverage")
        }

        return Self(
            width: width,
            height: height,
            transforms: transforms,
            indices: indices,
            coefficientCount: coefficientOffset
        )
    }
}

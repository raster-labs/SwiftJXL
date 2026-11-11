// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Raster Images Private Limited

import Foundation

/// Natural zigzag and Lehmer-coded custom HF scan orders per ISO/IEC 18181-1 §9.3.4.
package enum VarDCTOrders {
    package static let orderCount = 13

    /// Order bucket `(cx, cy)` dimensions in 8x8 block units for `orderID in 0..<13` per ISO/IEC 18181-1 §9.3.4 Table 43.
    package static let orderDimensions: [(width: Int, height: Int)] = [
        (1, 1),   // 0: DCT8
        (1, 1),   // 1: AFV
        (2, 2),   // 2: DCT16
        (4, 4),   // 3: DCT32
        (2, 1),   // 4: DCT8x16
        (4, 1),   // 5: DCT8x32
        (4, 2),   // 6: DCT16x32
        (8, 8),   // 7: DCT64
        (8, 4),   // 8: DCT32x64
        (16, 16), // 9: DCT128
        (16, 8),  // 10: DCT64x128
        (32, 32), // 11: DCT256
        (32, 16), // 12: DCT128x256
    ]

    /// Computes the natural scan order for a normalized `(width * 8) x (height * 8)` transform block (`width >= height`).
    package static func natural(
        width: Int,
        height: Int,
        budget: ScalarOperationBudget
    ) throws -> [Int] {
        try budget.checkpoint()
        guard width > 0, height > 0, width >= height, width % height == 0 else {
            throw VarDCTError.invalidTransform
        }
        let w = width * 8
        let h = height * 8
        let (total, over) = w.multipliedReportingOverflow(by: h)
        guard !over else { throw VarDCTError.invalidTransform }

        try budget.reserveWorkspace(ScalarOperationBudget.product(total, MemoryLayout<Int>.stride))

        var order: [Int] = []
        order.reserveCapacity(total)

        // 1. Lowest-frequency (LLF) corner in row-major order.
        for y in 0..<height {
            for x in 0..<width {
                order.append(y * w + x)
            }
        }

        // 2. High-frequency (HF) coefficients sorted by scaled anti-diagonal zigzag.
        let yScale = width / height
        var hf: [(key1: Int, key2: Int, index: Int)] = []
        hf.reserveCapacity(total - width * height)

        for y in 0..<h {
            for x in 0..<w {
                if x < width && y < height { continue }
                let xs = x
                let ys = y * yScale
                let diag = xs + ys
                let secondary = (diag & 1) == 1 ? y : -y
                hf.append((diag, secondary, y * w + x))
            }
        }

        hf.sort { a, b in
            if a.key1 != b.key1 { return a.key1 < b.key1 }
            return a.key2 < b.key2
        }

        for item in hf {
            order.append(item.index)
        }
        return order
    }

    /// Computes the natural scan order for `AFV` (`orderID == 1`) per ISO/IEC 18181-1 §9.3.4.
    package static func naturalAFV(budget: ScalarOperationBudget) throws -> [Int] {
        return try natural(width: 1, height: 1, budget: budget)
    }

    /// Reads the `used_orders` U32 mask from `reader` and decodes the HF scan orders for `usedBuckets`.
    package static func read(
        from reader: inout BitReader,
        usedBuckets: Set<Int>,
        budget: ScalarOperationBudget
    ) throws -> [Int: [[Int]]] {
        try budget.checkpoint()
        let usedOrders = try reader.readU32((
            .literal(0x5F),
            .literal(0x13),
            .literal(0),
            .bits(13)
        ))
        let allOrders = try decodeOrders(
            usedOrders: usedOrders,
            from: &reader,
            budget: budget
        )
        var out: [Int: [[Int]]] = [:]
        for bucket in usedBuckets where bucket >= 0 && bucket < allOrders.count {
            if allOrders[bucket][0].isEmpty {
                let dims = orderDimensions[bucket]
                let nat = bucket == 1
                    ? try naturalAFV(budget: budget)
                    : try natural(width: dims.width, height: dims.height, budget: budget)
                out[bucket] = [nat, nat, nat]
            } else {
                out[bucket] = allOrders[bucket]
            }
        }
        return out
    }

    /// Decodes custom HF scan orders for a pass when `usedOrders != 0` per ISO/IEC 18181-1 §9.3.4.
    package static func decodeOrders(
        usedOrders: UInt32,
        from reader: inout BitReader,
        budget: ScalarOperationBudget
    ) throws -> [[[Int]]] {
        try budget.checkpoint()
        guard usedOrders < (1 << orderCount) else {
            throw ScalarModularError.invalidInput("Invalid VarDCT used_orders mask")
        }

        var result: [[[Int]]] = Array(
            repeating: Array(repeating: [], count: 3),
            count: orderCount
        )

        var naturalCache = [[Int]?](repeating: nil, count: orderCount)
        func getNatural(_ b: Int) throws -> [Int] {
            if let cached = naturalCache[b] { return cached }
            let dims = orderDimensions[b]
            let nat = b == 1
                ? try naturalAFV(budget: budget)
                : try natural(width: dims.width, height: dims.height, budget: budget)
            naturalCache[b] = nat
            return nat
        }

        if usedOrders == 0 {
            for b in 0..<9 {
                let nat = try getNatural(b)
                for c in 0..<3 {
                    result[b][c] = nat
                }
            }
            return result
        }

        let header = try EntropySectionHeader.read(from: &reader, numContexts: 8)
        let codebook = try MultiClusterCodebook.read(from: &reader, header: header)
        try budget.reserveWorkspace(
            ScalarOperationBudget.product(codebook.ansCounts.count, 64 * 1024)
        )
        var stream = TokenStreamReader(header: header, codebook: codebook)

        for b in 0..<orderCount {
            let nat = try getNatural(b)
            let dims = orderDimensions[b]
            let llf = dims.width * dims.height
            let total = llf * 64
            if (usedOrders & (UInt32(1) << b)) != 0 {
                for c in 0..<3 {
                    result[b][c] = try decodeLehmerPermutation(
                        naturalOrder: nat,
                        llfCount: llf,
                        totalCount: total,
                        stream: &stream,
                        from: &reader,
                        budget: budget
                    )
                }
            } else if b < 9 {
                for c in 0..<3 {
                    result[b][c] = nat
                }
            }
        }

        try stream.finish(from: &reader)
        return result
    }

    @inline(__always)
    private static func lehmerContext(_ x: Int) -> Int {
        guard x > 0 else { return 0 }
        return min(7, Int.bitWidth - x.leadingZeroBitCount)
    }

    private static func decodeLehmerPermutation(
        naturalOrder: [Int],
        llfCount: Int,
        totalCount: Int,
        stream: inout TokenStreamReader,
        from reader: inout BitReader,
        budget: ScalarOperationBudget
    ) throws -> [Int] {
        try budget.checkpoint()
        try budget.reserveWorkspace(ScalarOperationBudget.product(totalCount, MemoryLayout<Int>.stride * 3))
        let rawEnd = try stream.readToken(context: lehmerContext(totalCount), from: &reader)
        guard let endDelta = Int(exactly: rawEnd),
              case let (end, over) = endDelta.addingReportingOverflow(llfCount),
              !over,
              end <= totalCount else {
            throw VarDCTError.invalidTransform
        }
        var lehmer = [Int](repeating: 0, count: totalCount)
        var prev = 0
        for i in llfCount..<end {
            if (i & 255) == 0 { try budget.checkpoint() }
            let ctx = lehmerContext(prev)
            let rawVal = try stream.readToken(context: ctx, from: &reader)
            guard let val = Int(exactly: rawVal), val < totalCount - i else {
                throw VarDCTError.invalidTransform
            }
            lehmer[i] = val
            prev = val
        }

        var available = Array(0..<totalCount)
        var perm = [Int](repeating: 0, count: totalCount)
        for i in 0..<totalCount {
            let idx = lehmer[i]
            let chosen = available.remove(at: idx)
            perm[i] = naturalOrder[chosen]
        }
        return perm
    }
}

/// VarDCT HF block context and non-zero / zero-density context calculation per ISO/IEC 18181-1 §§9.3.2, 9.3.5, 9.3.6.
package enum VarDCTEntropy {
    package static let defaultNumBlockClusters = 15
    package static let nonZeroBuckets = 37
    package static let zeroDensityContextsPerCluster = 458
    package static let contextsPerBlockCluster = nonZeroBuckets + zeroDensityContextsPerCluster // 495

    /// Default 39-entry block context map (`c_idx in 0..<3`, `orderID in 0..<13`) where `c_idx` is `[Y=0, X=1, B=2]`.
    package static let defaultBlockCtxMap: [Int] = [
        // c_idx = 0 (Y, channel 1)
        0, 1, 2, 2, 3, 3, 4, 5, 6, 6, 6, 6, 6,
        // c_idx = 1 (X / Cb, channel 0)
        7, 8, 9, 9, 10, 11, 12, 13, 14, 14, 14, 14, 14,
        // c_idx = 2 (B / Cr, channel 2)
        7, 8, 9, 9, 10, 11, 12, 13, 14, 14, 14, 14, 14,
    ]

    private static let coeffFreqContext: [Int] = [
        0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
        15, 15, 16, 16, 17, 17, 18, 18, 19, 19, 20, 20, 21, 21, 22, 22,
        23, 23, 23, 23, 24, 24, 24, 24, 25, 25, 25, 25, 26, 26, 26, 26,
        27, 27, 27, 27, 28, 28, 28, 28, 29, 29, 29, 29, 30, 30, 30, 30,
    ]

    private static let coeffNumNonzeroContext: [Int] = [
        0, 0, 31, 62, 62, 93, 93, 93, 93, 123, 123, 123, 123, 152, 152, 152,
        152, 152, 152, 152, 152, 180, 180, 180, 180, 180, 180, 180, 180, 180, 180, 180,
        180, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206,
        206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206,
    ]

    @inline(__always)
    package static func blockContext(
        channel: Int,
        orderBucket: Int,
        blockCtxMap: [Int] = defaultBlockCtxMap
    ) -> Int {
        let cIdx = (channel == 1) ? 0 : (channel == 0 ? 1 : 2)
        return blockCtxMap[cIdx * 13 + orderBucket]
    }

    @inline(__always)
    package static func predictedNonZeros(
        x: Int,
        y: Int,
        width: Int,
        grid: UnsafeBufferPointer<Int32>
    ) -> Int {
        if x == 0 && y == 0 { return 32 }
        if x == 0 { return Int(grid[(y - 1) * width]) }
        if y == 0 { return Int(grid[y * width + (x - 1)]) }
        let top = Int(grid[(y - 1) * width + x])
        let left = Int(grid[y * width + (x - 1)])
        return (top + left + 1) >> 1
    }

    @inline(__always)
    package static func nonZeroContext(
        predicted: Int,
        blockContext: Int,
        numBlockClusters: Int = defaultNumBlockClusters
    ) -> Int {
        let clamped = min(64, max(0, predicted))
        let bucket = clamped < 8 ? clamped : (4 + (clamped >> 1))
        return blockContext + numBlockClusters * bucket
    }

    @inline(__always)
    package static func zeroDensityContext(
        nonZerosLeft: Int,
        k: Int,
        log2CoveredBlocks: Int,
        prev: Int,
        blockContext: Int,
        numBlockClusters: Int = defaultNumBlockClusters
    ) -> Int {
        let normNZ = min(63, max(1, (nonZerosLeft + (1 << log2CoveredBlocks) - 1) >> log2CoveredBlocks))
        let normK = min(63, max(1, k >> log2CoveredBlocks))
        let density = (coeffNumNonzeroContext[normNZ] + coeffFreqContext[normK]) * 2 + prev
        return numBlockClusters * nonZeroBuckets + blockContext * zeroDensityContextsPerCluster + density
    }
}

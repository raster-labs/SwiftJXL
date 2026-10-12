// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Adapted from JXLSwift VarDCT/{ACContext,ACDecoder,CoeffOrders}.swift at
// 57e81cb9e2411d1efac435b429a306a031744c1e. Copyright (c) 2026 Raster-Lab.
// JPEG XL Project Authors retain BSD-3-Clause; see libjxl-LICENSE.txt.
import Foundation

extension JPEGBridgeBlockContext {
    /// Generic VarDCT context; JPEG bridge continues to use its DCT8-only path.
    func varDCTContext(dcValues: [Int32], quantisation: UInt32, channel: Int, order: Int) throws -> Int {
        guard dcValues.count == 3, (0..<3).contains(channel), (0..<13).contains(order) else {
            throw VarDCTError.invalidTransform
        }
        let a = dc[0].reduce(0) { $0 + (dcValues[0] > $1 ? 1 : 0) }
        let b = dc[1].reduce(0) { $0 + (dcValues[1] > $1 ? 1 : 0) }
        let c = dc[2].reduce(0) { $0 + (dcValues[2] > $1 ? 1 : 0) }
        let bucket = (a * (dc[2].count + 1) + c) * (dc[1].count + 1) + b
        let quantBucket = qf.reduce(0) { $0 + (quantisation > $1 ? 1 : 0) }
        let mapped = channel < 2 ? channel ^ 1 : 2
        let index = ((mapped * 13 + order) * (qf.count + 1) + quantBucket) * dcContexts + bucket
        guard map.indices.contains(index), Int(map[index]) < classes else { throw VarDCTError.invalidTransform }
        return Int(map[index])
    }

    func readVarDCTBlock(prediction: UInt32, blockContext: Int, offset: Int, order: [Int],
                         coveredCells: Int, stream: inout TokenStreamReader, from r: inout BitReader,
                         budget: ScalarOperationBudget) throws -> (coefficients: [Int32], nonzeros: Int) {
        try budget.checkpoint()
        guard (1...1024).contains(coveredCells), coveredCells & (coveredCells - 1) == 0,
              order.count == coveredCells * 64, (0..<classes).contains(blockContext), prediction <= 64,
              offset >= 0, offset <= 64 * 16 * 495 else { throw VarDCTError.invalidTransform }
        let size = order.count, shift = coveredCells.trailingZeroBitCount
        try budget.reserveWorkspace(size * MemoryLayout<Int32>.stride)
        var block = [Int32](repeating: 0, count: size)
        let bucket = prediction < 8 ? Int(prediction) : 4 + Int(prediction) / 2
        let count = try stream.readToken(context: offset + bucket * classes + blockContext, from: &r)
        guard count <= size - coveredCells else { throw VarDCTError.invalidTransform }
        var remaining = Int(count), previous = Int(count) > size / 16 ? 0 : 1
        let base = offset + classes * 37 + 458 * blockContext
        for k in coveredCells..<size {
            if remaining == 0 { break }
            if k & 255 == 0 { try budget.checkpoint() }
            let nz = (remaining + coveredCells - 1) >> shift, position = k >> shift
            guard (1..<64).contains(nz), (1..<64).contains(position), (0..<size).contains(order[k]) else {
                throw VarDCTError.invalidTransform
            }
            let context = base + (Int(kCoeffNumNonzeroContext[nz]) + Int(kCoeffFreqContext[position])) * 2 + previous
            let value = try stream.readToken(context: context, from: &r)
            block[order[k]] = ZigZag.unpack(value)
            previous = value == 0 ? 0 : 1; remaining -= previous
        }
        guard remaining == 0 else { throw VarDCTError.invalidTransform }
        return (block, Int(count))
    }
}

/// Per-order coefficient scans. Every encoded permutation is consumed, even if
/// a frame does not use that bucket; all allocations and scans are admitted.
package enum VarDCTOrders {
    private static let shapes = [(1,1),(1,1),(2,2),(4,4),(2,1),(4,1),(4,2),
                                 (8,8),(8,4),(16,16),(16,8),(32,32),(32,16)]
    package static func read(from r: inout BitReader, usedBuckets: Set<Int>,
                             budget: ScalarOperationBudget) throws -> [Int: [[Int]]] {
        guard usedBuckets.allSatisfy({ (0..<13).contains($0) }) else { throw VarDCTError.invalidTransform }
        let used = try r.readU32((.literal(0x5f), .literal(0x13), .literal(0), .bits(13)))
        var stream: TokenStreamReader?
        if used != 0 {
            let header = try EntropySectionHeader.read(from: &r, numContexts: 8)
            let codebook = try MultiClusterCodebook.read(from: &r, header: header)
            stream = TokenStreamReader(header: header, codebook: codebook)
        }
        var result: [Int: [[Int]]] = [:]
        func context(_ value: UInt32) -> Int { value == 0 ? 0 : min(32 - value.leadingZeroBitCount, 7) }
        for bucket in 0..<13 where used & (1 << bucket) != 0 || usedBuckets.contains(bucket) {
            try budget.checkpoint()
            let shape = shapes[bucket], skip = shape.0 * shape.1, size = skip * 64
            try budget.reserveWorkspace(size * MemoryLayout<Int>.stride * 10)
            let natural = try natural(width: shape.0, height: shape.1, budget: budget)
            var orders: [[Int]] = []
            for _ in 0..<3 {
                guard used & (1 << bucket) != 0 else { orders.append(natural); continue }
                guard var tokens = stream else { throw VarDCTError.invalidTransform }
                let endToken = try tokens.readToken(context: context(UInt32(size)), from: &r)
                guard endToken <= UInt32(size - skip) else { throw VarDCTError.invalidTransform }
                let end = Int(endToken) + skip
                var lehmer = [Int](repeating: 0, count: size), last: UInt32 = 0
                for i in skip..<end {
                    if i & 255 == 0 { try budget.checkpoint() }
                    last = try tokens.readToken(context: context(last), from: &r)
                    guard last < size - i else { throw VarDCTError.invalidTransform }
                    lehmer[i] = Int(last)
                }
                stream = tokens
                // Fenwick rank selection is O(n log n), avoiding quadratic
                // remove(at:) on an attacker-selected 65536-coefficient order.
                var tree = [Int](repeating: 0, count: size + 1)
                for i in 1...size { tree[i] = i & -i }
                var order = [Int](repeating: 0, count: size)
                for i in 0..<size {
                    if i & 255 == 0 { try budget.checkpoint() }
                    var rank = lehmer[i] + 1, index = 0, bit = size
                    while bit > 0 {
                        let next = index + bit
                        if next <= size, tree[next] < rank { index = next; rank -= tree[next] }
                        bit >>= 1
                    }
                    guard index < size else { throw VarDCTError.invalidTransform }
                    order[i] = natural[index]
                    var cursor = index + 1
                    while cursor <= size { tree[cursor] -= 1; cursor += cursor & -cursor }
                }
                orders.append(order)
            }
            if usedBuckets.contains(bucket) { result[bucket] = orders }
        }
        if var stream { try stream.finish() }
        return result
    }

    package static func natural(width: Int, height: Int, budget: ScalarOperationBudget) throws -> [Int] {
        guard width >= height, [1,2,4,8,16,32].contains(width), [1,2,4,8,16,32].contains(height) else {
            throw VarDCTError.invalidTransform
        }
        let size = width * height * 64, ratio = width / height
        try budget.reserveWorkspace(size * MemoryLayout<Int>.stride)
        var output = [Int](repeating: -1, count: size), cursor = width * height
        func append(_ x: Int, _ y: Int) throws {
            if y % ratio != 0 { return }
            let row = y / ratio
            let slot = x < width && row < height ? row * width + x : cursor
            if !(x < width && row < height) { cursor += 1 }
            guard slot < size, output[slot] == -1 else { throw VarDCTError.invalidTransform }
            output[slot] = row * width * 8 + x
        }
        for diagonal in 0..<(width * 8) {
            try budget.checkpoint()
            for j in 0...diagonal {
                let x = diagonal & 1 == 0 ? j : diagonal - j
                let y = diagonal & 1 == 0 ? diagonal - j : j
                try append(x, y)
            }
        }
        for diagonal in stride(from: width * 8 - 2, through: 0, by: -1) {
            try budget.checkpoint()
            for j in 0...diagonal {
                let a = width * 8 - 1 - (diagonal - j), b = width * 8 - 1 - j
                try append(diagonal & 1 == 0 ? a : b, diagonal & 1 == 0 ? b : a)
            }
        }
        guard cursor == size, output.allSatisfy({ (0..<size).contains($0) }) else { throw VarDCTError.invalidTransform }
        return output
    }
}

private let kCoeffFreqContext: [UInt16] = [
    0xBAD, 0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14,
    15,    15, 16, 16, 17, 17, 18, 18, 19, 19, 20, 20, 21, 21, 22, 22,
    23,    23, 23, 23, 24, 24, 24, 24, 25, 25, 25, 25, 26, 26, 26, 26,
    27,    27, 27, 27, 28, 28, 28, 28, 29, 29, 29, 29, 30, 30, 30, 30,
]
private let kCoeffNumNonzeroContext: [UInt16] = [
    0xBAD, 0,   31,  62,  62,  93,  93,  93,  93,  123, 123, 123, 123,
    152,   152, 152, 152, 152, 152, 152, 152, 180, 180, 180, 180, 180,
    180,   180, 180, 180, 180, 180, 180, 206, 206, 206, 206, 206, 206,
    206,   206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206,
    206,   206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206,
]

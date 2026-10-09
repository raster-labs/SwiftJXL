// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Copyright (c) 2026 Raster-Lab.
// Adapted from JXLSwift VarDCT/{ACContext,ACDecoder,CoeffOrders}.swift at
// 57e81cb9e2411d1efac435b429a306a031744c1e. JPEG XL Project Authors
// retain BSD-3-Clause terms; see Documentation/ThirdParty/libjxl-LICENSE.txt.
import Foundation

package struct JPEGBridgeBlockContext {
    let dc: [[Int32]]
    let qf: [UInt32]
    let map: [UInt8]
    let dcContexts: Int
    let classes: Int
    var contexts: Int { classes * (37 + 458) }

    static func read(from r: inout BitReader) throws -> Self {
        if try r.readBit() { return Self(dc: [[], [], []], qf: [], map: kDefaultBlockCtxMap, dcContexts: 1, classes: 15) }
        var dc: [[Int32]] = [], qf: [UInt32] = [], dcContexts = 1
        for _ in 0..<3 {
            let count = Int(try r.read(bits: 4)); dcContexts *= count + 1
            var thresholds: [Int32] = []
            for _ in 0..<count {
                let raw = try r.readU32((.bits(4), .offset(constant: 16, extraBits: 8),
                    .offset(constant: 272, extraBits: 16), .offset(constant: 65808, extraBits: 32)))
                thresholds.append(ZigZag.unpack(raw))
            }
            dc.append(thresholds)
        }
        let count = Int(try r.read(bits: 4))
        guard dcContexts * (count + 1) <= 64 else { throw JPEGEntropyError.malformed }
        for _ in 0..<count {
            qf.append(try r.readU32((.bits(2), .offset(constant: 4, extraBits: 3),
                .offset(constant: 12, extraBits: 5), .offset(constant: 44, extraBits: 8))) + 1)
        }
        let map = try ContextMap.read(numContexts: 39 * dcContexts * (count + 1), from: &r)
        guard (1...16).contains(map.numClusters) else { throw JPEGEntropyError.malformed }
        return Self(dc: dc, qf: qf, map: map.map, dcContexts: dcContexts, classes: map.numClusters)
    }

    func blockContext(dcValues: [Int32], quantisation: UInt32, channel: Int) throws -> Int {
        guard dcValues.count == 3, (0..<3).contains(channel) else { throw JPEGEntropyError.malformed }
        let a = dc[0].reduce(0) { $0 + (dcValues[0] > $1 ? 1 : 0) }
        let b = dc[1].reduce(0) { $0 + (dcValues[1] > $1 ? 1 : 0) }
        let c = dc[2].reduce(0) { $0 + (dcValues[2] > $1 ? 1 : 0) }
        let bucket = (a * (dc[2].count + 1) + c) * (dc[1].count + 1) + b
        let quantBucket = qf.reduce(0) { $0 + (quantisation > $1 ? 1 : 0) }
        let mappedChannel = channel < 2 ? channel ^ 1 : 2
        let index = (mappedChannel * 13 * (qf.count + 1) + quantBucket) * dcContexts + bucket
        guard map.indices.contains(index), Int(map[index]) < classes else { throw JPEGEntropyError.malformed }
        return Int(map[index])
    }

    func readBlock(prediction: UInt32, blockContext: Int, offset: Int, order: [Int],
                   stream: inout TokenStreamReader, from r: inout BitReader, into block: inout [Int32]) throws -> Int {
        guard block.count == 64, order.count == 64, (0..<classes).contains(blockContext), prediction <= 64 else {
            throw JPEGEntropyError.malformed
        }
        for i in 0..<64 { block[i] = 0 }
        let bucket = prediction < 8 ? Int(prediction) : 4 + Int(prediction) / 2
        let nonzeros = try stream.readToken(context: offset + bucket * classes + blockContext, from: &r)
        guard nonzeros <= 63 else { throw JPEGEntropyError.malformed }
        var remaining = Int(nonzeros), previous = nonzeros > 4 ? 0 : 1
        let base = offset + classes * 37 + 458 * blockContext
        for k in 1..<64 {
            if remaining == 0 { break }
            let context = base + (Int(kCoeffNumNonzeroContext[remaining]) + Int(kCoeffFreqContext[k])) * 2 + previous
            let value = try stream.readToken(context: context, from: &r)
            guard (1..<64).contains(order[k]) else { throw JPEGEntropyError.malformed }
            block[order[k]] = ZigZag.unpack(value)
            previous = value == 0 ? 0 : 1
            remaining -= previous
        }
        guard remaining == 0 else { throw JPEGEntropyError.malformed }
        return Int(nonzeros)
    }
}

package func readJPEGBridgeOrders(from r: inout BitReader) throws -> [[Int]] {
    let used = try r.readU32((.literal(0x5f), .literal(0x13), .literal(0), .bits(13)))
    guard used <= 1 else { throw JPEGEntropyError.unsupported }
    if used == 0 { return [jpegBridgeNaturalOrder, jpegBridgeNaturalOrder, jpegBridgeNaturalOrder] }
    let header = try EntropySectionHeader.read(from: &r, numContexts: 8)
    let codebook = try MultiClusterCodebook.read(from: &r, header: header)
    var stream = TokenStreamReader(header: header, codebook: codebook)
    func context(_ v: UInt32) -> Int { v == 0 ? 0 : min(32 - v.leadingZeroBitCount, 7) }
    var orders: [[Int]] = []
    for _ in 0..<3 {
        let end = Int(try stream.readToken(context: context(64), from: &r)) + 1
        guard end <= 64 else { throw JPEGEntropyError.malformed }
        var lehmer = [Int](repeating: 0, count: 64), last: UInt32 = 0
        for i in 1..<end {
            last = try stream.readToken(context: context(last), from: &r)
            guard last < UInt32(64 - i) else { throw JPEGEntropyError.malformed }
            lehmer[i] = Int(last)
        }
        var remaining = Array(0..<64), order: [Int] = []
        for i in 0..<64 { order.append(jpegBridgeNaturalOrder[remaining.remove(at: lehmer[i])]) }
        orders.append(order)
    }
    try stream.finish()
    return orders
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
private let kDefaultBlockCtxMap: [UInt8] = [
    0, 1, 2, 2, 3,  3,  4,  5,  6,  6,  6,  6,  6,
    7, 8, 9, 9, 10, 11, 12, 13, 14, 14, 14, 14, 14,
    7, 8, 9, 9, 10, 11, 12, 13, 14, 14, 14, 14, 14,
]
package let jpegBridgeNaturalOrder: [Int] = [
    0,  1,  8, 16,  9,  2,  3, 10, 17, 24, 32, 25, 18, 11,  4,  5,
   12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13,  6,  7, 14, 21, 28,
   35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
   58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63
]

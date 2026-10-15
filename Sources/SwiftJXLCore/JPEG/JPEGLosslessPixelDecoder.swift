// SPDX-License-Identifier: Apache-2.0
// Predictor formulae adapted from JXLSwift JPEGLosslessDecoder.swift at
// 57e81cb9e2411d1efac435b429a306a031744c1e; bounded framing and validation
// are new. ITU-T T.81 Annex H (non-differential Huffman lossless JPEG).
import Foundation

package enum JPEGLosslessPixelDecoder {
    /// Full-resolution grey or stored RGB; no implicit colour transform.
    /// One previous-row buffer per component is updated in place. The saved
    /// upper-left scalar preserves its overwritten neighbour. Final samples are
    /// emitted directly into the scoped owning destination, including orientation.
    package static func decode(_ source: Data, frame: JPEGFrameLayout,
                               budget: ScalarOperationBudget, into bytes: UnsafeMutableRawBufferPointer,
                               layouts: [ModularChannelLayout], orientation: Int) throws {
        var reader = try JPEGSegmentReader(source, maximumInputBytes: budget.maximumCompressedBytes,
            deadline: budget.deadline, checkpoint: { try budget.checkpoint() })
        var tables = [JPEGHuffmanTable?](repeating: nil, count: 4)
        var rows = frame.components.map { _ in [Int](repeating: 0, count: frame.width) }
        for _ in frame.components { ScalarStorageAudit.current?.workingPlane(frame.width * MemoryLayout<Int>.stride) }
        var seen = Set<Int>(), restartInterval = 0, sawFrame = false
        func byte(_ p: Int) -> UInt8 { source[source.startIndex + p] }
        while let segment = try reader.next() {
            try budget.checkpoint()
            let r = segment.payloadRange
            switch segment.markerByte {
            case 0xd8, 0xd9, 0xe0...0xef, 0xfe: break
            case 0xc3:
                guard !sawFrame else { throw JPEGEntropyError.malformed }
                sawFrame = true
            case 0xc4:
                var p = r.lowerBound
                guard !r.isEmpty else { throw JPEGEntropyError.malformed }
                while p < r.upperBound {
                    guard r.upperBound - p >= 17 else { throw JPEGEntropyError.malformed }
                    let id = Int(byte(p)); p += 1
                    guard id < 4 else { throw JPEGEntropyError.malformed }
                    let counts = (0..<16).map { Int(byte(p + $0)) }; p += 16
                    let total = counts.reduce(0, +)
                    guard total <= 256, total <= r.upperBound - p else { throw JPEGEntropyError.malformed }
                    let symbols = (0..<total).map { byte(p + $0) }; p += total
                    guard symbols.allSatisfy({ $0 <= 16 }) else { throw JPEGEntropyError.malformed }
                    tables[id] = try JPEGHuffmanTable(counts: counts, symbols: symbols)
                }
            case 0xdd:
                guard r.count == 2 else { throw JPEGEntropyError.malformed }
                restartInterval = Int(byte(r.lowerBound)) * 256 + Int(byte(r.lowerBound + 1))
            case 0xda:
                guard sawFrame, r.count >= 6 else { throw JPEGEntropyError.malformed }
                let n = Int(byte(r.lowerBound))
                guard (1...frame.components.count).contains(n), r.count == 4 + 2 * n else { throw JPEGEntropyError.malformed }
                let predictor = Int(byte(r.lowerBound + 1 + 2 * n))
                let point = Int(byte(r.lowerBound + 3 + 2 * n))
                guard (1...7).contains(predictor), byte(r.lowerBound + 2 + 2 * n) == 0,
                      point < frame.precision else { throw JPEGEntropyError.malformed }
                // T.81 H.2.1 requires restart intervals to contain whole MCU rows.
                guard restartInterval == 0 || restartInterval % frame.width == 0 else { throw JPEGEntropyError.malformed }
                var components: [(Int, JPEGHuffmanTable)] = []
                for i in 0..<n {
                    let id = byte(r.lowerBound + 1 + i * 2), selection = Int(byte(r.lowerBound + 2 + i * 2))
                    guard let c = frame.components.firstIndex(where: { $0.id == id }),
                          !seen.contains(c), selection & 15 == 0, selection >> 4 < 4,
                          let table = tables[selection >> 4] else { throw JPEGEntropyError.malformed }
                    seen.insert(c); components.append((c, table))
                }
                var bits = try JPEGEntropyReader(data: source, range: segment.entropyRange, checkpoint: { try budget.checkpoint() })
                var restart: UInt8 = 0, firstRow = 0
                var upperLeft = [Int](repeating: 0, count: frame.components.count)
                let reducedBits = frame.precision - point, mask = (1 << reducedBits) - 1
                for y in 0..<frame.height {
                    try budget.checkpoint()
                    for c in upperLeft.indices { upperLeft[c] = 0 }
                    for x in 0..<frame.width {
                        let p = y * frame.width + x
                        if p > 0, restartInterval > 0, p % restartInterval == 0 {
                            _ = try bits.restart(0xd0 + restart); restart = (restart + 1) & 7; firstRow = y
                        }
                        for (c, table) in components {
                            let category = Int(try table.symbol(&bits))
                            // Predictors 4–6 can exceed the sample domain; their
                            // legal differences need more than P-Pt bits. Annex H
                            // defines 16-bit modular difference arithmetic.
                            let difference = category == 16 ? 32768 : Int(try bits.magnitude(category))
                            let predicted: Int
                            if y == firstRow { predicted = x == 0 ? 1 << (reducedBits - 1) : rows[c][x - 1] }
                            else if x == 0 { predicted = rows[c][x] }
                            else {
                                let a = rows[c][x - 1], b = rows[c][x]
                                let previous = upperLeft[c]
                                switch predictor {
                                case 1: predicted = a
                                case 2: predicted = b
                                case 3: predicted = previous
                                case 4: predicted = a + b - previous
                                case 5: predicted = a + ((b - previous) >> 1)
                                case 6: predicted = b + ((a - previous) >> 1)
                                default: predicted = (a + b) >> 1
                                }
                            }
                            let reduced = (predicted + difference) & 0xffff
                            guard reduced <= mask else { throw JPEGEntropyError.malformed }
                            upperLeft[c] = rows[c][x]; rows[c][x] = reduced
                            let sample = UInt16(reduced << point)
                            let (dx, dy) = JPEGPixelFrame.destinationPosition(x: x, y: y,
                                width: frame.width, height: frame.height, orientation: orientation)
                            let layout = layouts[c]
                            let address = layout.offset + dy * layout.rowBytes + dx * layout.pixelStride
                            let low = UInt8(truncatingIfNeeded: sample), high = UInt8(sample >> 8)
                            if layout.storageBits == 8 { bytes[address] = low }
                            else {
                                bytes[address] = layout.littleEndian ? low : high
                                bytes[address + 1] = layout.littleEndian ? high : low
                            }
                        }
                    }
                }
                _ = try bits.finish()

            default: throw JPEGEntropyError.unsupported
            }
        }
        guard seen.count == frame.components.count else { throw JPEGEntropyError.malformed }
        try budget.checkpoint()
    }
}

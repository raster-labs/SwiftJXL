// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Raster Images Private Limited

import Dispatch
import Foundation

/// Gaborish 3x3 smoothing convolution per ISO/IEC 18181-1 §10.4.1.
package enum Gaborish {
    package static let defaultWeight1: Float = 0.115169525
    package static let defaultWeight2: Float = 0.061248592

    package static func apply(
        _ input: [Float],
        width: Int,
        height: Int,
        stride: Int,
        weight1: Float = defaultWeight1,
        weight2: Float = defaultWeight2,
        budget: ScalarOperationBudget
    ) throws -> [Float] {
        try budget.checkpoint()
        guard width > 0, height > 0, stride >= width,
              weight1.isFinite, weight1 >= 0,
              weight2.isFinite, weight2 >= 0 else {
            throw ScalarModularError.invalidInput("Invalid Gaborish parameters")
        }
        let (lastRowOffset, rowOverflow) = (height - 1).multipliedReportingOverflow(by: stride)
        let (requiredInputCount, inputOverflow) = lastRowOffset.addingReportingOverflow(width)
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (workspaceBytes, byteOverflow) = pixelCount.multipliedReportingOverflow(by: MemoryLayout<Float>.size)
        guard !rowOverflow, !inputOverflow, !pixelOverflow, !byteOverflow,
              requiredInputCount <= input.count else {
            throw ScalarModularError.invalidInput("Gaborish buffer dimensions out of bounds")
        }

        try budget.reserveWorkspace(workspaceBytes)

        for y in 0..<height {
            if (y & 15) == 0 { try budget.checkpoint() }
            let rowBase = y * stride
            for x in 0..<width {
                guard input[rowBase + x].isFinite else {
                    throw ScalarModularError.invalidInput("Non-finite sample in Gaborish input")
                }
            }
        }

        var output = [Float](repeating: 0, count: pixelCount)
        let divisor = 1.0 + 4.0 * (weight1 + weight2)
        let w0 = 1.0 / divisor
        let w1 = weight1 / divisor
        let w2 = weight2 / divisor

        let workers = min(max(1, budget.maximumWorkers), height >= 32 ? min(8, height) : 1)
        try input.withUnsafeBufferPointer { srcBuf in
            try output.withUnsafeMutableBufferPointer { dstBuf in
                let srcAddr = Int(bitPattern: srcBuf.baseAddress!)
                let dstAddr = Int(bitPattern: dstBuf.baseAddress!)

                @Sendable
                func processRows(_ yStart: Int, _ yEnd: Int) throws {
                    let src = UnsafePointer<Float>(bitPattern: srcAddr)!
                    let dst = UnsafeMutablePointer<Float>(bitPattern: dstAddr)!
                    for y in yStart..<yEnd {
                        if ((y - yStart) & 15) == 0 { try budget.checkpoint() }
                        let ym1 = max(0, y - 1) * stride
                        let y0 = y * stride
                        let yp1 = min(height - 1, y + 1) * stride
                        let outRow = y * width
                        if width >= 3 {
                            do {
                                let xp1 = 1
                                let center = src[y0]
                                let cardinal = (src[ym1] + src[yp1]) + (src[y0] + src[y0 + xp1])
                                let diagonal = (src[ym1] + src[ym1 + xp1]) + (src[yp1] + src[yp1 + xp1])
                                dst[outRow] = center * w0 + cardinal * w1 + diagonal * w2
                            }
                            for x in 1..<(width - 1) {
                                let center = src[y0 + x]
                                let cardinal = (src[ym1 + x] + src[yp1 + x]) + (src[y0 + x - 1] + src[y0 + x + 1])
                                let diagonal = (src[ym1 + x - 1] + src[ym1 + x + 1]) + (src[yp1 + x - 1] + src[yp1 + x + 1])
                                dst[outRow + x] = center * w0 + cardinal * w1 + diagonal * w2
                            }
                            do {
                                let x = width - 1
                                let xm1 = x - 1
                                let center = src[y0 + x]
                                let cardinal = (src[ym1 + x] + src[yp1 + x]) + (src[y0 + xm1] + src[y0 + x])
                                let diagonal = (src[ym1 + xm1] + src[ym1 + x]) + (src[yp1 + xm1] + src[yp1 + x])
                                dst[outRow + x] = center * w0 + cardinal * w1 + diagonal * w2
                            }
                        } else {
                            for x in 0..<width {
                                let xm1 = max(0, x - 1)
                                let xp1 = min(width - 1, x + 1)
                                let center = src[y0 + x]
                                let cardinal = (src[ym1 + x] + src[yp1 + x]) + (src[y0 + xm1] + src[y0 + xp1])
                                let diagonal = (src[ym1 + xm1] + src[ym1 + xp1]) + (src[yp1 + xm1] + src[yp1 + xp1])
                                dst[outRow + x] = center * w0 + cardinal * w1 + diagonal * w2
                            }
                        }
                    }
                }

                if workers <= 1 {
                    try processRows(0, height)
                } else {
                    let errMutex = PackageMutex<(any Error)?>(nil)
                    let rowsPerWorker = (height + workers - 1) / workers
                    DispatchQueue.concurrentPerform(iterations: workers) { w in
                        let y0 = w * rowsPerWorker
                        let y1 = min(height, y0 + rowsPerWorker)
                        guard y0 < y1 else { return }
                        do {
                            try processRows(y0, y1)
                        } catch {
                            errMutex.withLock { if $0 == nil { $0 = error } }
                        }
                    }
                    if let err = errMutex.withLock({ $0 }) { throw err }
                }
            }
        }

        try budget.checkpoint()
        return output
    }
}

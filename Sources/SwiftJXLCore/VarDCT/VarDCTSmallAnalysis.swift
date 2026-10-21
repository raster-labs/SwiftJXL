// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Adapted from JXLSwift Codec/VarDCTEncoder.swift at
// 57e81cb9e2411d1efac435b429a306a031744c1e, Copyright (c) 2026 Raster-Lab.
// JPEG XL Project Authors retain BSD-3-Clause; see libjxl-LICENSE.txt.
import Foundation

/// Operation-owned forward plans for the predecessor's ten single-cell strategies.
/// Output is the codestream coefficient layout, including the unquantised cell DC.
package struct VarDCTSmallAnalysis: Sendable {
    private let budget: ScalarOperationBudget
    private let square4: ScaledDCT, square8: ScaledDCT, wide: ScaledDCT, tall: ScaledDCT
    package init(budget: ScalarOperationBudget) throws {
        var axes = ScaledDCT.AxisBank(direction: .forward, budget: budget)
        try self.init(budget: budget, axes: &axes)
    }
    package init(budget: ScalarOperationBudget, axes: inout ScaledDCT.AxisBank) throws {
        self.budget = budget
        square4 = try ScaledDCT(rows: 4, columns: 4, direction: .forward, budget: budget, axes: &axes)
        square8 = try ScaledDCT(rows: 8, columns: 8, direction: .forward, budget: budget, axes: &axes)
        wide = try ScaledDCT(rows: 4, columns: 8, direction: .forward, budget: budget, axes: &axes)
        tall = try ScaledDCT(rows: 8, columns: 4, direction: .forward, budget: budget, axes: &axes)
    }
    /// Exclusive reusable buffers: no array or pointer owner escapes, and
    /// non-copyability prevents unadmitted COW allocations between operations.
    package struct Workspace: ~Copyable {
        fileprivate let budget: ScalarOperationBudget
        fileprivate var storage: [Float]
        fileprivate var dct: ScaledDCT.Workspace
        package init(budget: ScalarOperationBudget) throws {
            // 276 floats plus 384 floats for 3-channel 4x8 and 4x4 subtransform
            // reuse within the existing 4096-byte admission envelope.
            try budget.reserveWorkspace(4096)
            dct = try ScaledDCT.Workspace(capacity: 64, budget: budget)
            self.budget = budget
            storage = [Float](repeating: 0, count: 660)
        }
        package func value(at index: Int) -> Float { storage[index] }
        package borrowing func withValues<Result>(_ body: (UnsafeBufferPointer<Float>) throws -> Result) rethrows -> Result {
            try storage.withUnsafeBufferPointer { buf in
                try body(UnsafeBufferPointer(rebasing: buf[0..<64]))
            }
        }
    }

    package func apply(_ pixels: [Float], identifier: Int) throws -> [Float] {
        try validate(pixels.count, identifier: identifier)
        guard pixels.allSatisfy(\.isFinite) else { throw VarDCTError.nonFiniteSample }
        var workspace = try Workspace(budget: budget)
        try pixels.withUnsafeBufferPointer { try apply($0, identifier: identifier, workspace: &workspace) }
        try budget.reserveWorkspace(64 * MemoryLayout<Float>.stride)
        return (0..<64).map { workspace.value(at: $0) }
    }
    private func validate(_ count: Int, identifier: Int) throws {
        try budget.checkpoint()
        guard ((0...3).contains(identifier) || (12...17).contains(identifier)), count == 64 else {
            throw VarDCTError.invalidTransform
        }
    }
    /// Synchronous input borrow. The caller retains its owner until return;
    /// each output can be read by value and is overwritten by the next call.
    package func apply(_ pixels: UnsafeBufferPointer<Float>, identifier: Int,
                       workspace: inout Workspace,
                       channelSlot: Int = 0, reuseSubtransforms: Bool = false) throws {
        try validate(pixels.count, identifier: identifier)
        guard workspace.budget === budget, let pBase = pixels.baseAddress else { throw VarDCTError.invalidTransform }
        for i in 0..<64 {
            if !pBase[i].isFinite { throw VarDCTError.nonFiniteSample }
        }
        // One uniquely owned allocation supplies disjoint typed slices.
        // The synchronous borrow establishes uniqueness once per transform;
        // no pointer escapes or enters a worker, and DCT scratch is separate.
        try workspace.storage.withUnsafeMutableBufferPointer { (buffer: inout UnsafeMutableBufferPointer<Float>) throws -> Void in
            try apply(pixels, identifier: identifier, buffer: buffer, dct: &workspace.dct,
                      channelSlot: channelSlot, reuseSubtransforms: reuseSubtransforms)
        }
    }
    private func apply(_ pixels: UnsafeBufferPointer<Float>, identifier: Int,
                       buffer: UnsafeMutableBufferPointer<Float>,
                       dct: inout ScaledDCT.Workspace,
                       channelSlot: Int, reuseSubtransforms: Bool) throws {
        try budget.checkpoint()
        let basePtr = buffer.baseAddress!
        let output = UnsafeMutableBufferPointer(start: basePtr, count: 64)
        let source = UnsafeMutableBufferPointer(start: basePtr + 64, count: 64)
        let patch16 = UnsafeMutableBufferPointer(start: basePtr + 128, count: 16)
        let patch32 = UnsafeMutableBufferPointer(start: basePtr + 144, count: 32)
        let dc = UnsafeMutableBufferPointer(start: basePtr + 176, count: 4)
        let corner = UnsafeMutableBufferPointer(start: basePtr + 180, count: 16)
        let square = UnsafeMutableBufferPointer(start: basePtr + 196, count: 16)
        let rectangle = UnsafeMutableBufferPointer(start: basePtr + 212, count: 32)
        let afv = UnsafeMutableBufferPointer(start: basePtr + 244, count: 16)
        let small = UnsafeMutableBufferPointer(start: basePtr + 260, count: 16)
        let cachedWideBase = basePtr + 276 + (channelSlot &* 64)
        let cachedSquare4Base = basePtr + 468 + (channelSlot &* 64)
        if identifier != 0 && identifier != 2 {
            for i in 0..<64 { output[i] = 0 }
        }
        if identifier == 0 {
            try square8.apply(pixels, workspace: &dct)
            dct.withValues { dctOut in
                let dPtr = dctOut.baseAddress!
                for y in 0..<8 {
                    for x in 0..<8 { output[y &* 8 &+ x] = dPtr[x &* 8 &+ y] }
                }
            }
        } else if identifier == 2 {
            for i in 0..<64 { output[i] = pixels[i] }
            for size in [8,4,2] {
                for i in 0..<64 { source[i] = output[i] }
                let half = size &>> 1
                for y in 0..<half { for x in 0..<half {
                    let a = source[y &* 16 &+ x &* 2], b = source[y &* 16 &+ x &* 2 &+ 1]
                    let c = source[(y &* 2 &+ 1) &* 8 &+ x &* 2], d = source[(y &* 2 &+ 1) &* 8 &+ x &* 2 &+ 1]
                    output[y &* 8 &+ x] = (a + b + c + d) * 0.25
                    output[y &* 8 &+ x &+ half] = (a + b - c - d) * 0.25
                    output[(y &+ half) &* 8 &+ x] = (a - b + c - d) * 0.25
                    output[(y &+ half) &* 8 &+ x &+ half] = (a - b - c + d) * 0.25
                } }
            }
        } else if identifier == 1 || identifier == 3 {
            for y in 0..<2 { for x in 0..<2 {
                try budget.checkpoint()
                if identifier == 1 {
                    let centre = pixels[(y &* 4 &+ 1) &* 8 &+ x &* 4 &+ 1]
                    var sum: Float = 0
                    for yy in 0..<4 { for xx in 0..<4 where xx != 0 || yy != 0 {
                        let at: Int = yy == 1 && xx == 1 ? y &* 32 &+ x &* 4 : (y &* 4 &+ yy) &* 8 &+ x &* 4 &+ xx
                        let residual = pixels[at] - centre
                        output[(y &+ yy &* 2) &* 8 &+ x &+ xx &* 2] = residual; sum += residual
                    } }
                    dc[y &* 2 &+ x] = centre + sum / 16
                } else {
                    for yy in 0..<4 { for xx in 0..<4 { patch16[yy &* 4 &+ xx] = pixels[(y &* 4 &+ yy) &* 8 &+ x &* 4 &+ xx] } }
                    try square4.apply(UnsafeBufferPointer(patch16), workspace: &dct)
                    let qOffset = (y &* 2 &+ x) &* 16
                    dct.withValues { dctOut in
                        let dPtr = dctOut.baseAddress!
                        dc[y &* 2 &+ x] = dPtr[0]
                        if reuseSubtransforms {
                            for i in 0..<16 { cachedSquare4Base[qOffset &+ i] = dPtr[i] }
                        }
                        for yy in 0..<4 { for xx in 0..<4 where xx != 0 || yy != 0 {
                            output[(y &+ yy &* 2) &* 8 &+ x &+ xx &* 2] = dPtr[xx &* 4 &+ yy]
                        } }
                    }
                }
            } }
            output[0] = (dc[0] + dc[1] + dc[2] + dc[3]) * 0.25
            output[1] = (dc[0] + dc[1] - dc[2] - dc[3]) * 0.25
            output[8] = (dc[0] - dc[1] + dc[2] - dc[3]) * 0.25
            output[9] = (dc[0] - dc[1] - dc[2] + dc[3]) * 0.25
        } else if identifier == 12 || identifier == 13 {
            let vertical = identifier == 12, rows = vertical ? 4 : 8, columns = vertical ? 8 : 4
            for half in 0..<2 {
                let rowOffset: Int = vertical ? half &* 4 : 0
                let columnOffset: Int = vertical ? 0 : half &* 4
                for y in 0..<rows { for x in 0..<columns {
                    patch32[y &* columns &+ x] = pixels[(y &+ rowOffset) &* 8 &+ x &+ columnOffset]
                } }
                try (vertical ? wide : tall).apply(UnsafeBufferPointer(patch32), workspace: &dct)
                dct.withValues { dctOut in
                    let dPtr = dctOut.baseAddress!
                    dc[half] = dPtr[0]
                    if vertical && reuseSubtransforms {
                        let wOffset = half &* 32
                        for i in 0..<32 { cachedWideBase[wOffset &+ i] = dPtr[i] }
                    }
                    for y in 0..<4 { for x in 0..<8 where x != 0 || y != 0 {
                        let index: Int = vertical ? y &* 8 &+ x : x &* 4 &+ y
                        output[(half &+ y &* 2) &* 8 &+ x] = dPtr[index]
                    } }
                }
            }
            output[0] = (dc[0] + dc[1]) * 0.5; output[8] = (dc[0] - dc[1]) * 0.5
        } else {
            let kind = identifier - 14, ax = kind & 1, ay = kind / 2
            if reuseSubtransforms {
                for y in 0..<4 {
                    let yy = ay == 1 ? 3 &- y : y
                    for x in 0..<4 {
                        let xx = ax == 1 ? 3 &- x : x
                        corner[yy &* 4 &+ xx] = pixels[(y &+ ay &* 4) &* 8 &+ x &+ ax &* 4]
                    }
                }
                try VarDCTAFV.forwardBasis(UnsafeBufferPointer(corner), into: afv, budget: budget)
                let sqPtr = cachedSquare4Base + ((ay &* 2 &+ (1 &- ax)) &* 16)
                let wdPtr = cachedWideBase + ((1 &- ay) &* 32)
                for y in 0..<4 { for x in 0..<8 {
                    if x < 4 && (x != 0 || y != 0) {
                        output[y &* 16 &+ x &* 2] = afv[y &* 4 &+ x]
                        output[y &* 16 &+ x &* 2 &+ 1] = sqPtr[x &* 4 &+ y]
                    }
                    if x != 0 || y != 0 { output[(y &* 2 &+ 1) &* 8 &+ x] = wdPtr[y &* 8 &+ x] }
                } }
                let dc0 = afv[0] * 0.25, dc1 = sqPtr[0], dc2 = wdPtr[0]
                output[0] = (dc0 + dc1 + 2 * dc2) * 0.25
                output[1] = (dc0 - dc1) * 0.5
                output[8] = (dc0 + dc1 - 2 * dc2) * 0.25
            } else {
                for y in 0..<4 { for x in 0..<8 {
                    if x < 4 {
                        let yy = ay == 1 ? 3 &- y : y, xx = ax == 1 ? 3 &- x : x
                        corner[yy &* 4 &+ xx] = pixels[(y &+ ay &* 4) &* 8 &+ x &+ ax &* 4]
                        square[y &* 4 &+ x] = pixels[(y &+ ay &* 4) &* 8 &+ x &+ (1 &- ax) &* 4]
                    }
                    rectangle[y &* 8 &+ x] = pixels[(y &+ (1 &- ay) &* 4) &* 8 &+ x]
                } }
                try VarDCTAFV.forwardBasis(UnsafeBufferPointer(corner), into: afv, budget: budget)
                try square4.apply(UnsafeBufferPointer(square), workspace: &dct)
                dct.withValues { dctOut in
                    let dPtr = dctOut.baseAddress!
                    for i in 0..<16 { small[i] = dPtr[i] }
                }
                try wide.apply(UnsafeBufferPointer(rectangle), workspace: &dct)
                dct.withValues { dctOut in
                    let dPtr = dctOut.baseAddress!
                    for y in 0..<4 { for x in 0..<8 {
                        if x < 4 && (x != 0 || y != 0) {
                            output[y &* 16 &+ x &* 2] = afv[y &* 4 &+ x]
                            output[y &* 16 &+ x &* 2 &+ 1] = small[x &* 4 &+ y]
                        }
                        if x != 0 || y != 0 { output[(y &* 2 &+ 1) &* 8 &+ x] = dPtr[y &* 8 &+ x] }
                    } }
                    let dc0 = afv[0] * 0.25, dc1 = small[0], dc2 = dPtr[0]
                    output[0] = (dc0 + dc1 + 2 * dc2) * 0.25
                    output[1] = (dc0 - dc1) * 0.5
                    output[8] = (dc0 + dc1 - 2 * dc2) * 0.25
                }
            }
        }
        for i in 0..<64 {
            if !output[i].isFinite { throw VarDCTError.nonFiniteSample }
        }
    }
}

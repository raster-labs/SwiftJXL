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
            // 276 floats plus conservative owner/capacity headroom. DCT scratch
            // is admitted independently and reused by all four transform plans.
            try budget.reserveWorkspace(4096)
            dct = try ScaledDCT.Workspace(capacity: 64, budget: budget)
            self.budget = budget
            storage = [Float](repeating: 0, count: 276)
        }
        package func value(at index: Int) -> Float { storage[index] }
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
                       workspace: inout Workspace) throws {
        try validate(pixels.count, identifier: identifier)
        guard workspace.budget === budget else { throw VarDCTError.invalidTransform }
        guard pixels.allSatisfy(\.isFinite) else { throw VarDCTError.nonFiniteSample }
        // One uniquely owned allocation supplies ten disjoint typed slices.
        // The synchronous borrow establishes uniqueness once per transform;
        // no pointer escapes or enters a worker, and DCT scratch is separate.
        try workspace.storage.withUnsafeMutableBufferPointer { buffer in
            let output = UnsafeMutableBufferPointer(rebasing: buffer[0..<64])
            let source = UnsafeMutableBufferPointer(rebasing: buffer[64..<128])
            let patch16 = UnsafeMutableBufferPointer(rebasing: buffer[128..<144])
            let patch32 = UnsafeMutableBufferPointer(rebasing: buffer[144..<176])
            let dc = UnsafeMutableBufferPointer(rebasing: buffer[176..<180])
            let corner = UnsafeMutableBufferPointer(rebasing: buffer[180..<196])
            let square = UnsafeMutableBufferPointer(rebasing: buffer[196..<212])
            let rectangle = UnsafeMutableBufferPointer(rebasing: buffer[212..<244])
            let afv = UnsafeMutableBufferPointer(rebasing: buffer[244..<260])
            let small = UnsafeMutableBufferPointer(rebasing: buffer[260..<276])
            for i in 0..<64 { output[i] = 0 }
            if identifier == 0 {
                try square8.apply(pixels, workspace: &workspace.dct)
                for y in 0..<8 { for x in 0..<8 { output[y * 8 + x] = workspace.dct.value(at: x * 8 + y) } }
            } else if identifier == 2 {
                for i in 0..<64 { output[i] = pixels[i] }
                for size in [8,4,2] {
                    for i in 0..<64 { source[i] = output[i] }
                    let half = size / 2
                    for y in 0..<half { for x in 0..<half {
                        let a = source[y * 16 + x * 2], b = source[y * 16 + x * 2 + 1]
                        let c = source[(y * 2 + 1) * 8 + x * 2], d = source[(y * 2 + 1) * 8 + x * 2 + 1]
                        output[y * 8 + x] = (a + b + c + d) * 0.25
                        output[y * 8 + x + half] = (a + b - c - d) * 0.25
                        output[(y + half) * 8 + x] = (a - b + c - d) * 0.25
                        output[(y + half) * 8 + x + half] = (a - b - c + d) * 0.25
                    } }
                }
            } else if identifier == 1 || identifier == 3 {
                for y in 0..<2 { for x in 0..<2 {
                    try budget.checkpoint()
                    if identifier == 1 {
                        let centre = pixels[(y * 4 + 1) * 8 + x * 4 + 1]
                        var sum: Float = 0
                        for yy in 0..<4 { for xx in 0..<4 where xx != 0 || yy != 0 {
                            let at = yy == 1 && xx == 1 ? y * 32 + x * 4 : (y * 4 + yy) * 8 + x * 4 + xx
                            let residual = pixels[at] - centre
                            output[(y + yy * 2) * 8 + x + xx * 2] = residual; sum += residual
                        } }
                        dc[y * 2 + x] = centre + sum / 16
                    } else {
                        for yy in 0..<4 { for xx in 0..<4 { patch16[yy * 4 + xx] = pixels[(y * 4 + yy) * 8 + x * 4 + xx] } }
                        try square4.apply(UnsafeBufferPointer(patch16), workspace: &workspace.dct); dc[y * 2 + x] = workspace.dct.value(at: 0)
                        for yy in 0..<4 { for xx in 0..<4 where xx != 0 || yy != 0 {
                            output[(y + yy * 2) * 8 + x + xx * 2] = workspace.dct.value(at: xx * 4 + yy)
                        } }
                    }
                } }
                output[0] = (dc[0] + dc[1] + dc[2] + dc[3]) * 0.25
                output[1] = (dc[0] + dc[1] - dc[2] - dc[3]) * 0.25
                output[8] = (dc[0] - dc[1] + dc[2] - dc[3]) * 0.25
                output[9] = (dc[0] - dc[1] - dc[2] + dc[3]) * 0.25
            } else if identifier == 12 || identifier == 13 {
                let vertical = identifier == 12, rows = vertical ? 4 : 8, columns = vertical ? 8 : 4
                for half in 0..<2 {
                    for y in 0..<rows { for x in 0..<columns {
                        patch32[y * columns + x] = pixels[(y + (vertical ? half * 4 : 0)) * 8 + x + (vertical ? 0 : half * 4)]
                    } }
                    try (vertical ? wide : tall).apply(UnsafeBufferPointer(patch32), workspace: &workspace.dct); dc[half] = workspace.dct.value(at: 0)
                    for y in 0..<4 { for x in 0..<8 where x != 0 || y != 0 {
                        output[(half + y * 2) * 8 + x] = workspace.dct.value(at: vertical ? y * 8 + x : x * 4 + y)
                    } }
                }
                output[0] = (dc[0] + dc[1]) * 0.5; output[8] = (dc[0] - dc[1]) * 0.5
            } else {
                let kind = identifier - 14, ax = kind & 1, ay = kind / 2
                for y in 0..<4 { for x in 0..<8 {
                    if x < 4 {
                        let yy = ay == 1 ? 3 - y : y, xx = ax == 1 ? 3 - x : x
                        corner[yy * 4 + xx] = pixels[(y + ay * 4) * 8 + x + ax * 4]
                        square[y * 4 + x] = pixels[(y + ay * 4) * 8 + x + (1 - ax) * 4]
                    }
                    rectangle[y * 8 + x] = pixels[(y + (1 - ay) * 4) * 8 + x]
                } }
                try VarDCTAFV.forwardBasis(UnsafeBufferPointer(corner), into: afv, budget: budget)
                try square4.apply(UnsafeBufferPointer(square), workspace: &workspace.dct)
                for i in 0..<16 { small[i] = workspace.dct.value(at: i) }
                try wide.apply(UnsafeBufferPointer(rectangle), workspace: &workspace.dct)
                for y in 0..<4 { for x in 0..<8 {
                    if x < 4 && (x != 0 || y != 0) {
                        output[y * 16 + x * 2] = afv[y * 4 + x]
                        output[y * 16 + x * 2 + 1] = small[x * 4 + y]
                    }
                    if x != 0 || y != 0 { output[(y * 2 + 1) * 8 + x] = workspace.dct.value(at: y * 8 + x) }
                } }
                let dc0 = afv[0] * 0.25, dc1 = small[0], dc2 = workspace.dct.value(at: 0)
                output[0] = (dc0 + dc1 + 2 * dc2) * 0.25
                output[1] = (dc0 - dc1) * 0.5
                output[8] = (dc0 + dc1 - 2 * dc2) * 0.25
            }
            guard output.allSatisfy(\.isFinite) else { throw VarDCTError.nonFiniteSample }
        }
        try budget.checkpoint()
    }
}

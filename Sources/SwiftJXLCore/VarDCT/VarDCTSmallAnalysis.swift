// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Raster Images Private Limited

import Foundation

/// Forward 8x8 and sub-8x8 VarDCT analysis transforms (`DCT8x8`, `Hornuss`, `DCT2x2`,
/// `DCT4x4`, `DCT4x8`, `DCT8x4`, and `AFV0..3`) per ISO/IEC 18181-1 §10.2.
package struct VarDCTSmallAnalysis: Sendable {
    package static let supportedIdentifiers: [Int] = [0, 1, 2, 3, 12, 13, 14, 15, 16, 17]

    package struct Workspace {
        let budget: ScalarOperationBudget
        var output: [Float]
        var dct8Scratch: ScaledDCT.Workspace
        var dct4x8Scratch: ScaledDCT.Workspace
        var dct8x4Scratch: ScaledDCT.Workspace
        var dct4x4Scratch: ScaledDCT.Workspace
        var patch32A: [Float]
        var patch32B: [Float]
        var patch16A: [Float]
        var patch16B: [Float]

        package init(budget: ScalarOperationBudget) throws {
            try budget.checkpoint()
            self.budget = budget
            self.dct8Scratch = try ScaledDCT.Workspace(capacity: 64, budget: budget)
            self.dct4x8Scratch = try ScaledDCT.Workspace(capacity: 32, budget: budget)
            self.dct8x4Scratch = try ScaledDCT.Workspace(capacity: 32, budget: budget)
            self.dct4x4Scratch = try ScaledDCT.Workspace(capacity: 16, budget: budget)
            try budget.reserveWorkspace((64 + 32 + 32 + 16 + 16) * MemoryLayout<Float>.stride)
            self.output = [Float](repeating: 0, count: 64)
            self.patch32A = [Float](repeating: 0, count: 32)
            self.patch32B = [Float](repeating: 0, count: 32)
            self.patch16A = [Float](repeating: 0, count: 16)
            self.patch16B = [Float](repeating: 0, count: 16)
        }

        package func value(at index: Int) -> Float {
            output[index]
        }
    }

    let budget: ScalarOperationBudget
    private let dct8: ScaledDCT
    private let dct4: ScaledDCT
    private let dct4x8: ScaledDCT
    private let dct8x4: ScaledDCT

    package init(budget: ScalarOperationBudget) throws {
        var axes = ScaledDCT.AxisBank(direction: .forward, budget: budget)
        try self.init(budget: budget, axes: &axes)
    }

    package init(budget: ScalarOperationBudget, axes: inout ScaledDCT.AxisBank) throws {
        try budget.checkpoint()
        self.budget = budget
        self.dct8 = try ScaledDCT(rows: 8, columns: 8, direction: .forward, budget: budget, axes: &axes)
        self.dct4 = try ScaledDCT(rows: 4, columns: 4, direction: .forward, budget: budget, axes: &axes)
        self.dct4x8 = try ScaledDCT(rows: 4, columns: 8, direction: .forward, budget: budget, axes: &axes)
        self.dct8x4 = try ScaledDCT(rows: 8, columns: 4, direction: .forward, budget: budget, axes: &axes)
    }

    package func apply(_ pixels: [Float], identifier: Int) throws -> [Float] {
        var workspace = try Workspace(budget: budget)
        try pixels.withUnsafeBufferPointer { buf in
            try apply(buf, identifier: identifier, workspace: &workspace)
        }
        return workspace.output
    }

    package func apply(
        _ pixels: UnsafeBufferPointer<Float>,
        identifier: Int,
        workspace: inout Workspace
    ) throws {
        try budget.checkpoint()
        guard workspace.budget === budget, pixels.count == 64 else {
            throw VarDCTError.invalidTransform
        }
        guard Self.supportedIdentifiers.contains(identifier) else {
            throw VarDCTError.invalidTransform
        }
        for i in 0..<64 {
            guard pixels[i].isFinite else {
                throw VarDCTError.nonFiniteSample
            }
        }

        switch identifier {
        case 0:
            try dct8.apply(pixels, workspace: &workspace.dct8Scratch)
            for y in 0..<8 {
                for x in 0..<8 {
                    workspace.output[x * 8 + y] = workspace.dct8Scratch.value(at: y * 8 + x)
                }
            }

        case 1:
            forwardHornuss(pixels, into: &workspace.output)

        case 2:
            forwardDCT2x2(pixels, into: &workspace.output)

        case 3:
            try forwardDCT4x4(pixels, workspace: &workspace)

        case 12:
            try forwardDCT4x8(pixels, workspace: &workspace)

        case 13:
            try forwardDCT8x4(pixels, workspace: &workspace)

        case 14, 15, 16, 17:
            try forwardAFV(pixels, kind: identifier - 14, workspace: &workspace)

        default:
            throw VarDCTError.invalidTransform
        }
    }

    @inline(__always)
    private static func dct2x2(_ p00: Double, _ p01: Double, _ p10: Double, _ p11: Double) -> (Double, Double, Double, Double) {
        let s0 = 0.5 * (p00 + p01)
        let d0 = 0.5 * (p00 - p01)
        let s1 = 0.5 * (p10 + p11)
        let d1 = 0.5 * (p10 - p11)
        return (
            0.5 * (s0 + s1),
            0.5 * (d0 + d1),
            0.5 * (s0 - s1),
            0.5 * (d0 - d1)
        )
    }

    private func forwardHornuss(_ pixels: UnsafeBufferPointer<Float>, into output: inout [Float]) {
        var dcs = (0.0, 0.0, 0.0, 0.0)
        for qy in 0..<2 {
            for qx in 0..<2 {
                let anchor = Double(pixels[(qy * 4 + 1) * 8 + (qx * 4 + 1)])
                var sum = 0.0
                for sy in 0..<4 {
                    for sx in 0..<4 {
                        let v = Double(pixels[(qy * 4 + sy) * 8 + (qx * 4 + sx)])
                        sum += v
                        if sy == 0 && sx == 0 {
                            output[(2 + qy) * 8 + (2 + qx)] = Float(v - anchor)
                        } else if !(sy == 1 && sx == 1) {
                            output[(sy * 2 + qy) * 8 + (sx * 2 + qx)] = Float(v - anchor)
                        }
                    }
                }
                let dc = sum * 0.0625
                switch qy * 2 + qx {
                case 0: dcs.0 = dc
                case 1: dcs.1 = dc
                case 2: dcs.2 = dc
                default: dcs.3 = dc
                }
            }
        }
        let (m00, m01, m10, m11) = Self.dct2x2(dcs.0, dcs.1, dcs.2, dcs.3)
        output[0] = Float(m00)
        output[8] = Float(m01)
        output[1] = Float(m10)
        output[9] = Float(m11)
    }

    private func forwardDCT2x2(_ pixels: UnsafeBufferPointer<Float>, into output: inout [Float]) {
        var dc2 = [Double](repeating: 0, count: 16)
        for by in 0..<4 {
            for bx in 0..<4 {
                let py = by * 2
                let px = bx * 2
                let (m00, m01, m10, m11) = Self.dct2x2(
                    Double(pixels[(py + 0) * 8 + (px + 0)]),
                    Double(pixels[(py + 0) * 8 + (px + 1)]),
                    Double(pixels[(py + 1) * 8 + (px + 0)]),
                    Double(pixels[(py + 1) * 8 + (px + 1)])
                )
                dc2[by * 4 + bx] = m00
                output[(4 + by) * 8 + bx] = Float(m01)
                output[by * 8 + (4 + bx)] = Float(m10)
                output[(4 + by) * 8 + (4 + bx)] = Float(m11)
            }
        }

        var quadDCs = (0.0, 0.0, 0.0, 0.0)
        for qy in 0..<2 {
            for qx in 0..<2 {
                let baseY = qy * 2
                let baseX = qx * 2
                let (m00, m01, m10, m11) = Self.dct2x2(
                    dc2[(baseY + 0) * 4 + (baseX + 0)],
                    dc2[(baseY + 0) * 4 + (baseX + 1)],
                    dc2[(baseY + 1) * 4 + (baseX + 0)],
                    dc2[(baseY + 1) * 4 + (baseX + 1)]
                )
                switch qy * 2 + qx {
                case 0: quadDCs.0 = m00
                case 1: quadDCs.1 = m00
                case 2: quadDCs.2 = m00
                default: quadDCs.3 = m00
                }
                output[(2 + qy) * 8 + qx] = Float(m01)
                output[qy * 8 + (2 + qx)] = Float(m10)
                output[(2 + qy) * 8 + (2 + qx)] = Float(m11)
            }
        }

        let (m00, m01, m10, m11) = Self.dct2x2(quadDCs.0, quadDCs.1, quadDCs.2, quadDCs.3)
        output[0] = Float(m00)
        output[8] = Float(m01)
        output[1] = Float(m10)
        output[9] = Float(m11)
    }

    private func forwardDCT4x4(_ pixels: UnsafeBufferPointer<Float>, workspace: inout Workspace) throws {
        var dcs = (0.0, 0.0, 0.0, 0.0)
        for qy in 0..<2 {
            for qx in 0..<2 {
                for sy in 0..<4 {
                    for sx in 0..<4 {
                        workspace.patch16A[sy * 4 + sx] = pixels[(qy * 4 + sy) * 8 + (qx * 4 + sx)]
                    }
                }
                try workspace.patch16A.withUnsafeBufferPointer { buf in
                    try dct4.apply(buf, workspace: &workspace.dct4x4Scratch)
                }
                let dc = Double(workspace.dct4x4Scratch.value(at: 0))
                switch qy * 2 + qx {
                case 0: dcs.0 = dc
                case 1: dcs.1 = dc
                case 2: dcs.2 = dc
                default: dcs.3 = dc
                }
                for fy in 0..<4 {
                    for fx in 0..<4 {
                        let ky = fx * 2 + qy
                        let kx = fy * 2 + qx
                        workspace.output[ky * 8 + kx] = workspace.dct4x4Scratch.value(at: fy * 4 + fx)
                    }
                }
            }
        }
        let (m00, m01, m10, m11) = Self.dct2x2(dcs.0, dcs.1, dcs.2, dcs.3)
        workspace.output[0] = Float(m00)
        workspace.output[8] = Float(m01)
        workspace.output[1] = Float(m10)
        workspace.output[9] = Float(m11)
    }

    private func forwardDCT4x8(_ pixels: UnsafeBufferPointer<Float>, workspace: inout Workspace) throws {
        for i in 0..<32 {
            workspace.patch32A[i] = pixels[i]
            workspace.patch32B[i] = pixels[32 + i]
        }
        try workspace.patch32A.withUnsafeBufferPointer { buf in
            try dct4x8.apply(buf, workspace: &workspace.dct4x8Scratch)
        }
        let topDC = Double(workspace.dct4x8Scratch.value(at: 0))
        for fy in 0..<4 {
            let kyTop = fy * 2
            for fx in 0..<8 {
                workspace.output[kyTop * 8 + fx] = workspace.dct4x8Scratch.value(at: fy * 8 + fx)
            }
        }

        try workspace.patch32B.withUnsafeBufferPointer { buf in
            try dct4x8.apply(buf, workspace: &workspace.dct4x8Scratch)
        }
        let bottomDC = Double(workspace.dct4x8Scratch.value(at: 0))
        for fy in 0..<4 {
            let kyBottom = fy * 2 + 1
            for fx in 0..<8 {
                workspace.output[kyBottom * 8 + fx] = workspace.dct4x8Scratch.value(at: fy * 8 + fx)
            }
        }

        workspace.output[0] = Float(0.5 * (topDC + bottomDC))
        workspace.output[8] = Float(0.5 * (topDC - bottomDC))
    }

    private func forwardDCT8x4(_ pixels: UnsafeBufferPointer<Float>, workspace: inout Workspace) throws {
        for y in 0..<8 {
            for x in 0..<4 {
                workspace.patch32A[y * 4 + x] = pixels[y * 8 + x]
                workspace.patch32B[y * 4 + x] = pixels[y * 8 + (4 + x)]
            }
        }
        try workspace.patch32A.withUnsafeBufferPointer { buf in
            try dct8x4.apply(buf, workspace: &workspace.dct8x4Scratch)
        }
        let leftDC = Double(workspace.dct8x4Scratch.value(at: 0))
        for fy in 0..<8 {
            for fx in 0..<4 {
                workspace.output[(fx * 2) * 8 + fy] = workspace.dct8x4Scratch.value(at: fy * 4 + fx)
            }
        }

        try workspace.patch32B.withUnsafeBufferPointer { buf in
            try dct8x4.apply(buf, workspace: &workspace.dct8x4Scratch)
        }
        let rightDC = Double(workspace.dct8x4Scratch.value(at: 0))
        for fy in 0..<8 {
            for fx in 0..<4 {
                workspace.output[(fx * 2 + 1) * 8 + fy] = workspace.dct8x4Scratch.value(at: fy * 4 + fx)
            }
        }

        workspace.output[0] = Float(0.5 * (leftDC + rightDC))
        workspace.output[8] = Float(0.5 * (leftDC - rightDC))
    }

    private func forwardAFV(_ pixels: UnsafeBufferPointer<Float>, kind: Int, workspace: inout Workspace) throws {
        let flipX = (kind & 1) != 0
        let flipY = (kind & 2) != 0
        let afvRowStart = flipY ? 4 : 0
        let dct4x8RowStart = flipY ? 0 : 4
        let afvColStart = flipX ? 4 : 0
        let dct4x4ColStart = flipX ? 0 : 4

        for sy in 0..<4 {
            let row4x8 = dct4x8RowStart + sy
            for x in 0..<8 {
                workspace.patch32A[sy * 8 + x] = pixels[row4x8 * 8 + x]
            }
            let rowAFV = afvRowStart + sy
            let dstAFVY = flipY ? (3 - sy) : sy
            for sx in 0..<4 {
                workspace.patch16A[sy * 4 + sx] = pixels[rowAFV * 8 + (dct4x4ColStart + sx)]
                let dstAFVX = flipX ? (3 - sx) : sx
                workspace.patch16B[dstAFVY * 4 + dstAFVX] = pixels[rowAFV * 8 + (afvColStart + sx)]
            }
        }

        try workspace.patch32A.withUnsafeBufferPointer { buf in
            try dct4x8.apply(buf, workspace: &workspace.dct4x8Scratch)
        }
        let dct4x8DC = Double(workspace.dct4x8Scratch.value(at: 0))
        for fy in 0..<4 {
            let ky = fy * 2 + 1
            for fx in 0..<8 {
                workspace.output[ky * 8 + fx] = workspace.dct4x8Scratch.value(at: fy * 8 + fx)
            }
        }

        try workspace.patch16A.withUnsafeBufferPointer { buf in
            try dct4.apply(buf, workspace: &workspace.dct4x4Scratch)
        }
        let dct4x4DC = Double(workspace.dct4x4Scratch.value(at: 0))
        for fy in 0..<4 {
            for fx in 0..<4 {
                let ky = fx * 2
                let kx = fy * 2 + 1
                workspace.output[ky * 8 + kx] = workspace.dct4x4Scratch.value(at: fy * 4 + fx)
            }
        }

        try workspace.patch16B.withUnsafeBufferPointer { src in
            try workspace.patch16A.withUnsafeMutableBufferPointer { dst in
                try VarDCTAFV.forwardBasis(src, into: dst, budget: budget)
            }
        }
        let afvDC = Double(workspace.patch16A[0])
        for sy in 0..<4 {
            for sx in 0..<4 {
                workspace.output[(sy * 2) * 8 + (sx * 2)] = workspace.patch16A[sy * 4 + sx]
            }
        }

        let afvHalfDC = 0.5 * (afvDC + dct4x4DC)
        workspace.output[1] = Float(0.5 * (afvDC - dct4x4DC))
        workspace.output[0] = Float(0.5 * (afvHalfDC + dct4x8DC))
        workspace.output[8] = Float(0.5 * (afvHalfDC - dct4x8DC))
    }
}

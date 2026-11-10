// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Raster Images Private Limited

import Foundation

/// Top-level clean-room VarDCT lossy pixel encoder.
package enum VarDCTPixelEncoder {
    package struct Coefficients: Sendable {
        package let width: Int
        package let height: Int
        package let blocksX: Int
        package let blocksY: Int
        package let bits: Int
        package let grayscale: Bool
        package let hasAlpha: Bool
        package let globalScale: Int
        package let quantAC: [Int32]
        package let strategies: [Int32]
        package let gaborish: Bool
        package let dcSmoothing: Bool
        package let dc: [[Int32]]
        package let ac: [[Int32]]
        package let transforms: [VarDCTStrategyMap.Transform]

        package init(
            width: Int,
            height: Int,
            blocksX: Int,
            blocksY: Int,
            bits: Int,
            grayscale: Bool,
            hasAlpha: Bool,
            globalScale: Int,
            quantAC: [Int32],
            strategies: [Int32],
            gaborish: Bool,
            dcSmoothing: Bool,
            dc: [[Int32]],
            ac: [[Int32]],
            transforms: [VarDCTStrategyMap.Transform]
        ) {
            self.width = width
            self.height = height
            self.blocksX = blocksX
            self.blocksY = blocksY
            self.bits = bits
            self.grayscale = grayscale
            self.hasAlpha = hasAlpha
            self.globalScale = globalScale
            self.quantAC = quantAC
            self.strategies = strategies
            self.gaborish = gaborish
            self.dcSmoothing = dcSmoothing
            self.dc = dc
            self.ac = ac
            self.transforms = transforms
        }
    }

    package static func encode(
        _ bytes: UnsafeRawBufferPointer,
        layouts: [ModularChannelLayout],
        bitsPerSample: Int,
        grayscale: Bool,
        alphaAssociated: Bool?,
        distance: Float,
        gaborish: Bool = false,
        adaptiveQuantisation: Bool = false,
        dcSmoothing: Bool = false,
        smallStrategySearch: Bool = false,
        largeStrategySearch: Bool = false,
        budget: ScalarOperationBudget
    ) throws -> Data {
        try budget.checkpoint()
        guard distance.isFinite, distance > 0 else {
            throw ScalarModularError.invalidInput("VarDCT distance must be positive and finite")
        }
        guard (8...16).contains(bitsPerSample), alphaAssociated != true else {
            throw ScalarModularError.unsupportedProfile
        }
        let hasAlpha = (alphaAssociated != nil)
        let expectedChannels = (grayscale ? 1 : 3) + (hasAlpha ? 1 : 0)
        guard let first = layouts.first, layouts.count == expectedChannels else {
            throw ScalarModularError.invalidInput("Invalid VarDCT channel layout count")
        }
        let width = first.width
        let height = first.height
        let pixelCount = try ScalarOperationBudget.product(width, height)
        guard width > 0, height > 0, width <= 4096, height <= 4096, pixelCount <= 4 * 1024 * 1024 else {
            throw ScalarModularError.unsupportedProfile
        }
        for layout in layouts {
            guard layout.width == width,
                  layout.height == height,
                  (8...16).contains(layout.storageBits),
                  bitsPerSample <= layout.storageBits else {
                throw ScalarModularError.invalidInput("Inconsistent VarDCT channel layout")
            }
            guard bytes.count >= layout.requiredBytes else {
                throw ScalarModularError.invalidInput("Source buffer shorter than layout requirement")
            }
        }

        let blocksX = (width + 7) / 8
        let blocksY = (height + 7) / 8
        let totalBlocks = try ScalarOperationBudget.product(blocksX, blocksY)
        let baseAdmission = 4 * 1024 * 1024
        let planeAdmission = try ScalarOperationBudget.product(pixelCount, 3 * MemoryLayout<Float>.stride)
        let blockAdmission = try ScalarOperationBudget.product(totalBlocks, 64 * 3 * MemoryLayout<Int32>.stride)
        try budget.reserveWorkspace(
            ScalarOperationBudget.sum(baseAdmission, ScalarOperationBudget.sum(planeAdmission, blockAdmission))
        )

        let maximum = (Int32(1) << bitsPerSample) - 1
        let source = VarDCTBorrowedSource(bytes: bytes, layouts: layouts, maximum: maximum)
        let eightBitTable = try bitsPerSample == 8
            ? VarDCTEncoderPreparation.EightBitConversion(grayscale: grayscale, budget: budget)
            : nil

        var planes = [
            [Float](repeating: 0, count: pixelCount),
            [Float](repeating: 0, count: pixelCount),
            [Float](repeating: 0, count: pixelCount)
        ]

        let invMax = 1.0 / Double(maximum)
        @inline(__always)
        func srgbToLinear(_ s: Int32) -> Double {
            let v = Double(s) * invMax
            return v <= 0.04045 ? (v / 12.92) : pow((v + 0.055) / 1.055, 2.4)
        }

        for y in 0..<height {
            if (y & 15) == 0 { try budget.checkpoint() }
            let rowOffset = y * width
            if grayscale {
                for x in 0..<width {
                    let sample = try source.sample(channel: 0, x: x, y: y)
                    let idx = rowOffset + x
                    if let table = eightBitTable {
                        let xyb = table.grayscale[Int(sample)]
                        planes[0][idx] = xyb.0
                        planes[1][idx] = xyb.1
                        planes[2][idx] = xyb.2
                    } else {
                        let lin = srgbToLinear(sample)
                        let xyb = try DefaultOpsin.forward((lin, lin, lin))
                        planes[0][idx] = Float(xyb.X)
                        planes[1][idx] = Float(xyb.Y)
                        planes[2][idx] = Float(xyb.B)
                    }
                }
            } else {
                for x in 0..<width {
                    let sr = try source.sample(channel: 0, x: x, y: y)
                    let sg = try source.sample(channel: 1, x: x, y: y)
                    let sb = try source.sample(channel: 2, x: x, y: y)
                    let r: Double
                    let g: Double
                    let b: Double
                    if let table = eightBitTable {
                        r = table.linear[Int(sr)]
                        g = table.linear[Int(sg)]
                        b = table.linear[Int(sb)]
                    } else {
                        r = srgbToLinear(sr)
                        g = srgbToLinear(sg)
                        b = srgbToLinear(sb)
                    }
                    let xyb = try DefaultOpsin.forward((r, g, b))
                    let idx = rowOffset + x
                    planes[0][idx] = Float(xyb.X)
                    planes[1][idx] = Float(xyb.Y)
                    planes[2][idx] = Float(xyb.B)
                }
            }
        }

        if gaborish {
            for c in 0..<3 {
                planes[c] = try VarDCTEncoderPreparation.inverseGaborish(
                    planes[c],
                    width: width,
                    height: height,
                    budget: budget
                )
            }
        }

        let globalScale = max(1, min(65535, Int((5111.0 / Double(distance)).rounded())))
        let writerLimit = budget.maximumCompressedBytes

        if largeStrategySearch {
            let result = try VarDCTHierarchicalAnalysis.analyse(
                planes,
                width: width,
                height: height,
                scale: globalScale,
                distance: distance,
                adaptiveQuantisation: adaptiveQuantisation,
                budget: budget
            )
            let coefficients = Coefficients(
                width: width,
                height: height,
                blocksX: blocksX,
                blocksY: blocksY,
                bits: bitsPerSample,
                grayscale: grayscale,
                hasAlpha: hasAlpha,
                globalScale: globalScale,
                quantAC: result.quantisation,
                strategies: result.strategies,
                gaborish: gaborish,
                dcSmoothing: dcSmoothing,
                dc: result.dc,
                ac: result.ac,
                transforms: result.transforms
            )
            return try ScalarEncodingWork.$current.withValue(.init(budget: budget, writerByteLimit: writerLimit)) {
                try VarDCTFrameWriter(
                    coefficients: coefficients,
                    source: source,
                    budget: budget,
                    limit: writerLimit
                ).write()
            }
        }

        // Single-cell (8x8) analysis path
        let smallPlan = try VarDCTSmallAnalysis(budget: budget)
        var smallWorkspace = try VarDCTSmallAnalysis.Workspace(budget: budget)
        let candidateIDs = smallStrategySearch ? VarDCTSmallAnalysis.supportedIdentifiers : [0]
        var weightTables: [Int: [Float]] = [:]
        for id in candidateIDs {
            weightTables[id] = try VarDCTQuantWeights.make(identifier: id, rows: 8, columns: 8, budget: budget)
        }
        let order = VarDCTFrameWriter.order
        let dcScales = [4096.0, 512.0, 256.0].map { Double(globalScale) * 17.0 * $0 / 65536.0 }
        let acScaleBase = Double(globalScale) / 65536.0

        var strategies = [Int32](repeating: 0, count: totalBlocks)
        var quantAC = [Int32](repeating: 5, count: totalBlocks)
        var transforms: [VarDCTStrategyMap.Transform] = []
        transforms.reserveCapacity(totalBlocks)
        var dc = [
            [Int32](repeating: 0, count: totalBlocks),
            [Int32](repeating: 0, count: totalBlocks),
            [Int32](repeating: 0, count: totalBlocks)
        ]
        var ac = [
            [Int32](repeating: 0, count: totalBlocks * 64),
            [Int32](repeating: 0, count: totalBlocks * 64),
            [Int32](repeating: 0, count: totalBlocks * 64)
        ]

        var patch = [[Float]](repeating: [Float](repeating: 0, count: 64), count: 3)
        var cflPatch = [[Float]](repeating: [Float](repeating: 0, count: 64), count: 3)

        for by in 0..<blocksY {
            try budget.checkpoint()
            for bx in 0..<blocksX {
                let block = by * blocksX + bx
                for c in 0..<3 {
                    let plane = planes[c]
                    for y in 0..<8 {
                        let sy = min(height - 1, by * 8 + y) * width
                        for x in 0..<8 {
                            let sx = min(width - 1, bx * 8 + x)
                            let v = plane[sy + sx]
                            patch[c][y * 8 + x] = v
                        }
                    }
                }
                cflPatch[0] = patch[0]
                cflPatch[1] = patch[1]
                for i in 0..<64 {
                    cflPatch[2][i] = patch[2][i] - patch[1][i]
                }

                let qf: Int32 = adaptiveQuantisation
                    ? try VarDCTEncoderPreparation.quantisation(patch, distance: distance)
                    : 5
                quantAC[block] = qf
                let qScale = acScaleBase * Double(qf)

                var bestID = 0
                var bestCost = Double.infinity
                var bestDC = (Int32(0), Int32(0), Int32(0))
                var bestAC = [[Int32]](repeating: [Int32](repeating: 0, count: 64), count: 3)

                for id in candidateIDs {
                    let weights = weightTables[id]!
                    var candDC = (Int32(0), Int32(0), Int32(0))
                    var candAC = [[Int32]](repeating: [Int32](repeating: 0, count: 64), count: 3)
                    var nonZeros = 0
                    var acEnergy = 0.0

                    for c in 0..<3 {
                        try cflPatch[c].withUnsafeBufferPointer { buf in
                            try smallPlan.apply(buf, identifier: id, workspace: &smallWorkspace)
                        }
                        let dcVal = Int32((Double(smallWorkspace.value(at: 0)) * dcScales[c]).rounded())
                        switch c {
                        case 0: candDC.0 = dcVal
                        case 1: candDC.1 = dcVal
                        default: candDC.2 = dcVal
                        }
                        let wBase = c * 64
                        for k in 1..<64 {
                            let pos = order[k]
                            let q = Int32((Double(smallWorkspace.value(at: pos)) * Double(weights[wBase + pos]) * qScale).rounded())
                            candAC[c][pos] = q
                            if q != 0 {
                                nonZeros += 1
                                acEnergy += abs(Double(q))
                            }
                        }
                    }

                    let penalty = (id == 0) ? 0.0 : 1.5
                    let cost = Double(nonZeros) * 3.5 + acEnergy * 0.25 + penalty
                    if cost + (id == 0 ? 0.0 : 0.5) < bestCost {
                        bestCost = cost
                        bestID = id
                        bestDC = candDC
                        bestAC = candAC
                    }
                }

                strategies[block] = Int32(bestID)
                dc[0][block] = bestDC.0
                dc[1][block] = bestDC.1
                dc[2][block] = bestDC.2
                let acOffset = block * 64
                for c in 0..<3 {
                    for i in 0..<64 {
                        ac[c][acOffset + i] = bestAC[c][i]
                    }
                }
                transforms.append(
                    VarDCTStrategyMap.Transform(
                        identifier: bestID,
                        x: bx,
                        y: by,
                        cellsX: 1,
                        cellsY: 1,
                        quantisation: UInt32(qf),
                        coefficientOffset: acOffset
                    )
                )
            }
        }

        let coefficients = Coefficients(
            width: width,
            height: height,
            blocksX: blocksX,
            blocksY: blocksY,
            bits: bitsPerSample,
            grayscale: grayscale,
            hasAlpha: hasAlpha,
            globalScale: globalScale,
            quantAC: quantAC,
            strategies: strategies,
            gaborish: gaborish,
            dcSmoothing: dcSmoothing,
            dc: dc,
            ac: ac,
            transforms: transforms
        )
        return try ScalarEncodingWork.$current.withValue(.init(budget: budget, writerByteLimit: writerLimit)) {
            try VarDCTFrameWriter(
                coefficients: coefficients,
                source: source,
                budget: budget,
                limit: writerLimit
            ).write()
        }
    }
}

/// Borrowed pixel buffer accessor that validates sample precision without copying source planes.
struct VarDCTBorrowedSource {
    let bytes: UnsafeRawBufferPointer
    let layouts: [ModularChannelLayout]
    let maximum: Int32

    @inline(__always)
    func sample(channel: Int, x: Int, y: Int) throws -> Int32 {
        let layout = layouts[channel]
        let offset = layout.offset + y * layout.rowBytes + x * layout.pixelStride
        let raw: Int32
        if layout.storageBits == 8 {
            raw = Int32(bytes[offset])
        } else if layout.littleEndian {
            raw = Int32(bytes[offset]) | (Int32(bytes[offset + 1]) << 8)
        } else {
            raw = (Int32(bytes[offset]) << 8) | Int32(bytes[offset + 1])
        }
        guard raw >= 0, raw <= maximum else {
            throw ScalarModularError.invalidInput("Source sample exceeds meaningful precision")
        }
        return raw
    }
}

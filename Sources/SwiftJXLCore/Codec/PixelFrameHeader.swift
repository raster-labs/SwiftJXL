// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Raster Images Private Limited

import Foundation

/// Shared codestream prelude parser for Modular and VarDCT pixel frames (ISO/IEC 18181-1 §§6.1, 9.1).
package struct PixelFrameHeader: Sendable {
    package let codestream: Data
    package let width: Int
    package let height: Int
    package let metadata: ImageMetadata
    package let reader: BitReader
    package let budget: ScalarOperationBudget
    package let maximumNestingDepth: Int

    package static func read(
        _ data: Data,
        budget: ScalarOperationBudget,
        maximumDimension: Int = 16384,
        maximumPixels: Int = 64 * 1024 * 1024,
        maximumNestingDepth: Int = 32
    ) throws -> Self {
        try budget.checkpoint()
        guard maximumDimension > 0,
              maximumPixels > 0,
              maximumNestingDepth > 0,
              data.count <= budget.maximumCompressedBytes else {
            throw ScalarModularError.resourceLimit
        }
        try budget.reserveWorkspace(
            ScalarOperationBudget.sum(
                ScalarOperationBudget.product(data.count, 6),
                ScalarOperationBudget.sum(256 * min(4096, data.count / 8), 16 * 1024)
            )
        )
        let codestream: Data
        switch try parseJXLContainer(data, checkpoint: budget.checkpoint) {
        case .naked:
            codestream = data
        case .iso(let boxes):
            guard boxes.allSatisfy({ ["ftyp", "jxll", "jxlc", "jxlp"].contains($0.type) }) else {
                throw ScalarModularError.unsupportedProfile
            }
            codestream = try extractCodestream(from: boxes, in: data, checkpoint: budget.checkpoint)
        }
        guard hasCodestreamSignature(codestream) else {
            throw ScalarModularError.invalidInput("Missing JPEG XL codestream signature")
        }
        try budget.checkpoint()
        let nesting = min(maximumNestingDepth, 32)
        var reader = BitReader(
            codestream,
            startingAt: 16,
            deadline: budget.deadline,
            maximumNestingDepth: nesting,
            budget: budget
        )
        let size = try SizeHeader.read(from: &reader)
        guard Int32(exactly: size.xsize) != nil,
              Int32(exactly: size.ysize) != nil else {
            throw ScalarModularError.resourceLimit
        }
        let width = Int(size.xsize)
        let height = Int(size.ysize)
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow,
              width > 0,
              height > 0,
              width <= maximumDimension,
              height <= maximumDimension,
              pixelCount <= maximumPixels else {
            throw ScalarModularError.resourceLimit
        }
        let metadata = try ImageMetadata.read(from: &reader)
        try budget.checkpoint()
        return Self(
            codestream: codestream,
            width: width,
            height: height,
            metadata: metadata,
            reader: reader,
            budget: budget,
            maximumNestingDepth: nesting
        )
    }
}

// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Shared preparation extracted from the Modular/VarDCT readers adapted from
// JXLSwift 57e81cb9e2411d1efac435b429a306a031744c1e, Codec/JXLDecoder.swift.
// Copyright (c) 2026 Raster-Lab. See Documentation/ThirdParty/libjxl-LICENSE.txt.
import Foundation

/// One bounded container/header parse for pixel-profile dispatch. This value
/// retains compressed owners and a reader positioned immediately after image
/// metadata, never decoded pixels or an escaped pointer. Copying the reader
/// shares immutable byte storage; the selected profile continues at its cursor.
/// ICC and frame fields are parsed only by that selected profile.
package struct PixelFrameHeader: Sendable {
    package let width: Int, height: Int
    package let metadata: ImageMetadata
    package let codestream: Data
    package let reader: BitReader
    package let budget: ScalarOperationBudget
    package let inputByteCount: Int, maximumNestingDepth: Int

    package static func read(_ data: Data, budget: ScalarOperationBudget,
                             maximumDimension: Int = 16384,
                             maximumPixels: Int = 64 * 1024 * 1024,
                             maximumNestingDepth: Int = 32) throws -> Self {
        try budget.checkpoint()
        guard maximumNestingDepth > 0, data.count <= budget.maximumCompressedBytes else {
            throw ScalarModularError.resourceLimit
        }
        // Container extraction and retained reader bytes. Modular preparation
        // separately admits its aggregate section-copy allowance; VarDCT
        // sections charge each opening. Dispatch never retries another parser.
        try budget.reserveWorkspace(ScalarOperationBudget.sum(ScalarOperationBudget.product(data.count, 3),
            ScalarOperationBudget.sum(256 * min(4096, data.count / 8), 64 * 1024)))
        let codestream: Data
        switch try parseJXLContainer(data, checkpoint: budget.checkpoint) {
        case .naked: codestream = data
        case .iso(let boxes):
            guard boxes.allSatisfy({ ["ftyp", "jxll", "jxlc", "jxlp"].contains($0.type) }) else {
                throw ScalarModularError.unsupportedProfile
            }
            codestream = try extractCodestream(from: boxes, in: data, checkpoint: budget.checkpoint)
        }
        guard hasCodestreamSignature(codestream) else {
            throw ScalarModularError.invalidInput("Missing codestream signature")
        }
        var reader = BitReader(codestream, startingAt: 16, deadline: budget.deadline,
            maximumNestingDepth: maximumNestingDepth, budget: budget)
        let size = try SizeHeader.read(from: &reader)
        let width = Int(size.xsize), height = Int(size.ysize)
        guard width > 0, height > 0, width <= min(maximumDimension, 16384),
              height <= min(maximumDimension, 16384),
              try ScalarOperationBudget.product(width, height) <= maximumPixels else {
            throw ScalarModularError.resourceLimit
        }
        let metadata = try ImageMetadata.read(from: &reader)
        try budget.checkpoint()
        return Self(width: width, height: height, metadata: metadata,
            codestream: codestream, reader: reader, budget: budget,
            inputByteCount: data.count, maximumNestingDepth: maximumNestingDepth)
    }
}

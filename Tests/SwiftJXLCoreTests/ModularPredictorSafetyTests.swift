// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import SwiftJXL
@testable import SwiftJXLCore

struct ModularPredictorSafetyTests {
    @Test func selectPredictorAcceptsEverySignedDifferenceMagnitude() {
        let values: [Int32] = [.min, .min + 1, -1, 0, 1, .max]
        for west in values { for north in values { for northwest in values {
            // Widen AFTER the specified wrapping subtraction. Int64 can
            // represent every Int32 magnitude, including 2^31.
            let pa = abs(Int64(west &- northwest)), pb = abs(Int64(north &- northwest))
            let expected = pa < pb ? north : west
            let neighbours = Neighbourhood(w: west, n: north, nw: northwest, ne: 0, ww: 0, nn: 0)
            #expect(applyLibjxlPredictor(raw: 4, neighbourhood: neighbours) == expected)
        } } }
    }

    // A complete 2x2 RGB codestream with an identity RCT: its presence selects
    // signed transform workspace. The malformed variant produces first-plane
    // values [Int32.min, 0, 0, ...]. At the final pixel W=N=0 and NW=Int32.min,
    // which previously trapped in Select before final precision validation.
    private func codestream(malformed: Bool) throws -> Data {
        var section = BitWriter()
        section.writeBit(true) // Default DC matrices.
        section.writeBit(true) // Global tree follows.
        let treeHeader = EntropySectionHeader(lz77: .disabled,
            contextMap: .trivial(numContexts: 6), usePrefixCode: true,
            logAlphaSize: 15, uintConfigs: [.raw4])
        let treeBook = MultiClusterCodebook(huffmanTables: [try PrefixCodeTable(lengths: Array(repeating: 4, count: 16))],
            ansCounts: [], alphabetSizes: [16])
        try treeHeader.write(to: &section, numContexts: 6)
        try treeBook.write(to: &section, header: treeHeader)
        let tree = ModularTree(nodes: [.init(property: -1, splitVal: 0, leftChildOrLeafId: 0,
            rightChild: 0, predictor: .zero, predictorOffset: 0, multiplier: 1, rawPredictor: 4)])
        let treeWriter = TokenStreamWriter(header: treeHeader, codebook: treeBook)
        try tree.encode { context, value in try treeWriter.writeToken(context: context, value: value, to: &section) }
        let pixelHeader = EntropySectionHeader(lz77: .disabled,
            contextMap: .trivial(numContexts: 1), usePrefixCode: true,
            logAlphaSize: 15, uintConfigs: [.raw4])
        let pixelBook = MultiClusterCodebook(huffmanTables: [try PrefixCodeTable(lengths: Array(repeating: 6, count: 64))],
            ansCounts: [], alphabetSizes: [64])
        try pixelHeader.write(to: &section, numContexts: 1)
        try pixelBook.write(to: &section, header: pixelHeader)
        try GroupHeader(transforms: [.init(id: .rct, rctType: 0)]).write(to: &section)
        let pixelWriter = TokenStreamWriter(header: pixelHeader, codebook: pixelBook)
        let firstPlane: [UInt32] = malformed ? [.max, .max, .max, 0] : [2, 1, 1, 0]
        for value in firstPlane + Array(repeating: UInt32(0), count: 8) {
            try pixelWriter.writeToken(context: 0, value: value, to: &section)
        }
        let prelude = try SpecModularEncoder.writeModularPrelude(width: 2, height: 2,
            bitsPerSample: 8, colorSpace: .rgb, extraChannels: [], animation: nil)
        return try prelude + SpecModularEncoder.writeModularFrameChunk(extraChannels: [],
            built: .init(groupSizeShift: 2, sections: [section.finishToData()]),
            isLast: true, animationFrame: .default, haveAnimation: false)
    }

    @Test(arguments: [false, true])
    func publicTransformedPlaneRejectsOutOfPrecisionSamplesWithoutTrapping(_ malformed: Bool) async throws {
        let data = try codestream(malformed: malformed), decoder = try Decoder()
        let info = try decoder.inspect(data)
        #expect(info.descriptor.width == 2 && info.descriptor.height == 2)
        let destination = try ImageDestination.allocate(descriptor: info.descriptor)
        if malformed {
            do { _ = try await decoder.decode(data); Issue.record("Invalid signed samples accepted") }
            catch let error as CodecError {
                #expect(error.category == .malformedInput)
                #expect(error.message == "Sample outside declared precision")
            }
            do { _ = try await decoder.decode(data, into: destination); Issue.record("Invalid caller samples accepted") }
            catch let error as CodecError {
                #expect(error.category == .malformedInput)
                #expect(error.message == "Sample outside declared precision")
            }
            #expect(throws: CodecError.self) { try destination.writeUInt16 { _, _ in 0 } }
        } else {
            let allocated = try await decoder.decode(data)
            let caller = try await decoder.decode(data, into: destination)
            var expected = Data(repeating: 0, count: 24)
            expected[0] = 1
            #expect(try allocated.image.storage.withUnsafeBytes { Data($0) } == expected)
            #expect(try caller.image.storage.withUnsafeBytes { Data($0) } == expected)
        }
    }
}

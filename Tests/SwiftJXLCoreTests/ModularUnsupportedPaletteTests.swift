// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import SwiftJXL
@testable import SwiftJXLCore

struct ModularUnsupportedPaletteTests {
    // Replace only the palette header in the independently generated single-
    // section fixture. Its original pixel payload is deliberately retained:
    // these cases must reject during preparation, before decoding that payload.
    private func headerProbe(delta: Bool, invalidRange: Bool) throws -> Data {
        let file = try #require(Bundle.module.url(forResource: "palette-rgb8",
            withExtension: "jxl", subdirectory: "Modular/Decoder"))
        let input = try Data(contentsOf: file)
        let cs: Data
        switch try parseJXLContainer(input) {
        case .naked: cs = input
        case .iso(let boxes): cs = try extractCodestream(from: boxes, in: input)
        }
        var reader = BitReader(cs, startingAt: 16)
        let size = try SizeHeader.read(from: &reader)
        let metadata = try SwiftJXLCore.ImageMetadata.read(from: &reader)
        #expect(try reader.readBit())
        try reader.expectZeroPadding()
        let frame = try FrameHeader.read(from: &reader, context: .init(xybEncoded: false,
            numExtraChannels: metadata.extraChannels.count))
        let dimension = 128 << Int(frame.groupSizeShift)
        try #require(Int(size.xsize) <= dimension && Int(size.ysize) <= dimension && frame.passes.numPasses == 1)
        let tocStart = reader.position
        let toc = try TOC.read(from: &reader, numEntries: 1)
        try #require(!toc.hasPermutation)
        let section = cs.subdata(in: (reader.position / 8)..<cs.count)
        var groupReader = BitReader(section)
        #expect(try groupReader.readBit())
        if try groupReader.readBit() {
            _ = try ScalarModularDecoder.readTreeAndCodebook(from: &groupReader,
                pixelCount: Int(size.xsize) * Int(size.ysize))
        }
        let headerStart = groupReader.position
        let header = try GroupHeader.read(from: &groupReader)
        let paletteIndex = try #require(header.transforms.firstIndex(where: { $0.id == .palette }))
        let original = header.transforms[paletteIndex]
        var transforms = header.transforms
        transforms[paletteIndex] = .init(id: .palette,
            beginC: invalidRange ? 100 : original.beginC, numC: original.numC,
            nbColors: original.nbColors, nbDeltas: delta ? 1 : 0,
            palettePredictor: delta ? 0 : 1)
        var payload = BitWriter(), prefix = BitReader(section)
        for _ in 0..<headerStart { payload.writeBit(try prefix.readBit()) }
        try GroupHeader(useGlobalTree: header.useGlobalTree, wpHeader: header.wpHeader,
            transforms: transforms).write(to: &payload)
        while !groupReader.isExhausted { payload.writeBit(try groupReader.readBit()) }
        let body = payload.finishToData()
        var output = BitWriter(), prelude = BitReader(cs)
        for _ in 0..<tocStart { output.writeBit(try prelude.readBit()) }
        try TOC(hasPermutation: false, entrySizes: [UInt32(body.count)], offsets: []).write(to: &output)
        return output.finishToData() + body
    }

    @Test(arguments: [false, true], [false, true])
    func publicPaletteErrorsDistinguishUnsupportedFromMalformed(_ delta: Bool, _ invalidRange: Bool) async throws {
        let data = try headerProbe(delta: delta, invalidRange: invalidRange)
        let decoder = try Decoder()
        let expected: CodecError.Category = invalidRange ? .malformedInput : .unsupportedFeature
        do { _ = try decoder.inspect(data); Issue.record("Unsupported palette inspection accepted") }
        catch let error as CodecError { #expect(error.category == expected) }
        do { _ = try await decoder.decode(data); Issue.record("Unsupported palette decode accepted") }
        catch let error as CodecError { #expect(error.category == expected) }
    }
}

// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

struct ModularFrameDecoderTests {
    private struct Fixture: Decodable {
        let name: String
        let width: Int, height: Int, channels: Int, bits: Int
    }
    private func budget(workspace: Int = 512 * 1024 * 1024) throws -> ScalarOperationBudget {
        try ScalarOperationBudget(retainedBytes: 4 * 1024 * 1024,
            maximumWorkspaceBytes: workspace, maximumMemoryBytes: 768 * 1024 * 1024,
            maximumDecodedBytes: 64 * 1024 * 1024, maximumCompressedBytes: 4 * 1024 * 1024,
            deadline: .now.advanced(by: .seconds(120)))
    }
    @Test(arguments: ["gray8", "grayalpha8", "rgb8", "rgba8", "rgb12", "rgba16",
                      "groups-rgb8", "groups-rgba16", "responsive-gray8", "responsive-rgb8",
                      "responsive-wide-rgb8", "responsive-small-rgb8", "grayalpha16", "palette-rgb8", "palette-rgb16"])
    func independentLibjxlSamples(_ name: String) throws {
        let manifest = try #require(Bundle.module.url(forResource: "manifest", withExtension: "json", subdirectory: "Modular/Decoder"))
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: manifest))
        let fixture = try #require(fixtures.first { $0.name == name })
        let file = try #require(Bundle.module.url(forResource: name, withExtension: "jxl", subdirectory: "Modular/Decoder"))
        let decoded = try ModularFrameDecoder.decode(Data(contentsOf: file), budget: budget())
        #expect(decoded.width == fixture.width && decoded.height == fixture.height)
        #expect(decoded.bitsPerSample == fixture.bits && decoded.image.channels.count == fixture.channels)
        #expect(decoded.grayscale == (fixture.channels < 3))
        #expect(decoded.alphaAssociated == (fixture.channels % 2 == 0 ? false : nil))
        let maximum = (1 << fixture.bits) - 1
        for c in 0..<fixture.channels {
            let expected = (0..<(fixture.width * fixture.height)).map {
                Int32(name.hasPrefix("palette-") ? (($0 % 4) * 47 + c * 31) & maximum
                    : ($0 * 71 + ($0 / fixture.width) * 37 + c * 113) & maximum)
            }
            #expect(decoded.image.channels[c].pixels == expected)
        }
    }

    @Test func malformedSectionAndInsufficientWorkspaceReject() throws {
        let file = try #require(Bundle.module.url(forResource: "rgb8", withExtension: "jxl", subdirectory: "Modular/Decoder"))
        let valid = try Data(contentsOf: file)
        #expect(throws: (any Error).self) { try ModularFrameDecoder.decode(valid.dropLast(), budget: budget()) }
        #expect(throws: (any Error).self) { try ModularFrameDecoder.decode(valid + Data([0]), budget: budget()) }
        #expect(throws: ScalarModularError.self) { try ModularFrameDecoder.decode(valid, budget: budget(workspace: 64)) }
        #expect(throws: ScalarModularError.self) { try ModularFrameDecoder.decode(valid, budget: budget(), maximumDimension: 1) }
    }

    @Test func aShortGroupCannotReadBytesFromTheFollowingGroup() throws {
        let file = try #require(Bundle.module.url(forResource: "groups-rgb8", withExtension: "jxl", subdirectory: "Modular/Decoder"))
        let encoded = try Data(contentsOf: file)
        let cs: Data
        switch try parseJXLContainer(encoded) {
        case .naked: cs = encoded
        case .iso(let boxes): cs = try extractCodestream(from: boxes, in: encoded)
        }
        var reader = BitReader(cs, startingAt: 16)
        let size = try SizeHeader.read(from: &reader)
        let metadata = try ImageMetadata.read(from: &reader)
        #expect(try reader.readBit())
        try reader.expectZeroPadding()
        let frame = try FrameHeader.read(from: &reader, context: .init(xybEncoded: false, numExtraChannels: metadata.extraChannels.count))
        let dim = 128 << Int(frame.groupSizeShift)
        let groups = ((Int(size.xsize) - 1) / dim + 1) * ((Int(size.ysize) - 1) / dim + 1)
        let dc = ((Int(size.xsize) - 1) / (dim * 8) + 1) * ((Int(size.ysize) - 1) / (dim * 8) + 1)
        let tocStart = reader.position
        let toc = try TOC.read(from: &reader, numEntries: TOC.numEntries(numGroups: groups, numDcGroups: dc, numPasses: 1))
        #expect(!toc.hasPermutation)
        let payload = cs.dropFirst(reader.position / 8)
        var sizes = toc.entrySizes
        let firstAC = 2 + dc
        #expect(sizes[firstAC] > 1)
        sizes[firstAC] -= 1
        sizes[firstAC + 1] += 1
        var writer = BitWriter(), prefix = BitReader(cs)
        for _ in 0..<tocStart { writer.writeBit(try prefix.readBit()) }
        try TOC(hasPermutation: false, entrySizes: sizes, offsets: []).write(to: &writer)
        let corrupted = writer.finishToData() + payload
        #expect(throws: (any Error).self) { try ModularFrameDecoder.decode(corrupted, budget: budget()) }
    }

    @Test func cancelledDecodeRejectsBeforeAllocatingWorkspace() async throws {
        let b = try budget()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: CancellationError.self) {
                try ModularFrameDecoder.decode(Data([0xFF, 0x0A]), budget: b)
            }
        }
        await task.value
        #expect(b.reservedWorkspaceBytes == 0)
    }
}

// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

struct ModularWireTests {
    private struct Vector: Decodable {
        struct Parameter: Decodable {
            let horizontal: Bool, inPlace: Bool
            let beginC: UInt32, numC: UInt32
        }
        let count: Int, payloadBits: Int
        let canonical: Bool
        let parameters: [Parameter]
        let bytes: [UInt8]
    }
    @Test func squeezeReadsIndependentWireVectorsAndWritesCanonicalBytes() throws {
        let url = try #require(Bundle.module.url(forResource: "squeeze-wire", withExtension: "json", subdirectory: "Modular"))
        let vectors = try JSONDecoder().decode([Vector].self, from: Data(contentsOf: url))
        for vector in vectors {
            var reader = BitReader(Data(vector.bytes))
            let transform = try ModularTransform.read(from: &reader)
            #expect(transform.id == .squeeze && transform.squeezes.count == vector.count)
            #expect(reader.position == vector.payloadBits)
            #expect(try reader.read(bits: 8) == 0xB7)
            for (actual, expected) in zip(transform.squeezes, vector.parameters) {
                #expect(actual.horizontal == expected.horizontal && actual.inPlace == expected.inPlace)
                #expect(actual.beginC == expected.beginC && actual.numC == expected.numC)
            }
            if vector.canonical {
                var writer = BitWriter()
                try transform.write(to: &writer)
                writer.write(bits: 8, value: 0xB7)
                #expect(writer.finishToData() == Data(vector.bytes))
            }
            let completeBytes = vector.payloadBits / 8
            for length in 0..<min(completeBytes, 8) {
                var truncated = BitReader(Data(vector.bytes.prefix(length)))
                #expect(throws: (any Error).self) { try ModularTransform.read(from: &truncated) }
            }
        }
    }

    @Test func transformMetadataRejectsAllocationBeyondBudget() throws {
        let budget = try ScalarOperationBudget(retainedBytes: 0, maximumWorkspaceBytes: 1,
            maximumMemoryBytes: 1024, maximumDecodedBytes: 1024, maximumCompressedBytes: 1024,
            deadline: .now.advanced(by: .seconds(30)))
        // Squeeze ID=2, count selector=1, value=1: one byte 00000110.
        // Resource failure must precede the absent parameter payload.
        var reader = BitReader(Data([0x06]), budget: budget)
        #expect(throws: ScalarModularError.self) { try ModularTransform.read(from: &reader) }
        #expect(budget.reservedWorkspaceBytes == 0)
    }

    @Test func rctCannotMixMetaAndNormalChannelsWithEqualDimensions() throws {
        let channel = try ModularChannel(width: 2, height: 2)
        let image = try ModularImage(channels: [channel, channel, channel], nbMetaChannels: 1)
        #expect(throws: ModularGeometryError.self) {
            try image.checkEqual(image.checkedRange(begin: 0, count: 3))
        }
    }
}

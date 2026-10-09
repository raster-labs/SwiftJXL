// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
@testable import SwiftJXLCore

struct BrotliDecoderTests {
    struct Manifest: Decodable {
        struct Entry: Decodable { let name: String; let raw: String; let bytes: Int }
        let cases: [Entry]
    }
    func fixture(_ name: String, _ ext: String, directory: String = "Brotli") throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: directory))
        return try Data(contentsOf: url)
    }
    @Test(arguments: ["text-q0-m0", "text-q1-m0", "text-q4-m0", "text-q6-m0", "text-q9-m0", "text-q11-m0", "text-q11-m1", "text-q11-m2", "unicode-q0-m0", "unicode-q1-m0", "unicode-q4-m0", "unicode-q6-m0", "unicode-q9-m0", "unicode-q11-m0", "binary-q0-m0", "binary-q1-m0", "binary-q4-m0", "binary-q6-m0", "binary-q9-m0", "binary-q11-m0", "runs-q0-m0", "runs-q1-m0", "runs-q4-m0", "runs-q6-m0", "runs-q9-m0", "runs-q11-m0", "runs-q11-m1", "runs-q11-m2", "mixed-q0-m0", "mixed-q1-m0", "mixed-q4-m0", "mixed-q6-m0", "mixed-q9-m0", "mixed-q11-m0", "streaming-postfix0-direct0", "streaming-postfix1-direct12", "streaming-postfix3-direct120", "unsorted-three-symbol", "all-block-types-mtf0", "all-block-types-mtf1", "all-short-distances"])
    func independentCompressedStreams(_ name: String) throws {
        let manifest = try JSONDecoder().decode(Manifest.self, from: fixture("decoder", "json"))
        let entry = try #require(manifest.cases.first { $0.name == name })
        let original = try fixture(entry.raw, "raw")
        var owner = Data([1, 2]); owner.append(try fixture(name, "br"))
        let decoded = try BrotliDecoder.decode(owner.dropFirst(2), expectedOutputSize: entry.bytes, policy: BrotliPolicy())
        #expect(decoded == original)
    }
    @Test(arguments: ["gray", "444", "422", "420", "440", "progressive", "restart", "metadata-tail", "fill-marker",
                      "progressive-edge", "progressive-restart", "progressive-422", "progressive-440",
                      "progressive-dc-refine", "sequential-multiscan", "zero-padding"])
    func independentJPEGReconstructionPayloads(_ name: String) throws {
        let source = try fixture(name, "jbrd", directory: "JBRD")
        let parsed = try JBRDBoxReader.read(source, policy: JBRDPolicy())
        let actual = try BrotliDecoder.decode(source[parsed.brotliRange], expectedOutputSize: parsed.expectedBrotliBytes, policy: BrotliPolicy())
        #expect(actual == (try fixture(name, "raw", directory: "JBRD")))
        let expected = try parsed.resolvingPayload(actual, policy: JBRDPolicy())
        let resolved = try JBRDBoxReader.readResolved(source, policy: JBRDPolicy())
        #expect(resolved.appData == expected.appData)
    }
    @Test func storedAndMetadataBlocks() throws {
        struct Framing: Decodable {
            struct Entry: Decodable { let stream: String; let output: String }
            let streams: [Entry]
        }
        let f = try JSONDecoder().decode(Framing.self, from: fixture("framing", "json"))
        let helper = BrotliFramingTests()
        for item in f.streams {
            let expected = try helper.hex(item.output)
            #expect(try BrotliDecoder.decode(helper.hex(item.stream), expectedOutputSize: expected.count, policy: BrotliPolicy()) == expected)
        }
    }
    @Test func allDictionaryTransformsMatchIndependentReference() throws {
        struct Record: Decodable {
            struct Vector: Decodable { let length: Int; let offset: Int; let transform: Int; let output: String }
            let vectors: [Vector]
        }
        let record = try JSONDecoder().decode(Record.self, from: fixture("transforms", "json"))
        #expect(record.vectors.count == 21 * 2 * 121)
        let helper = BrotliFramingTests()
        for v in record.vectors {
            let actual = try BrotliStaticDictionary.transformWord(wordOffset: v.offset, length: v.length, transformIdx: v.transform)
            #expect(Data(actual) == (try helper.hex(v.output)))
        }
        for (offset, length, transform) in [(-1, 4, 0), (122784, 4, 0), (0, 25, 0), (0, 4, 121)] {
            #expect(throws: BrotliError.self) {
                try BrotliStaticDictionary.transformWord(wordOffset: offset, length: length, transformIdx: transform)
            }
        }
    }
    @Test func rejectsTruncationTrailingAndWrongExpansion() throws {
        let stream = try fixture("unsorted-three-symbol", "br")
        for length in 0..<stream.count {
            #expect(throws: BrotliError.self) {
                try BrotliDecoder.decode(stream.prefix(length), expectedOutputSize: 3, policy: BrotliPolicy())
            }
        }
        for expected in [0, 2, 4] {
            #expect(throws: BrotliError.self) { try BrotliDecoder.decode(stream, expectedOutputSize: expected, policy: BrotliPolicy()) }
        }
        #expect(throws: BrotliError.self) { try BrotliDecoder.decode(stream + Data([0]), expectedOutputSize: 3, policy: BrotliPolicy()) }
        #expect(throws: BrotliError.self) { try BrotliDecoder.decode(Data([0x86]), expectedOutputSize: 0, policy: BrotliPolicy()) }
        for byte in stream.indices {
            for bit in 0..<8 {
                var changed = stream; changed[byte] ^= 1 << bit
                do {
                    let output = try BrotliDecoder.decode(changed, expectedOutputSize: 3, policy: BrotliPolicy())
                    #expect(output.count == 3)
                } catch is BrotliError { /* malformed inputs reject without traps */ }
            }
        }
    }
    @Test func malformedContextAndBlockTablesStayBounded() throws {
        let input = try fixture("all-block-types-mtf1", "br")
        for index in input.indices {
            for bit in 0..<8 {
                var changed = input; changed[index] ^= 1 << bit
                do {
                    let result = try BrotliDecoder.decodeWithStatistics(changed, expectedOutputSize: 9,
                        policy: BrotliPolicy(maximumMemoryBytes: 2 * 1024 * 1024, maximumCommands: 1024))
                    #expect(result.data.count == 9)
                    #expect(result.reservedBytes <= 2 * 1024 * 1024)
                } catch is BrotliError { /* malformed shape or admission limit */ }
            }
        }
    }
    @Test func resourceLimitsAndCancellation() async throws {
        let source = try fixture("runs-q11-m0", "br")
        #expect(throws: BrotliError.resourceLimit) { try BrotliDecoder.decode(source, expectedOutputSize: 32768, policy: BrotliPolicy(maximumOutputBytes: 32767)) }
        #expect(throws: BrotliError.resourceLimit) { try BrotliDecoder.decode(source, expectedOutputSize: 32768, policy: BrotliPolicy(maximumMemoryBytes: 1024 * 1024)) }
        #expect(throws: BrotliError.resourceLimit) { try BrotliDecoder.decode(source, expectedOutputSize: 32768, policy: BrotliPolicy(maximumCommands: 1)) }
        let many = try BrotliEncoder.encodeUncompressed(Data([1]), policy: BrotliPolicy())
        #expect(throws: BrotliError.resourceLimit) { try BrotliDecoder.decode(many, expectedOutputSize: 1, policy: BrotliPolicy(maximumMetaBlocks: 1)) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: CancellationError.self) { try BrotliDecoder.decode(source, expectedOutputSize: 32768, policy: BrotliPolicy()) }
        }
        await task.value
        let checks = Mutex(0)
        let policy = try BrotliPolicy(checkpoint: { try checks.withLock { n in n += 1; if n == 40 { throw CancellationError() } } })
        #expect(throws: CancellationError.self) { try BrotliDecoder.decode(source, expectedOutputSize: 32768, policy: policy) }
    }

    @Test func compressedFeatureCoverage() throws {
        let manifest = try JSONDecoder().decode(Manifest.self, from: fixture("decoder", "json"))
        var modes = 0, postfix = 0, shortCodes = 0, dictionary = 0, switches = 0
        var literalTypes = 0, commandTypes = 0, distanceTypes = 0, literalTrees = 0, distanceTrees = 0
        var metadata = 0, blocks = 0
        for entry in manifest.cases {
            let result = try BrotliDecoder.decodeWithStatistics(fixture(entry.name, "br"), expectedOutputSize: entry.bytes, policy: BrotliPolicy())
            #expect(result.reservedBytes <= 64 * 1024 * 1024)
            let s = result.statistics
            modes |= s.contextModeMask; postfix |= s.distancePostfixMask; shortCodes |= s.shortDistanceMask
            dictionary += s.dictionaryReferences; switches += s.blockSwitches
            literalTypes = max(literalTypes, s.maximumLiteralBlockTypes)
            commandTypes = max(commandTypes, s.maximumCommandBlockTypes)
            distanceTypes = max(distanceTypes, s.maximumDistanceBlockTypes)
            literalTrees = max(literalTrees, s.maximumLiteralTrees)
            distanceTrees = max(distanceTrees, s.maximumDistanceTrees)
            metadata += s.metadataMetaBlocks; blocks = max(blocks, s.compressedMetaBlocks)
        }
        print("BROTLI_COVERAGE modes=\(modes) postfix=\(postfix) short=\(shortCodes) dictionary=\(dictionary) switches=\(switches) types=\(literalTypes),\(commandTypes),\(distanceTypes) trees=\(literalTrees),\(distanceTrees) metadata=\(metadata) blocks=\(blocks)")
        #expect(dictionary > 0)
        #expect(modes == 15)
        #expect(shortCodes == 65535)
        #expect(literalTypes > 1 && commandTypes > 1 && distanceTypes > 1)
        #expect(literalTrees > 1 && distanceTrees > 1 && switches > 0)
        #expect(metadata > 0 && blocks > 1)
        #expect(postfix & 0b1011 == 0b1011)
    }
}

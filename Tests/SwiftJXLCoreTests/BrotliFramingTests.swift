// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
@testable import SwiftJXLCore

struct BrotliFramingTests {
    struct Fixtures: Decodable {
        struct Stream: Decodable {
            let name: String; let stream: String; let window: Int; let output: String
            let kinds: [String]; let lengths: [Int]
        }
        struct Boundary: Decodable { let count: Int; let prefix: String; let suffix: String }
        let streams: [Stream]
        let encoderBoundaries: [Boundary]
    }
    func hex(_ value: String) throws -> Data {
        let chars = Array(value)
        return try Data(stride(from: 0, to: chars.count, by: 2).map {
            try #require(UInt8(String(chars[$0...($0 + 1)]), radix: 16))
        })
    }
    func fixtures() throws -> Fixtures {
        let url = try #require(Bundle.module.url(forResource: "framing", withExtension: "json", subdirectory: "Brotli"))
        return try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
    }
    func reader(_ bytes: Data, policy: BrotliPolicy? = nil) throws -> BrotliReader {
        var budget = BrotliBudget(policy: try policy ?? BrotliPolicy())
        return try BrotliReader(bytes, budget: &budget)
    }

    @Test func independentlyAcceptedFramingAndMetadata() throws {
        for item in try fixtures().streams {
            var input = Data([99, 98]); input.append(try hex(item.stream))
            var r = try reader(input.dropFirst(2)) // non-zero Data start index
            #expect(try BrotliMetaBlockReader.readWindowBits(from: &r) == item.window)
            var output = Data()
            for (index, expectedKind) in item.kinds.enumerated() {
                let h = try BrotliMetaBlockReader.read(from: &r)
                #expect(String(describing: h.kind) == expectedKind)
                #expect(h.length == item.lengths[index])
                switch h.kind {
                case .metadata: try r.skipAlignedBytes(h.length)
                case .uncompressed:
                    for _ in 0..<h.length { output.append(UInt8(try r.read(bits: 8))) }
                case .empty: break
                case .compressed: Issue.record("Unexpected compressed fixture")
                }
                #expect(h.isLast == (index == item.kinds.count - 1))
            }
            try r.requireEnd()
            #expect(output == (try hex(item.output)))
        }
    }

    @Test func encoderMatchesIndependentBoundaryStreams() throws {
        for entry in try fixtures().encoderBoundaries {
            let payload = Data(repeating: 165, count: entry.count)
            var expected = try hex(entry.prefix)
            expected.append(payload); expected.append(try hex(entry.suffix))
            let encoded = try BrotliEncoder.encodeUncompressed(payload, policy: BrotliPolicy())
            #expect(encoded == expected)
        }
    }

    @Test func completeVariableLengthCountRange() throws {
        for count in 1...256 {
            var w = BitWriter()
            w.writeBit(count != 1)
            if count > 1 {
                let bits = (0...7).last(where: { (1 << $0) + 1 <= count }) ?? 0
                w.write(bits: 3, value: UInt32(bits))
                w.write(bits: bits, value: UInt32(count - (1 << bits) - 1))
            }
            var r = try reader(w.finishToData())
            #expect(try r.readVarLenU8() == count)
        }
    }

    @Test func malformedHeadersAndTruncation() throws {
        var reserved = try reader(Data([0x11]))
        #expect(throws: BrotliError.self) { try BrotliMetaBlockReader.readWindowBits(from: &reserved) }
        // Metadata reserved flag, nonminimal metadata length, metadata fill,
        // nonminimal MLEN, raw-block fill, empty-stream fill, trailing byte.
        for fields: [(Int, UInt32)] in [
            [(1,0),(1,0),(2,3),(1,1)],
            [(1,0),(1,0),(2,3),(1,0),(2,2),(16,1)],
            [(1,0),(1,0),(2,3),(1,0),(2,0),(1,1)],
            [(1,0),(1,0),(2,1),(20,1),(1,1)],
            [(1,0),(1,0),(2,0),(16,0),(1,1),(3,1)],
            [(1,0),(2,3),(5,1)],
            [(1,0),(2,3),(5,0),(8,0)]
        ] {
            var w = BitWriter()
            for (width,value) in fields { w.write(bits: width, value: value) }
            var r = try reader(w.finishToData())
            _ = try BrotliMetaBlockReader.readWindowBits(from: &r)
            #expect(throws: BrotliError.self) {
                let h = try BrotliMetaBlockReader.read(from: &r)
                if h.kind == .empty { try r.requireEnd() }
            }
        }
        let source = try fixtures().streams.first { $0.name == "metadata-257-True" }
        let data = try hex(#require(source).stream)
        for count in 0..<data.count {
            #expect(throws: BrotliError.self) {
                var r = try reader(data.prefix(count))
                _ = try BrotliMetaBlockReader.readWindowBits(from: &r)
                let h = try BrotliMetaBlockReader.read(from: &r)
                try r.skipAlignedBytes(h.length)
            }
        }
    }

    @Test func inputOutputMemoryAndDeadlineAdmission() throws {
        let input = Data(repeating: 1, count: 32)
        #expect(throws: BrotliError.resourceLimit) { try reader(input, policy: BrotliPolicy(maximumInputBytes: 31)) }
        #expect(throws: BrotliError.resourceLimit) { try reader(input, policy: BrotliPolicy(maximumMemoryBytes: 31)) }
        #expect(throws: BrotliError.resourceLimit) {
            try BrotliEncoder.encodeUncompressed(input, policy: BrotliPolicy(maximumOutputBytes: 35))
        }
        #expect(throws: BrotliError.resourceLimit) {
            try BrotliEncoder.encodeUncompressed(input, policy: BrotliPolicy(maximumMemoryBytes: 100))
        }
        #expect(throws: BrotliError.resourceLimit) {
            try BrotliEncoder.encodeUncompressed(input, policy: BrotliPolicy(deadline: .now.advanced(by: .seconds(-1))))
        }
        #expect(throws: BrotliError.resourceLimit) { try BrotliPolicy(maximumInputBytes: Int.max) }
        #expect(throws: BrotliError.resourceLimit) { try BrotliPolicy(maximumOutputBytes: -1) }
    }

    @Test func cancellationAndBoundedWork() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: CancellationError.self) {
                try BrotliEncoder.encodeUncompressed(Data([1]), policy: BrotliPolicy())
            }
        }
        await task.value
        let counter = Mutex(0)
        let policy = try BrotliPolicy(checkpoint: {
            try counter.withLock { value in
                value += 1
                if value == 6 { throw CancellationError() }
            }
        })
        #expect(throws: CancellationError.self) {
            try BrotliEncoder.encodeUncompressed(Data(repeating: 1, count: 16384), policy: policy)
        }
        let checks = Mutex(0)
        var r = try reader(Data(repeating: 0, count: 1024), policy: BrotliPolicy(checkpoint: { checks.withLock { $0 += 1 } }))
        for _ in 0..<4096 { _ = try r.readBit() }
        #expect(checks.withLock { $0 } == 5) // admission + four bounded read checkpoints
    }
}

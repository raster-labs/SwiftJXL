// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
@testable import SwiftJXLCore

@Suite(.serialized)
struct ICCStreamTests {
    @Test(arguments: ["srgb", "gray-gamma22"])
    func nativeProfileRoundTripAndTruncation(_ name: String) throws {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "icc", subdirectory: "JPEGBridge"))
        let profile = try Data(contentsOf: url)
        var writer = BitWriter()
        try ICCStream.write(profile, to: &writer, maximumBytes: profile.count, checkpoint: {})
        let stream = writer.finishToData()
        var reader = BitReader(stream)
        #expect(try ICCStream.decode(from: &reader, maximumBytes: profile.count, checkpoint: {}) == profile)
        try reader.expectZeroPadding(); #expect(reader.bitsRemaining == 0)
        for count in 0..<stream.count {
            var truncated = BitReader(Data(stream.prefix(count)))
            #expect(throws: (any Error).self) { try ICCStream.decode(from: &truncated, maximumBytes: profile.count, checkpoint: {}) }
        }
        var limited = BitReader(stream)
        #expect(throws: JPEGEntropyError.resourceLimit) { try ICCStream.decode(from: &limited, maximumBytes: profile.count - 1, checkpoint: {}) }
        var cancelled = BitReader(stream)
        #expect(throws: CancellationError.self) { try ICCStream.decode(from: &cancelled, maximumBytes: profile.count, checkpoint: { throw CancellationError() }) }
    }
    @Test func malformedCommandsAndOutputBoundsDoNotTrap() throws {
        let malformed: [[UInt8]] = [[], [128], Array(repeating: 255, count: 10), [255,255,255,255,15,0], [1,10,0], [1,0], [0,1,0]]
        for bytes in malformed {
            #expect(throws: (any Error).self) { try ICCStream.unpredict(bytes, maximumBytes: 512, checkpoint: {}) }
        }
        // Deterministic short mutations exercise command/data separation and
        // declared-size admission; accepted results must stay within the cap.
        var state: UInt64 = 0x4a584c
        for size in 0..<256 {
            var bytes: [UInt8] = []
            for _ in 0..<size {
                state = state &* 6364136223846793005 &+ 1; bytes.append(UInt8(truncatingIfNeeded: state >> 32))
            }
            do { #expect(try ICCStream.unpredict(bytes, maximumBytes: 512, checkpoint: {}).count <= 512) }
            catch { }
        }
    }
    @Test func standardCommandFamiliesAndPredictors() throws {
        func variable(_ n: Int) -> [UInt8] {
            var n = n, bytes: [UInt8] = []
            repeat { let b = UInt8(n & 127); n >>= 7; bytes.append(b | (n == 0 ? 0 : 128)) } while n != 0
            return bytes
        }
        func decode(_ commands: [UInt8], _ payload: [UInt8], tailSize: Int) throws -> Data {
            let bytes = variable(128 + tailSize) + variable(commands.count) + commands + [UInt8](repeating: 0, count: 128) + payload
            return try ICCStream.unpredict(bytes, maximumBytes: 1024, checkpoint: {})
        }
        #expect(try decode([0,2,7], [1,2,3,4,5,6,7], tailSize: 7).suffix(7) == Data([1,5,2,6,3,7,4]))
        #expect(try decode([0,3,7], [1,2,3,4,5,6,7], tailSize: 7).suffix(7) == Data([1,3,5,7,2,4,6]))
        for width in [1,2,4] {
            func fields(_ values: [Int]) -> [UInt8] {
                values.flatMap { value in (0..<width).map { UInt8(truncatingIfNeeded: value >> ((width - 1 - $0) * 8)) } }
            }
            for (order, expected) in [[16,16,16,16], [23,30,37,44], [25,36,49,64]].enumerated() {
                let seed = fields([1,4,9,16]), flags = UInt8(width - 1 + order * 4)
                let result = try decode([0,1,UInt8(seed.count),4,flags,UInt8(seed.count)],
                    seed + [UInt8](repeating: 0, count: seed.count), tailSize: seed.count * 2)
                #expect(result.suffix(seed.count) == Data(fields(expected)))
            }
        }
        let xyz = Array(0..<12).map(UInt8.init)
        #expect(try decode([0,10], xyz, tailSize: 20).suffix(20) == Data("XYZ ".utf8) + Data([0,0,0,0]) + Data(xyz))
        for (index, type) in ["XYZ ","desc","text","mluc","para","curv","sf32","gbd "].enumerated() {
            #expect(try decode([0,UInt8(16 + index)], [], tailSize: 8).suffix(8) == Data(type.utf8) + Data([0,0,0,0]))
        }
        let trc = try decode([4,0x82,8,0], [], tailSize: 40)
        var expected = Data([0,0,0,3])
        for tag in ["rTRC","gTRC","bTRC"] { expected.append(Data(tag.utf8) + Data([0,0,0,164,0,0,0,8])) }
        #expect(trc.suffix(40) == expected)
    }

}

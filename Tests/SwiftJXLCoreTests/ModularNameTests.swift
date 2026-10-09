// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

struct ModularNameTests {
    // A and @ differ only in bit zero: find the byte-alignment-independent
    // name position, then replace that UTF-8 byte with an invalid leading byte.
    private func invalidName(_ encode: (String) throws -> Data) throws -> Data {
        var a = try encode("A")
        let b = try encode("@")
        let changes = a.indices.filter { a[$0] != b[$0] }
        let index = try #require(changes.first)
        #expect(changes.count == 1)
        let bit = (a[index] ^ b[index]).trailingZeroBitCount
        for i in 0..<8 {
            let position = index * 8 + bit + i
            a[position / 8] |= UInt8(1 << (position % 8))
        }
        return a
    }
    @Test func malformedExtraChannelNameCannotBecomeUnnamedAlpha() throws {
        let bytes = try invalidName { name in
            var writer = BitWriter()
            try ExtraChannelInfo(type: .alpha, bitDepth: .standard, dimShift: 0, name: name).write(to: &writer)
            return writer.finishToData()
        }
        var reader = BitReader(bytes)
        #expect(throws: BitstreamError.self) { try ExtraChannelInfo.read(from: &reader) }
    }
    @Test func malformedFrameNameCannotBecomeUnnamedFrame() throws {
        let bytes = try invalidName { name in
            var writer = BitWriter()
            try FrameHeader(allDefault: false, encoding: .modular, colorTransform: .none, name: name).write(to: &writer, context: .default)
            let data = writer.finishToData()
            var valid = BitReader(data)
            #expect(try FrameHeader.read(from: &valid, context: .default).name == name)
            return data
        }
        var reader = BitReader(bytes)
        do {
            _ = try FrameHeader.read(from: &reader, context: .default)
            Issue.record("Invalid frame name accepted")
        } catch FrameHeaderError.bitstream(.malformedValue(let message)) {
            #expect(message == "Invalid frame name UTF-8")
        }

    }
}

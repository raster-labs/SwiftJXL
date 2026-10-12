// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

struct ModularAddressTests {
    @Test(arguments: [1, 2, 3, 511, 512, 513], [0, 1, 2])
    func packedPaddedAndCroppedAddressesPreserveSamplesAndGuards(_ width: Int, _ mode: Int) throws {
        for bits in [8, 16] { for little in [false, true] {
            let sampleBytes = bits / 8, stride = sampleBytes * 4, height = 3
            let layout: ModularChannelLayout
            if mode == 2 {
                let parent = try ModularChannelLayout(width: width + 2, height: height + 2,
                    offset: 8, rowBytes: (width + 2) * stride + 8, pixelStride: stride,
                    storageBits: bits, littleEndian: little)
                layout = try parent.rectangle(x: 1, y: 1, width: width, height: height)
            } else {
                layout = try ModularChannelLayout(width: width, height: height, offset: 8,
                    rowBytes: width * stride + (mode == 0 ? 0 : 8), pixelStride: stride,
                    storageBits: bits, littleEndian: little)
            }
            #expect(layout.packedRows == (mode == 0))
            var actual = [UInt8](repeating: 0xA5, count: layout.requiredBytes + 8)
            var expected = actual
            let maximum = (1 << bits) - 1
            for index in 0..<(width * height) {
                // Independent quotient/remainder reference, including all
                // row transitions and final samples of odd/group widths.
                let offset = layout.offset + (index / width) * layout.rowBytes + (index % width) * stride
                #expect(layout.byteOffset(for: index) == offset)
                let value = (index * 71 + 37) & maximum
                expected[offset] = UInt8(truncatingIfNeeded: bits == 8 || little ? value : value >> 8)
                if bits == 16 { expected[offset + 1] = UInt8(truncatingIfNeeded: little ? value >> 8 : value) }
            }
            actual.withUnsafeMutableBytes { bytes in
                var channel = BorrowedModularChannel(bytes: bytes, layout: layout)
                for index in 0..<channel.count { channel[index] = Int32((index * 71 + 37) & maximum) }
                for index in (0..<channel.count).reversed() {
                    #expect(channel[index] == Int32((index * 71 + 37) & maximum))
                }
            }
            #expect(actual == expected)
        } }
    }

    @Test func rectangleEligibilityAndUnusedRowOverflowDoNotChangeAdmission() throws {
        let parent = try ModularChannelLayout(width: 513, height: 4, offset: 8,
            rowBytes: 513 * 2, pixelStride: 2, storageBits: 16, littleEndian: true)
        let fullWidth = try parent.rectangle(x: 0, y: 1, width: 513, height: 2)
        let cropped = try parent.rectangle(x: 1, y: 1, width: 512, height: 2)
        #expect(fullWidth.packedRows && !cropped.packedRows)
        #expect(fullWidth.byteOffset(for: 513) == 8 + 2 * parent.rowBytes)
        #expect(cropped.byteOffset(for: 512) == 10 + 2 * parent.rowBytes)
        // No allocation: only one row is addressed, so requiredBytes fits even
        // though width*pixelStride does not. Both valid sample offsets fit.
        let largeStride = try ModularChannelLayout(width: 2, height: 1, offset: 0,
            rowBytes: Int.max - 1, pixelStride: Int.max - 2, storageBits: 8, littleEndian: true)
        #expect(!largeStride.packedRows && largeStride.requiredBytes == Int.max - 1)
        #expect(largeStride.byteOffset(for: 0) == 0)
        #expect(largeStride.byteOffset(for: 1) == Int.max - 2)
    }
}

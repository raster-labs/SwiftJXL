// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

struct ModularConstantPerformanceTests {
    @Test(arguments: [1, 512, 513, 1025], [0, 32768, 65535])
    func constantPlanesKeepPrecisionAcrossGroups(_ width: Int, _ value: Int) throws {
        let fixture = ModularProfileCase(width: width, height: 3, channels: 1, bits: 16)
        let pixels = [[UInt16](repeating: UInt16(value), count: width * 3)]
        let bytes = try fixture.encode(pixels, effort: 3, budget: fixture.budget())
        let decoded = try ModularFrameDecoder.decode(bytes, budget: fixture.budget())
        #expect(decoded.bitsPerSample == 16)
        #expect(decoded.image.channels[0].pixels == pixels[0].map(Int32.init))
        #if os(macOS) || os(Linux)
        if let binary = ProcessInfo.processInfo.environment["SWIFTJXL_ORACLE_BIN"] {
            try ModularProfileTests().oracle(bytes, fixture: fixture, pixels: pixels, effort: 3, binary: binary)
        }
        #endif
    }

    @Test func flat2048DoesNotExceedPinnedPredecessorSize() throws {
        let fixture = ModularProfileCase(width: 2048, height: 2048, channels: 1, bits: 16)
        let pixels = [[UInt16](repeating: 32768, count: 2048 * 2048)]
        func budget() throws -> ScalarOperationBudget {
            try fixture.budget(workspace: 2 * 1024 * 1024 * 1024,
                memory: 3 * 1024 * 1024 * 1024, decoded: 32 * 1024 * 1024)
        }
        let bytes = try fixture.encode(pixels, effort: 3, budget: budget())
        // Prior qualified predecessor: 363 bytes; successor: 367 bytes.
        // A constant leaf removes all pixel entropy bits without omitting a
        // required terminal state or changing precision/effort/fidelity.
        #expect(bytes.count <= 363)
        let decoded = try ModularFrameDecoder.decode(bytes, budget: budget())
        #expect(decoded.image.channels[0].pixels == pixels[0].map(Int32.init))
        #if os(macOS) || os(Linux)
        if let binary = ProcessInfo.processInfo.environment["SWIFTJXL_ORACLE_BIN"] {
            try ModularProfileTests().oracle(bytes, fixture: fixture, pixels: pixels, effort: 3, binary: binary)
        }
        #endif
    }

    @Test(arguments: [1, 2, 3, 4])
    func constantCandidateRequiresEverySampleAndChannel(_ channels: Int) throws {
        let fixture = ModularProfileCase(width: 513, height: 3, channels: channels, bits: 12)
        for perturbation in [false, true] {
            var pixels = [[UInt16]](repeating: [UInt16](repeating: 4095, count: 513 * 3), count: channels)
            if perturbation { pixels[channels - 1][513 * 3 - 1] = 0 }
            let bytes = try fixture.encode(pixels, effort: 3, budget: fixture.budget())
            let decoded = try ModularFrameDecoder.decode(bytes, budget: fixture.budget())
            for channel in 0..<channels {
                #expect(decoded.image.channels[channel].pixels == pixels[channel].map(Int32.init))
            }
            #if os(macOS) || os(Linux)
            if let binary = ProcessInfo.processInfo.environment["SWIFTJXL_ORACLE_BIN"] {
                try ModularProfileTests().oracle(bytes, fixture: fixture, pixels: pixels, effort: 3, binary: binary)
            }
            #endif
        }
    }
}

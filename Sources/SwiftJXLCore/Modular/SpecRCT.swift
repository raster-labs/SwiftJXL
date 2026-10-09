// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Adapted from JXLSwift Modular/SpecRCT.swift at
// 57e81cb9e2411d1efac435b429a306a031744c1e, Copyright (c) 2026 Raster-Lab.
// JPEG XL Project Authors' reversible colour-transform algorithm retains
// BSD-3-Clause terms; see Documentation/ThirdParty/libjxl-LICENSE.txt.
import Foundation

package enum SpecRCTError: Error, Sendable {
    case invalidType(UInt32)
    case mismatchedChannelLengths
}

/// Inverse of all 42 Modular reversible colour transforms. Each input triple
/// is loaded before writes, so the caller's three working planes are reused.
/// No output planes or permutation buffers are explicitly allocated here.
/// The caller admits array ownership/COW costs and supplies its work checkpoint.
package enum SpecRCT {
    package static func inverse(rctType: UInt32, channel0: inout [Int32],
                                channel1: inout [Int32], channel2: inout [Int32],
                                checkpoint: () throws -> Void) throws {
        try checkpoint()
        guard channel0.count == channel1.count, channel1.count == channel2.count else {
            throw SpecRCTError.mismatchedChannelLengths
        }
        guard rctType < 42 else { throw SpecRCTError.invalidType(rctType) }
        if rctType == 0 { return }
        let permutation = Int(rctType / 7), custom = Int(rctType % 7)
        // Scoped borrows hoist array uniqueness checks out of the pixel loop.
        // All three lengths were checked above. The only indices visited are
        // 0..<count; pointers never leave these synchronous nested borrows.
        // The work checkpoint must not re-enter the caller's working arrays.
        try channel0.withUnsafeMutableBufferPointer { input0 in
            try channel1.withUnsafeMutableBufferPointer { input1 in
                try channel2.withUnsafeMutableBufferPointer { input2 in
                    let outputs: (UnsafeMutableBufferPointer<Int32>, UnsafeMutableBufferPointer<Int32>, UnsafeMutableBufferPointer<Int32>)
                    switch permutation {
                    case 0: outputs = (input0,input1,input2)
                    case 1: outputs = (input1,input2,input0)
                    case 2: outputs = (input2,input0,input1)
                    case 3: outputs = (input0,input2,input1)
                    case 4: outputs = (input1,input0,input2)
                    default: outputs = (input2,input1,input0)
                    }
                    let count = input0.count
                    var start = 0
                    while start < count {
                        try checkpoint()
                        let end = start + min(1024, count - start)
                        if custom == 6 {
                            for i in start..<end {
                                let first = input0[i], second = input1[i], third = input2[i]
                                let temporary = first &- (third >> 1)
                                let b = third &+ temporary
                                let c = temporary &- (second >> 1)
                                let a = c &+ second
                                outputs.0[i] = a; outputs.1[i] = b; outputs.2[i] = c
                            }
                        } else {
                            for i in start..<end {
                                let first = input0[i], second = input1[i], third = input2[i]
                                let c = custom & 1 != 0 ? third &+ first : third
                                let b: Int32
                                switch custom >> 1 {
                                case 1: b = second &+ first
                                case 2: b = second &+ ((first &+ c) >> 1)
                                default: b = second
                                }
                                outputs.0[i] = first; outputs.1[i] = b; outputs.2[i] = c
                            }
                        }
                        start = end
                    }
                }
            }
        }
        try checkpoint()
    }
}

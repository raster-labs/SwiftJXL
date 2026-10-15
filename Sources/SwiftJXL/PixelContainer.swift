// SPDX-License-Identifier: Apache-2.0
import Foundation
import SwiftJXLCore

/// Basic ISO/IEC 18181-2 container: signature, ftyp and a single jxlc box.
/// No ancillary metadata is invented. Compressed assembly is distinct from
/// the zero-copy pixel handoff. Admit source/output overlap before allocating.
func packagePixelCodestream(_ source: Data, format: PixelContainerFormat,
                            budget: ScalarOperationBudget) throws -> (data: Data, copies: [CopyEvent]) {
    try budget.checkpoint()
    guard format == .iso else { return (source, []) }
    let size = try ScalarOperationBudget.sum(source.count, 40)
    guard UInt64(source.count) <= UInt64(UInt32.max) - 8 else {
        throw ScalarModularError.resourceLimit
    }
    try budget.reserveOutput(size)
    try budget.reserveWorkspace(source.count)
    var result = Data()
    result.reserveCapacity(size)
    result.append(contentsOf: jxlContainerSignature)
    result.append(contentsOf: [0, 0, 0, 20, 102, 116, 121, 112, 106, 120, 108, 32,
                               0, 0, 0, 0, 106, 120, 108, 32])
    let box = UInt32(source.count + 8)
    for shift in [24, 16, 8, 0] { result.append(UInt8(truncatingIfNeeded: box >> shift)) }
    result.append(contentsOf: [106, 120, 108, 99])
    // Bound cancellation even when the caller explicitly admits a large stream.
    try source.withUnsafeBytes { bytes in
        for offset in stride(from: 0, to: bytes.count, by: 65536) {
            try budget.checkpoint()
            result.append(contentsOf: bytes.bindMemory(to: UInt8.self)[offset..<min(offset + 65536, bytes.count)])
        }
    }
    try budget.checkpoint()
    return (result, [try CopyEvent(reason: "Pixel codestream copied into explicit ISO container",
        bytesMoved: source.count, sourceLayout: "compressed codestream", destinationLayout: "jxlc payload")])
}

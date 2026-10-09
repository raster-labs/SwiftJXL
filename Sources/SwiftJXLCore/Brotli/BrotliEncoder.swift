// SPDX-License-Identifier: Apache-2.0
// Adapted from JXLSwift 57e81cb9e2411d1efac435b429a306a031744c1e,
// Sources/JXLSwift/Brotli/BrotliEncoder.swift. RFC 7932 §9.2 stored blocks.
import Foundation

package enum BrotliEncoder {
    /// A standard Brotli stream with an uncompressed meta-block. This preserves
    /// exact JPEG reconstruction metadata, without claiming entropy compression.
    /// The caller must separately admit the enclosing JBRD/container buffers.
    package static func encodeUncompressed(_ data: Data, policy: BrotliPolicy) throws -> Data {
        guard data.count <= policy.maximumInputBytes, data.count <= (1 << 24) else {
            throw BrotliError.resourceLimit
        }
        let headerBytes = data.isEmpty ? 0 : (data.count <= 65536 ? 3 : 4)
        let encodedSize = data.count + headerBytes + 1
        guard encodedSize <= policy.maximumOutputBytes else { throw BrotliError.resourceLimit }
        var budget = BrotliBudget(policy: policy)
        try budget.reserve(data.count)
        try budget.reserve(encodedSize, stride: 3) // output capacity and transient reallocation/copy
        try budget.reserve(1024)
        var output = Data()
        output.reserveCapacity(encodedSize)
        if !data.isEmpty {
            let length = UInt32(data.count - 1)
            let nibbles = length < 1 << 16 ? 4 : (length < 1 << 20 ? 5 : 6)
            // WBITS=16 (0), ISLAST=0, MNIBBLES, MLEN-1, ISUNCOMPRESSED=1.
            let header = UInt32(nibbles - 4) << 2 | length << 4 | 1 << (4 + nibbles * 4)
            for index in 0..<headerBytes {
                output.append(UInt8(truncatingIfNeeded: header >> (index * 8)))
            }
            var offset = 0
            while offset < data.count {
                try policy.checkpoint()
                let end = min(data.count, offset + 4096)
                output.append(data[(data.startIndex + offset)..<(data.startIndex + end)])
                offset = end
            }
            output.append(3) // ISLAST=1, ISLASTEMPTY=1, zero padding
        } else {
            output.append(6) // WBITS=16 then empty final meta-block
        }
        try policy.checkpoint()
        return output
    }
}

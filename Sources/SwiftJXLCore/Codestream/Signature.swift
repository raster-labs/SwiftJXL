// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Raster-Lab.
// Adapted from JXLSwift 57e81cb9e2411d1efac435b429a306a031744c1e, Sources/JXLSwift/Codestream/Signature.swift.
// JPEG XL codestream signature (ISO/IEC 18181-1 §C.3.1).
//
// Every codestream — whether naked or packaged inside a `jxlc`/`jxlp`
// container box — begins with the two-byte sequence `FF 0A`.

import Foundation

package let codestreamSignatureBytes: [UInt8] = [0xFF, 0x0A]

/// Whether `data` starts with the codestream signature.
package func hasCodestreamSignature(_ data: Data) -> Bool {
    data.count >= 2
        && data[data.startIndex]     == 0xFF
        && data[data.startIndex + 1] == 0x0A
}

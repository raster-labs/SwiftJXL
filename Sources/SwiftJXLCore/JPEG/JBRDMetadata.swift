// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Raster-Lab.
// Adapted from JXLSwift JBRDBox.distributeBrotliPayload at
// 57e81cb9e2411d1efac435b429a306a031744c1e; exact lengths replace partial fills.
import Foundation

package struct JBRDExternalMetadata: Sendable {
    /// Original TIFF bytes after Exif\0\0, not the enclosing JXL Exif box.
    package var exifTIFF: Data?
    package var xmp: Data?
    package var iccProfile: Data?
    package init(exifTIFF: Data? = nil, xmp: Data? = nil, iccProfile: Data? = nil) {
        self.exifTIFF = exifTIFF; self.xmp = xmp; self.iccProfile = iccProfile
    }
}

extension JBRDParsedBundle {
    /// Populate admitted marker slots only after exact Brotli expansion. Missing
    /// external metadata or size mismatches throw; never manufacture zero bytes.
    /// This method does not decompress Brotli or reconstruct JPEG entropy data.
    package func resolvingPayload(_ decoded: Data, external: JBRDExternalMetadata = .init(),
                                  policy: JBRDPolicy) throws -> JBRDBox {
        try policy.checkpoint()
        guard decoded.count == expectedBrotliBytes, box.appData.count == box.appMarkerType.count,
              box.markerOrder.count <= policy.maximumMarkers else {
            throw JBRDError.malformed("Metadata payload size or layout mismatch")
        }
        var budget = JBRDBudget(policy: policy)
        try budget.reserve(reservedBytes, stride: 1)
        try budget.reserve(box.markerOrder.count, stride: 1024)
        try budget.reserve(decoded.count, stride: 2)
        for group in [box.appData, box.comData, box.interMarkerData] {
            for value in group { try budget.reservePayload(value.count) }
        }
        try budget.reservePayload(box.tailData.count)
        for bytes in [external.exifTIFF, external.xmp, external.iccProfile] {
            if let bytes { try budget.reserve(bytes.count, stride: 2) }
        }
        let appMarkers = box.markerOrder.filter { (0xe0...0xef).contains($0) }
        guard appMarkers.count == box.appData.count else { throw JBRDError.malformed("APP marker count") }
        let iccCount = box.appMarkerType.filter { $0 == .icc }.count
        guard iccCount <= 255 else { throw JBRDError.malformed("ICC fragment count") }
        var result = box, cursor = 0, iccCursor = 0, iccIndex = 0
        func consume(_ count: Int) throws -> Data {
            guard count >= 0, count <= decoded.count - cursor else { throw JBRDError.truncated }
            defer { cursor += count }
            return Data(decoded[(decoded.startIndex + cursor)..<(decoded.startIndex + cursor + count)])
        }
        func validateMarker(_ data: Data, code: UInt8) throws {
            guard data.count >= 3, data[data.startIndex] == code,
                  Int(data[data.startIndex + 1]) * 256 + Int(data[data.startIndex + 2]) + 1 == data.count else {
                throw JBRDError.malformed("Marker identity or length mismatch")
            }
        }
        func marker(code: UInt8, size: Int, prefix: Data, body: Data?) throws -> Data {
            guard (3...65536).contains(size), prefix.count <= size - 3,
                  let body, body.count == size - 3 - prefix.count else {
                throw JBRDError.malformed("Missing or incorrectly sized external metadata")
            }
            return Data([code, UInt8((size - 1) >> 8), UInt8((size - 1) & 255)]) + prefix + body
        }
        for i in box.appData.indices {
            try policy.checkpoint()
            let size = box.appData[i].count
            switch box.appMarkerType[i] {
            case .unknown:
                result.appData[i] = try consume(size)
            case .exif:
                result.appData[i] = try marker(code: 0xe1, size: size,
                    prefix: Data("Exif\0\0".utf8), body: external.exifTIFF)
            case .xmp:
                result.appData[i] = try marker(code: 0xe1, size: size,
                    prefix: Data("http://ns.adobe.com/xap/1.0/\0".utf8), body: external.xmp)
            case .icc:
                guard size >= 17, let icc = external.iccProfile, size - 17 <= icc.count - iccCursor else {
                    throw JBRDError.malformed("Missing or truncated ICC profile")
                }
                iccIndex += 1
                let count = size - 17
                let body = Data(icc[(icc.startIndex + iccCursor)..<(icc.startIndex + iccCursor + count)])
                iccCursor += count
                result.appData[i] = try marker(code: 0xe2, size: size,
                    prefix: Data("ICC_PROFILE\0".utf8) + Data([UInt8(iccIndex), UInt8(iccCount)]), body: body)
            }
            try validateMarker(result.appData[i], code: appMarkers[i])
        }
        if iccCount > 0, iccCursor != external.iccProfile?.count { throw JBRDError.malformed("Surplus ICC bytes") }
        for i in box.comData.indices {
            try policy.checkpoint()
            result.comData[i] = try consume(box.comData[i].count)
            try validateMarker(result.comData[i], code: 0xfe)
        }
        for i in box.interMarkerData.indices {
            try policy.checkpoint()
            result.interMarkerData[i] = try consume(box.interMarkerData[i].count)
        }
        result.tailData = try consume(box.tailData.count)
        guard cursor == decoded.count else { throw JBRDError.malformed("Surplus metadata payload") }
        try policy.checkpoint()
        return result
    }
}

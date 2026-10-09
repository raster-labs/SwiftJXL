// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Raster-Lab.
// Adapted from JXLSwift JPEG/JBRDBox.swift at 57e81cb9e2411d1efac435b429a306a031744c1e.
import Foundation

package enum JBRDBoxWriter {
    /// Return the aligned reconstruction header only, with bounded field sizes.
    /// The caller must append a separately qualified Brotli payload.
    package static func write(_ box: JBRDBox, policy: JBRDPolicy) throws -> Data {
        let bound = try validateShape(box, policy: policy)
        var writer = BitWriter(reservingBytes: bound)
        try write(box, to: &writer, policy: policy)
        writer.alignToByte()
        let result = writer.finishToData()
        guard result.count <= bound else { throw JBRDError.resourceLimit }
        // Reuse reader semantic validation before publishing a header. The one
        // dummy body byte supplies framing only; it is never returned as a body.
        _ = try JBRDBoxReader.read(result + Data([0x06]), policy: policy)
        try policy.checkpoint()
        return result
    }

    private static func validateShape(_ box: JBRDBox, policy: JBRDPolicy) throws -> Int {
        try policy.checkpoint()
        let markers = box.markerOrder
        guard !markers.isEmpty, markers.count <= policy.maximumMarkers else { throw JBRDError.resourceLimit }
        var budget = JBRDBudget(policy: policy)
        try budget.reserve(16384, stride: 1)
        try budget.reserve(markers.count, stride: 1024)
        guard markers.last == 0xd9,
              markers.dropLast().allSatisfy({ $0 >= 0xc0 && $0 != 0xd9 }),
              box.appData.count == markers.filter({ (0xe0...0xef).contains($0) }).count,
              box.appMarkerType.count == box.appData.count,
              box.comData.count == markers.filter({ $0 == 0xfe }).count,
              box.interMarkerData.count == markers.filter({ $0 == 0xff }).count,
              box.scanInfo.count == markers.filter({ $0 == 0xda }).count,
              box.components.count == 1 || box.components.count == 3,
              (1...3).contains(box.quant.count), (2...89).contains(box.huffmanCode.count),
              box.restartInterval <= 65535, (markers.contains(0xdd) || box.restartInterval == 0),
              box.tailData.count <= 4_260_096 else {
            throw JBRDError.malformed("Invalid reconstruction header shape")
        }
        for bytes in box.appData + box.comData {
            guard (3...65536).contains(bytes.count) else { throw JBRDError.malformed("Marker size") }
            try budget.reservePayload(bytes.count)
        }
        for bytes in box.interMarkerData {
            guard bytes.count <= 65535 else { throw JBRDError.malformed("Inter-marker size") }
            try budget.reservePayload(bytes.count)
        }
        try budget.reservePayload(box.tailData.count)
        for component in box.components {
            guard component.id <= 255, component.quantIdx < box.quant.count else { throw JBRDError.malformed("Component") }
        }
        for quant in box.quant {
            guard quant.index < 4, quant.precision <= 1, quant.values.isEmpty || quant.values.count == 64 else {
                throw JBRDError.malformed("Quantisation table")
            }
        }
        for huffman in box.huffmanCode {
            guard huffman.counts.count == 17, huffman.counts.allSatisfy({ $0 <= 255 }),
                  huffman.counts.reduce(0, +) == huffman.values.count, huffman.values.count <= 257,
                  huffman.values.allSatisfy({ $0 <= 256 }),
                  [0, 1, 2, 3, 16, 17, 18, 19].contains(huffman.slotId) else {
                throw JBRDError.malformed("Huffman table shape")
            }
        }
        var events = 0
        for scan in box.scanInfo {
            guard (1...3).contains(scan.numComponents), scan.components.count == Int(scan.numComponents),
                  scan.ss <= 63, scan.se <= 63, scan.ah <= 13, scan.al <= 13, scan.lastNeededPass <= 10 else {
                throw JBRDError.malformed("Scan fields")
            }
            for component in scan.components {
                guard component.compIdx < box.components.count, component.dcTblIdx < 4, component.acTblIdx < 4 else {
                    throw JBRDError.malformed("Scan component")
                }
            }
            try budget.reserveEvents(scan.resetPoints.count)
            try budget.reserveEvents(scan.extraZeroRuns.count)
            events += scan.resetPoints.count + scan.extraZeroRuns.count
            var previous: Int64 = -1
            for index in scan.resetPoints {
                guard Int64(index) > previous, index < 3 << 26 else { throw JBRDError.malformed("Reset order") }
                previous = Int64(index)
            }
            previous = -1
            for event in scan.extraZeroRuns {
                guard Int64(event.blockIdx) > previous, event.blockIdx < 3 << 26,
                      (1...4).contains(event.numExtraZeroRuns) else { throw JBRDError.malformed("Extra zero run") }
                previous = Int64(event.blockIdx)
            }
        }
        guard box.paddingBits.count < 1 << 24, box.paddingBits.count <= policy.maximumPaddingBits,
              box.hasZeroPaddingBit || box.paddingBits.isEmpty else {
            throw JBRDError.malformed("Padding bits")
        }
        for (index, bit) in box.paddingBits.enumerated() {
            if index & 4095 == 0 { try policy.checkpoint() }
            guard bit <= 1 else { throw JBRDError.malformed("Padding bit value") }
        }
        // Upper envelope: marker/section fields, each <=257-symbol Huffman
        // table, scan headers, <=34-bit events and packed padding, plus slack.
        let bound = 1024 + markers.count * 16 + box.huffmanCode.count * 512
            + box.scanInfo.count * 16 + events * 8 + (box.paddingBits.count + 7) / 8
        guard bound < policy.maximumInputBytes else { throw JBRDError.resourceLimit }
        try budget.reserve(bound, stride: 8) // writer capacity, Data and validation overlap
        try budget.reserve(box.paddingBits.count, stride: 4)
        return bound
    }


    // Field encoding retained from the predecessor; shape and capacity are
    // checked before this routine. Brotli follows the returned aligned header.
    private static func write(_ box: JBRDBox, to w: inout BitWriter, policy: JBRDPolicy) throws {
        do {
            // 1. is_gray.
            let isGray = box.components.count == 1
            w.writeBit(isGray)

            // 2. marker_order walk — 6-bit codes (marker - 0xC0).
            if box.markerOrder.count > 16384 {
                throw JBRDError.tooManyMarkers(box.markerOrder.count)
            }
            for m in box.markerOrder {
                try policy.checkpoint()
                let code = UInt32(m) &- 0xC0
                w.write(bits: 6, value: code)
            }

            // 3. App marker metadata.
            for i in 0..<box.appData.count {
                try policy.checkpoint()
                let t = box.appMarkerType[i].rawValue
                try w.writeU32(t, distributions: (
                    .literal(0), .literal(1),
                    .offset(constant: 2, extraBits: 1),
                    .offset(constant: 4, extraBits: 2)))
                let len = UInt32(box.appData[i].count) - 1
                w.write(bits: 16, value: len)
            }
            // 4. Com marker lengths.
            for com in box.comData {
                try policy.checkpoint()
                let len = UInt32(com.count) - 1
                w.write(bits: 16, value: len)
            }
            // 5. Quant tables.
            let nQuant = UInt32(box.quant.count)
            if nQuant == 4 {
                throw JBRDError.invalidQuantTableCount
            }
            try w.writeU32(nQuant, distributions: (
                .literal(1), .literal(2),
                .literal(3), .literal(4)))
            for q in box.quant {
                if q.precision > 1 {
                    throw JBRDError.invalidQuantPrecision
                }
                w.write(bits: 1, value: q.precision)
                w.write(bits: 2, value: q.index)
                w.writeBit(q.isLast)
            }
            // 6. Component type.
            //    Classify based on box.components ids — mirrors the
            //    libjxl reader's component_type detection. Wire format
            //    is Bits(2, default=1).
            let componentType: UInt32
            if box.components.count == 1 && box.components[0].id == 1
            {
                componentType = 0  // kGray
            } else if box.components.count == 3
                && box.components[0].id == 1
                && box.components[1].id == 2
                && box.components[2].id == 3
            {
                componentType = 1  // kYCbCr
            } else if box.components.count == 3
                && box.components[0].id == UInt32(UInt8(ascii: "R"))
                && box.components[1].id == UInt32(UInt8(ascii: "G"))
                && box.components[2].id == UInt32(UInt8(ascii: "B"))
            {
                componentType = 2  // kRGB
            } else {
                componentType = 3  // kCustom
            }
            w.write(bits: 2, value: componentType)
            if componentType == 3 {
                let nc = UInt32(box.components.count)
                try w.writeU32(nc, distributions: (
                    .literal(1), .literal(2),
                    .literal(3), .literal(4)))
                for comp in box.components {
                    w.write(bits: 8, value: comp.id)
                }
            }
            // Per-component quant_idx.
            for comp in box.components {
                w.write(bits: 2, value: comp.quantIdx)
            }

            // 7. Huffman codes.
            try w.writeU32(
                UInt32(box.huffmanCode.count),
                distributions: (
                    .literal(4),
                    .offset(constant: 2, extraBits: 3),
                    .offset(constant: 10, extraBits: 4),
                    .offset(constant: 26, extraBits: 6)))
            for hc in box.huffmanCode {
                try policy.checkpoint()
                let isAC = (hc.slotId & 0x10) != 0
                let id = UInt32(hc.slotId & 0x0F)
                w.writeBit(isAC)
                w.write(bits: 2, value: id)
                w.writeBit(hc.isLast)
                var numSymbols = 0
                for k in 0...16 {
                    try w.writeU32(hc.counts[k], distributions: (
                        .literal(0), .literal(1),
                        .offset(constant: 2, extraBits: 3),
                        .bits(8)))
                    numSymbols += Int(hc.counts[k])
                }
                if numSymbols > hc.values.count {
                    throw JBRDError.malformed(
                        "Huffman values undersized: numSymbols="
                        + "\(numSymbols), values.count="
                        + "\(hc.values.count)")
                }
                for k in 0..<numSymbols {
                    try w.writeU32(hc.values[k], distributions: (
                        .bits(2),
                        .offset(constant: 4, extraBits: 2),
                        .offset(constant: 8, extraBits: 4),
                        .offset(constant: 1, extraBits: 8)))
                }
            }

            // 8. Scan info.
            for scan in box.scanInfo {
                try policy.checkpoint()
                if scan.numComponents >= 4 {
                    throw JBRDError.invalidScanComponentCount(
                        scan.numComponents)
                }
                try w.writeU32(scan.numComponents,
                    distributions: (
                        .literal(1), .literal(2),
                        .literal(3), .literal(4)))
                w.write(bits: 6, value: scan.ss)
                w.write(bits: 6, value: scan.se)
                w.write(bits: 4, value: scan.al)
                w.write(bits: 4, value: scan.ah)
                for k in 0..<Int(scan.numComponents) {
                    let c = scan.components[k]
                    w.write(bits: 2, value: c.compIdx)
                    w.write(bits: 2, value: c.acTblIdx)
                    w.write(bits: 2, value: c.dcTblIdx)
                }
                try w.writeU32(scan.lastNeededPass,
                    distributions: (
                        .literal(0), .literal(1),
                        .literal(2),
                        .offset(constant: 3, extraBits: 3)))
            }

            // 9. Restart interval (only if has_dri).
            let hasDRI = box.markerOrder.contains(0xDD)
            if hasDRI {
                w.write(bits: 16, value: box.restartInterval)
            }

            // 10. Reset points + extra zero runs per scan.
            for scan in box.scanInfo {
                try policy.checkpoint()
                try w.writeU32(
                    UInt32(scan.resetPoints.count),
                    distributions: (
                        .literal(0),
                        .offset(constant: 1, extraBits: 2),
                        .offset(constant: 4, extraBits: 4),
                        .offset(constant: 20, extraBits: 16)))
                var lastBlockIdx: Int = -1
                for b in scan.resetPoints {
                try policy.checkpoint()
                    let delta = b - UInt32(lastBlockIdx + 1)
                    if b >= (3 << 26) {
                        throw JBRDError.invalidBlockIndex(b)
                    }
                    try w.writeU32(delta, distributions: (
                        .literal(0),
                        .offset(constant: 1, extraBits: 3),
                        .offset(constant: 9, extraBits: 5),
                        .offset(constant: 41, extraBits: 28)))
                    lastBlockIdx = Int(b)
                }
                try w.writeU32(
                    UInt32(scan.extraZeroRuns.count),
                    distributions: (
                        .literal(0),
                        .offset(constant: 1, extraBits: 2),
                        .offset(constant: 4, extraBits: 4),
                        .offset(constant: 20, extraBits: 16)))
                lastBlockIdx = -1
                for ezr in scan.extraZeroRuns {
                try policy.checkpoint()
                    try w.writeU32(ezr.numExtraZeroRuns,
                        distributions: (
                            .literal(1),
                            .offset(constant: 2, extraBits: 2),
                            .offset(constant: 5, extraBits: 4),
                            .offset(constant: 20, extraBits: 8)))
                    let delta = ezr.blockIdx
                        - UInt32(lastBlockIdx + 1)
                    if ezr.blockIdx > (3 << 26) {
                        throw JBRDError.invalidBlockIndex(
                            ezr.blockIdx)
                    }
                    try w.writeU32(delta, distributions: (
                        .literal(0),
                        .offset(constant: 1, extraBits: 3),
                        .offset(constant: 9, extraBits: 5),
                        .offset(constant: 41, extraBits: 28)))
                    lastBlockIdx = Int(ezr.blockIdx)
                }
            }

            // 11. Inter-marker sizes.
            for data in box.interMarkerData {
                w.write(bits: 16, value: UInt32(data.count))
            }

            // 12. Tail data length.
            let tailLen = UInt32(box.tailData.count)
            if tailLen > 4_260_096 {
                throw JBRDError.tailDataTooLarge(tailLen)
            }
            try w.writeU32(tailLen, distributions: (
                .literal(0),
                .offset(constant: 1, extraBits: 8),
                .offset(constant: 257, extraBits: 16),
                .offset(constant: 65793, extraBits: 22)))

            // 13. Padding bits.
            w.writeBit(box.hasZeroPaddingBit)
            if box.hasZeroPaddingBit {
                let nbit = UInt32(box.paddingBits.count)
                w.write(bits: 24, value: nbit)
                for b in box.paddingBits {
                try policy.checkpoint()
                    w.writeBit(b != 0)
                }
            }
        } catch let e as BitstreamError {
            throw JBRDError.bitstream(e)
        } catch let e as JBRDError {
            throw e
        }
    }
}

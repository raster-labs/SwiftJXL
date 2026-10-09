// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Raster-Lab.
// Adapted from JXLSwift JPEG/JBRDBox.swift at 57e81cb9e2411d1efac435b429a306a031744c1e.
// `JPEG/JBRDBox.swift` — `jbrd` box reader + builder.
//
// The `jbrd` (JPEG Bitstream Reconstruction Data) box is the ISOBMFF
// container box JXL writes alongside a coefficient-bridged frame
// when the goal is byte-identical JPEG reconstruction (JXL → JPEG).
// Without `jbrd`, `djxl --output_format=jpeg` falls back to
// `--pixels_to_jpeg` (re-encoding from decoded pixels), which is
// lossy at the second JPEG quantisation step.
//
// Structure (per libjxl `lib/jxl/jpeg/jpeg_data.{h,cc}` +
// `dec_jpeg_data.cc`):
//
// ```
// jbrd-box-payload:
//   Bundle-serialised JPEGData (Fields::VisitFields traversal)
//     ─ is_gray            1 bit
//     ─ marker_order       sequence of 6-bit marker codes
//                          (0xc0..0xff range), terminated by 0xd9 (EOI)
//     ─ app_marker_type[]  U32 enum per app marker (kUnknown/kICC/kExif/kXMP)
//     ─ app/com_marker_len 16-bit length per APP / COM marker
//     ─ quant tables       precision, slot index, is_last
//     ─ component metadata kGray/kYCbCr/kRGB/kCustom + ids
//     ─ huffman_code       counts[17] + values[N] per Huffman table
//     ─ scan_info          per-scan Ss/Se/Al/Ah + comp_idx/dc/ac
//     ─ restart_interval, reset_points, extra_zero_runs (per scan)
//     ─ inter_marker_data sizes, tail_data length
//     ─ padding_bits flag + bits
//   <byte alignment>
//   Brotli-compressed blob carrying the marker payloads
//     (app_data, com_data, inter_marker_data, tail_data)
//     decompressed using the sizes from the Bundle.
// ```
//
// This stage parses and bounds the bundle; Brotli expansion and JPEG restoration
// are separate integration stages.

import Foundation

/// Errors specific to `jbrd` parsing.
package enum JBRDError: Error, Sendable {
    /// Wrapper around a bit-reader error.
    case bitstream(BitstreamError)
    /// Marker order exceeded the libjxl-imposed 16384-entry cap.
    case tooManyMarkers(Int)
    /// Number of quantisation tables was the reserved value 4
    /// (libjxl `jpeg_data.cc:133`).
    case invalidQuantTableCount
    /// Quant-table precision exceeds the encoded 8/16-bit alternatives.
    case invalidQuantPrecision
    /// Number of components was neither 1 nor 3 in custom mode.
    case invalidComponentCount(UInt32)
    /// Component referenced a quant index out of range.
    case invalidQuantIndex(comp: Int, idx: UInt32)
    /// Huffman-table EOI symbol mismatch (libjxl
    /// `jpeg_data.cc:248-250`).
    case missingEOISymbol
    /// Duplicate Huffman symbols in a single table.
    case duplicateHuffmanSymbols
    /// DC Huffman table contained AC-range symbols (libjxl
    /// `jpeg_data.cc:259-262`).
    case dcHuffmanOutOfRange
    /// Scan SOS-marker num_components > 3 (libjxl
    /// `jpeg_data.cc:268-270`).
    case invalidScanComponentCount(UInt32)
    /// Block-index field out of range
    /// (libjxl `jpeg_data.cc:308-313`).
    case invalidBlockIndex(UInt32)
    /// Tail-data length exceeded the 4 260 096-byte cap (libjxl
    /// `jpeg_data.cc:349-352`).
    case tailDataTooLarge(UInt32)
    /// Reading hit unexpected end-of-data.
    case truncated
    /// A feature in jbrd we haven't implemented yet.
    case malformed(String)
    case resourceLimit
}

/// One quantisation table entry from the jbrd Bundle. Maps directly
/// to libjxl's `JPEGQuantTable`. `values` are the unpacked 64-element
/// natural-order matrix. The coefficient bridge supplies actual values;
/// the reconstruction bundle itself records only the table metadata.
package struct JBRDQuantTable: Sendable, Equatable {
    /// Precision flag: 0 = 8-bit table, 1 = 16-bit. Accepts
    /// precision 0 or 1 as encoded in the reconstruction bundle.
    package var precision: UInt32
    /// Slot index 0..3.
    package var index: UInt32
    /// True if this is the last table in its DQT marker.
    package var isLast: Bool
    /// 64 natural-order coefficients (decoded from the JPEG DQT
    /// payload, not stored in the jbrd Bundle itself — the bridge
    /// fills these from the JXL frame's quant matrices).
    package var values: [Int32]
    package init(
        precision: UInt32 = 0, index: UInt32 = 0,
        isLast: Bool = true, values: [Int32] = []
    ) {
        self.precision = precision
        self.index = index
        self.isLast = isLast
        self.values = values
    }
}

/// One Huffman table entry from the jbrd Bundle. Maps to libjxl's
/// `JPEGHuffmanCode`.
package struct JBRDHuffmanCode: Sendable, Equatable {
    /// Length histogram: counts[i] is the number of codes of bit
    /// length `i` (i ∈ 0..16). counts[0] is always 0.
    package var counts: [UInt32]
    /// Symbol values sorted by ascending bit length.
    package var values: [UInt32]
    /// Slot id: high nibble = AC flag (1=AC, 0=DC), low nibble =
    /// slot index 0..3.
    package var slotId: Int
    /// True if this is the last table in its DHT marker.
    package var isLast: Bool
    package init(
        counts: [UInt32] = Array(repeating: 0, count: 17),
        values: [UInt32] = [],
        slotId: Int = 0, isLast: Bool = true
    ) {
        self.counts = counts
        self.values = values
        self.slotId = slotId
        self.isLast = isLast
    }
}

/// Per-scan info (SOS marker contents + progressive-mode state).
package struct JBRDScanInfo: Sendable, Equatable {
    package var ss: UInt32        // Spectral start (Ss)
    package var se: UInt32        // Spectral end (Se)
    package var ah: UInt32        // Approximation high
    package var al: UInt32        // Approximation low
    package var numComponents: UInt32
    package var components: [JBRDScanComponent]
    package var lastNeededPass: UInt32
    package var resetPoints: [UInt32]
    package var extraZeroRuns: [JBRDExtraZeroRun]
    package init(
        ss: UInt32 = 0, se: UInt32 = 63,
        ah: UInt32 = 0, al: UInt32 = 0,
        numComponents: UInt32 = 1,
        components: [JBRDScanComponent] = [],
        lastNeededPass: UInt32 = 0,
        resetPoints: [UInt32] = [],
        extraZeroRuns: [JBRDExtraZeroRun] = []
    ) {
        self.ss = ss; self.se = se
        self.ah = ah; self.al = al
        self.numComponents = numComponents
        self.components = components
        self.lastNeededPass = lastNeededPass
        self.resetPoints = resetPoints
        self.extraZeroRuns = extraZeroRuns
    }
}

package struct JBRDScanComponent: Sendable, Equatable {
    package var compIdx: UInt32
    package var dcTblIdx: UInt32
    package var acTblIdx: UInt32
    package init(
        compIdx: UInt32 = 0, dcTblIdx: UInt32 = 0,
        acTblIdx: UInt32 = 0
    ) {
        self.compIdx = compIdx
        self.dcTblIdx = dcTblIdx
        self.acTblIdx = acTblIdx
    }
}

package struct JBRDExtraZeroRun: Sendable, Equatable {
    package var blockIdx: UInt32
    package var numExtraZeroRuns: UInt32
    package init(blockIdx: UInt32 = 0, numExtraZeroRuns: UInt32 = 1) {
        self.blockIdx = blockIdx
        self.numExtraZeroRuns = numExtraZeroRuns
    }
}

/// App-marker classification (libjxl `AppMarkerType`).
package enum JBRDAppMarkerType: UInt32, Sendable, Equatable {
    case unknown = 0
    case icc = 1
    case exif = 2
    case xmp = 3
}

/// One JPEG component (id + sampling factors + quant table).
package struct JBRDComponent: Sendable, Equatable {
    package var id: UInt32             // 1-byte component id
    package var hSampFactor: Int       // horizontal sampling factor
    package var vSampFactor: Int       // vertical sampling factor
    package var quantIdx: UInt32       // quant table 0..3
    package var widthInBlocks: UInt32
    package var heightInBlocks: UInt32
    package init(
        id: UInt32 = 0,
        hSampFactor: Int = 1, vSampFactor: Int = 1,
        quantIdx: UInt32 = 0,
        widthInBlocks: UInt32 = 0, heightInBlocks: UInt32 = 0
    ) {
        self.id = id
        self.hSampFactor = hSampFactor
        self.vSampFactor = vSampFactor
        self.quantIdx = quantIdx
        self.widthInBlocks = widthInBlocks
        self.heightInBlocks = heightInBlocks
    }
}

/// Full jbrd-Bundle payload. Mirrors libjxl's `JPEGData` struct at
/// the field level; reading + writing is via `JBRDBox.read`/`write`.
package struct JBRDBox: Sendable, Equatable {
    package var width: Int
    package var height: Int
    package var restartInterval: UInt32
    package var appData: [Data]
    package var appMarkerType: [JBRDAppMarkerType]
    package var comData: [Data]
    package var quant: [JBRDQuantTable]
    package var huffmanCode: [JBRDHuffmanCode]
    package var components: [JBRDComponent]
    package var scanInfo: [JBRDScanInfo]
    package var markerOrder: [UInt8]
    package var interMarkerData: [Data]
    package var tailData: Data
    package var hasZeroPaddingBit: Bool
    package var paddingBits: [UInt8]

    package init(
        width: Int = 0, height: Int = 0,
        restartInterval: UInt32 = 0,
        appData: [Data] = [],
        appMarkerType: [JBRDAppMarkerType] = [],
        comData: [Data] = [],
        quant: [JBRDQuantTable] = [],
        huffmanCode: [JBRDHuffmanCode] = [],
        components: [JBRDComponent] = [],
        scanInfo: [JBRDScanInfo] = [],
        markerOrder: [UInt8] = [],
        interMarkerData: [Data] = [],
        tailData: Data = Data(),
        hasZeroPaddingBit: Bool = false,
        paddingBits: [UInt8] = []
    ) {
        self.width = width; self.height = height
        self.restartInterval = restartInterval
        self.appData = appData
        self.appMarkerType = appMarkerType
        self.comData = comData
        self.quant = quant
        self.huffmanCode = huffmanCode
        self.components = components
        self.scanInfo = scanInfo
        self.markerOrder = markerOrder
        self.interMarkerData = interMarkerData
        self.tailData = tailData
        self.hasZeroPaddingBit = hasZeroPaddingBit
        self.paddingBits = paddingBits
    }
}

/// Bundle reader for the `jbrd` box payload. Implements the Field-
/// style serialisation libjxl's `JPEGData::VisitFields` produces.
/// `read` exposes the bounded header and payload range; `readResolved` also
/// decodes the native Brotli body and assembles exact marker metadata.
package enum JBRDBoxReader {

    /// Native reconstruction header + Brotli + marker metadata assembly. This
    /// still does not decode JPEG XL coefficients or reconstruct a JPEG file.
    package static func readResolved(_ data: Data, external: JBRDExternalMetadata = .init(),
                                     policy: JBRDPolicy) throws -> JBRDBox {
        let parsed = try read(data, policy: policy)
        var budget = JBRDBudget(policy: policy)
        try budget.reserve(parsed.reservedBytes, stride: 1)
        for bytes in [external.exifTIFF, external.xmp, external.iccProfile] {
            if let bytes { try budget.reserve(bytes.count, stride: 2) }
        }
        let remaining = policy.maximumMemoryBytes - budget.reserved
        let brotliPolicy = try BrotliPolicy(maximumInputBytes: policy.maximumInputBytes,
                                           maximumOutputBytes: policy.maximumPayloadBytes,
                                           maximumMemoryBytes: remaining, deadline: policy.deadline,
                                           checkpoint: { try policy.checkpoint() })
        let body = data[(data.startIndex + parsed.brotliRange.lowerBound)..<(data.startIndex + parsed.brotliRange.upperBound)]
        let decoded = try BrotliDecoder.decode(body, expectedOutputSize: parsed.expectedBrotliBytes, policy: brotliPolicy)
        // Fixed dictionary/context storage can remain resident after decode.
        // Decode temporaries have ended before the resolver's separate admission.
        return try parsed.resolvingPayload(decoded, external: external, policy: policy,
                                          retainedWorkspaceBytes: 1024 * 1024)
    }

    /// Parse and admit the reconstruction bundle, leaving its compressed
    /// metadata payload separate. This does not restore JPEG bytes by itself.
    package static func read(_ data: Data, policy: JBRDPolicy) throws -> JBRDParsedBundle {
        try policy.checkpoint()
        guard data.count <= policy.maximumInputBytes, data.count <= Int.max / 8 else {
            throw JBRDError.resourceLimit
        }
        var budget = JBRDBudget(policy: policy)
        try budget.reserve(data.count, stride: 2) // input owner + bit-reader copy
        try budget.reserve(16384, stride: 1)
        var reader = BitReader(data, deadline: policy.deadline)
        let box = try read(from: &reader, budget: &budget)
        try reader.expectZeroPadding()
        let offset = reader.position / 8
        guard offset < data.count else { throw JBRDError.truncated }
        var expected = box.tailData.count
        for (i, app) in box.appData.enumerated() where box.appMarkerType[i] == .unknown { expected += app.count }
        for value in box.comData { expected += value.count }
        for value in box.interMarkerData { expected += value.count }
        try policy.checkpoint()
        return JBRDParsedBundle(box: box, brotliRange: offset..<data.count,
                               expectedBrotliBytes: expected, reservedBytes: budget.reserved)
    }

    private static func read(from r: inout BitReader, budget: inout JBRDBudget) throws -> JBRDBox {
        var box = JBRDBox()
        do {
            // 1. is_gray
            let isGray = try r.readBit()
            // 2. marker_order walk (6-bit code + 0xc0 offset).
            //    Terminates at 0xd9 (EOI).
            var markers: [UInt8] = []
            var info = JPEGInfo()
            while true {
                let raw = try r.read(bits: 6)
                let marker = UInt8(raw + 0xC0)
                guard markers.count < budget.policy.maximumMarkers else { throw JBRDError.resourceLimit }
                try budget.reserve(1, stride: 1024) // marker, section records and vector capacities
                markers.append(marker)
                if marker & 0xF0 == 0xE0 { info.numAppMarkers += 1 }
                if marker == 0xFE { info.numComMarkers += 1 }
                if marker == 0xDA { info.numScans += 1 }
                if marker == 0xFF { info.numInterMarker += 1 }
                if marker == 0xDD { info.hasDRI = true }
                if markers.count > 16384 {
                    throw JBRDError.tooManyMarkers(markers.count)
                }
                if marker == 0xD9 { break }  // EOI terminator
            }
            guard info.numScans > 0 else { throw JBRDError.malformed("No JPEG scans") }
            box.markerOrder = markers

            // Size the per-section vectors from marker counts.
            box.appData = Array(repeating: Data(),
                count: info.numAppMarkers)
            box.appMarkerType = Array(
                repeating: .unknown, count: info.numAppMarkers)
            box.comData = Array(repeating: Data(),
                count: info.numComMarkers)
            box.scanInfo = Array(
                repeating: JBRDScanInfo(),
                count: info.numScans)

            // Set up component count from is_gray (will be refined
            // by the component_type field below).
            if isGray {
                box.components = [JBRDComponent()]
            } else {
                box.components = [
                    JBRDComponent(), JBRDComponent(),
                    JBRDComponent(),
                ]
            }

            // 3. Per app marker: marker_type (Enum 4-way) + 16-bit
            //    length.
            for i in 0..<info.numAppMarkers {
                // libjxl `U32(Val(0), Val(1), BitsOffset(1, 2),
                // BitsOffset(2, 4), 0, ...)`. Encodes 4 distinct
                // marker-type cases.
                let t = try r.readU32((
                    .literal(0),                  // kUnknown
                    .literal(1),                  // kICC
                    .offset(constant: 2, extraBits: 1),
                                                   // kExif (2..3)
                    .offset(constant: 4, extraBits: 2)
                                                   // kXMP (4..7)
                ))
                guard let mt = JBRDAppMarkerType(rawValue: t)
                else {
                    throw JBRDError.malformed(
                        "app_marker_type \(t) outside known enum")
                }
                box.appMarkerType[i] = mt
                let len = try r.read(bits: 16)
                // Allocate the marker storage at the recorded
                // length + 1 (length-field convention: stored
                // value is total bytes - 1).
                guard len >= 2 else { throw JBRDError.malformed("APP marker length") }
                try budget.reservePayload(Int(len) + 1)
                box.appData[i] = Data(
                    count: Int(len) + 1)
            }
            // 4. Per com marker: 16-bit length.
            for i in 0..<info.numComMarkers {
                let len = try r.read(bits: 16)
                guard len >= 2 else { throw JBRDError.malformed("COM marker length") }
                try budget.reservePayload(Int(len) + 1)
                box.comData[i] = Data(count: Int(len) + 1)
            }
            // 5. num_quant_tables — U32(Val(1), Val(2), Val(3),
            //    Val(4), default=2).
            let nQuant = try r.readU32((
                .literal(1), .literal(2),
                .literal(3), .literal(4)))
            if nQuant == 4 {
                throw JBRDError.invalidQuantTableCount
            }
            box.quant = Array(
                repeating: JBRDQuantTable(),
                count: Int(nQuant))
            for i in 0..<Int(nQuant) {
                let precision = try r.read(bits: 1)
                if precision > 1 {
                    throw JBRDError.invalidQuantPrecision
                }
                let index = try r.read(bits: 2)
                let isLast = try r.readBit()
                box.quant[i] = JBRDQuantTable(
                    precision: precision, index: index,
                    isLast: isLast)
            }
            // 6. component_type — Bits(2, default=kYCbCr=1).
            //    Values: 0=kGray, 1=kYCbCr, 2=kRGB, 3=kCustom.
            let compType = try r.read(bits: 2)
            var numComponents: UInt32
            switch compType {
            case 0:  // kGray
                numComponents = 1
            case 1, 2:  // kYCbCr or kRGB
                numComponents = 3
            case 3:  // kCustom — read num_components
                numComponents = try r.readU32((
                    .literal(1), .literal(2),
                    .literal(3), .literal(4)))
                if numComponents != 1 && numComponents != 3 {
                    throw JBRDError.invalidComponentCount(
                        numComponents)
                }
            default:
                throw JBRDError.invalidComponentCount(compType)
            }
            // Resize components and assign canonical ids.
            if box.components.count != Int(numComponents) {
                box.components = Array(
                    repeating: JBRDComponent(),
                    count: Int(numComponents))
            }
            switch compType {
            case 0:
                box.components[0].id = 1
            case 1:  // YCbCr
                box.components[0].id = 1
                box.components[1].id = 2
                box.components[2].id = 3
            case 2:  // RGB
                box.components[0].id = UInt32(UInt8(ascii: "R"))
                box.components[1].id = UInt32(UInt8(ascii: "G"))
                box.components[2].id = UInt32(UInt8(ascii: "B"))
            case 3:  // Custom — read ids
                for i in 0..<Int(numComponents) {
                    box.components[i].id = try r.read(bits: 8)
                }
            default:
                break
            }
            // Per-component quant_idx (2 bits each).
            for i in 0..<Int(numComponents) {
                let qIdx = try r.read(bits: 2)
                if qIdx >= UInt32(box.quant.count) {
                    throw JBRDError.invalidQuantIndex(
                        comp: i, idx: qIdx)
                }
                box.components[i].quantIdx = qIdx
            }
            guard Set(box.components.map(\.id)).count == box.components.count,
                  box.components.contains(where: { $0.quantIdx == 0 }) else {
                throw JBRDError.malformed("Duplicate component or unused first quantisation table")
            }

            // 7. Huffman tables.
            //    num_huff: U32(Val(4), BitsOffset(3, 2), BitsOffset(4, 10),
            //                  BitsOffset(6, 26), default=4)
            let numHuff = try r.readU32((
                .literal(4),
                .offset(constant: 2, extraBits: 3),
                .offset(constant: 10, extraBits: 4),
                .offset(constant: 26, extraBits: 6)))
            try budget.reserve(Int(numHuff), stride: 4096)
            box.huffmanCode = Array(
                repeating: JBRDHuffmanCode(),
                count: Int(numHuff))
            for i in 0..<Int(numHuff) {
                let isAC = try r.readBit()
                let id = try r.read(bits: 2)
                let isLast = try r.readBit()
                var counts = [UInt32](repeating: 0, count: 17)
                var numSymbols = 0
                for k in 0...16 {
                    // U32(Val(0), Val(1), BitsOffset(3, 2), Bits(8),
                    //     default=0)
                    let v = try r.readU32((
                        .literal(0), .literal(1),
                        .offset(constant: 2, extraBits: 3),
                        .bits(8)))
                    counts[k] = v
                    numSymbols += Int(v)
                }
                if numSymbols < 1 {
                    throw JBRDError.malformed(
                        "empty Huffman table at huffman_code[\(i)]")
                }
                if numSymbols > 257 {
                    // kJpegHuffmanAlphabetSize+1 = 257 (256 plus EOI
                    // sentinel).
                    throw JBRDError.malformed(
                        "Huffman code too large at huffman_code[\(i)]"
                        + ": \(numSymbols)")
                }
                var values = [UInt32](repeating: 0, count: numSymbols)
                var valueSlots: [UInt64] = [0, 0, 0, 0, 0]
                for k in 0..<numSymbols {
                    // U32(Bits(2), BitsOffset(2, 4), BitsOffset(4, 8),
                    //     BitsOffset(8, 1), default=0)
                    let v = try r.readU32((
                        .bits(2),
                        .offset(constant: 4, extraBits: 2),
                        .offset(constant: 8, extraBits: 4),
                        .offset(constant: 1, extraBits: 8)))
                    values[k] = v
                    let slot = Int(v >> 6)
                    let bit = UInt64(1) << UInt64(v & 0x3F)
                    valueSlots[slot] |= bit
                }
                if values[numSymbols - 1] != 256 {
                    // libjxl kJpegHuffmanAlphabetSize = 256.
                    throw JBRDError.missingEOISymbol
                }
                // valueSlots[4] should have exactly bit 0 set (for
                // the EOI sentinel 256 itself).
                // Duplicate check.
                var distinctCount = 1   // EOI sentinel
                for s in 0..<4 {
                    distinctCount += valueSlots[s].nonzeroBitCount
                }
                if distinctCount != numSymbols {
                    throw JBRDError.duplicateHuffmanSymbols
                }
                if !isAC {
                    // DC range check: kJpegDCAlphabetSize = 12. The
                    // bits in valueSlots above 12 (in slot 0) and
                    // any bits in slots 1, 2, 3 indicate out-of-DC-
                    // range symbols.
                    let outOfRange = (valueSlots[0] >> 12)
                        | valueSlots[1]
                        | valueSlots[2]
                        | valueSlots[3]
                    if outOfRange != 0 {
                        throw JBRDError.dcHuffmanOutOfRange
                    }
                }
                guard counts[0] == 0, let last = counts.lastIndex(where: { $0 > 0 }), last > 0 else {
                    throw JBRDError.malformed("Invalid Huffman length counts")
                }
                var jpegCounts = counts.dropFirst().map(Int.init)
                jpegCounts[last - 1] -= 1 // remove the reconstruction sentinel
                _ = try JPEGHuffmanTable(counts: jpegCounts, symbols: values.dropLast().map { UInt8($0) })
                let slotId = (Int(isAC ? 1 : 0) << 4) | Int(id)
                box.huffmanCode[i] = JBRDHuffmanCode(
                    counts: counts, values: values,
                    slotId: slotId, isLast: isLast)
            }

            // 8. Per-scan info (Ss/Se/Ah/Al + per-component bindings).
            for i in 0..<box.scanInfo.count {
                try budget.policy.checkpoint()
                let numComps = try r.readU32((
                    .literal(1), .literal(2),
                    .literal(3), .literal(4)))
                if numComps >= 4 {
                    throw JBRDError.invalidScanComponentCount(
                        numComps)
                }
                let ss = try r.read(bits: 6)
                let se = try r.read(bits: 6)
                let al = try r.read(bits: 4)
                let ah = try r.read(bits: 4)
                var comps: [JBRDScanComponent] = []
                comps.reserveCapacity(Int(numComps))
                for _ in 0..<Int(numComps) {
                    let compIdx = try r.read(bits: 2)
                    let acIdx = try r.read(bits: 2)
                    let dcIdx = try r.read(bits: 2)
                    guard compIdx < numComponents, !comps.contains(where: { $0.compIdx == compIdx }) else {
                        throw JBRDError.malformed("Invalid or duplicate scan component")
                    }
                    comps.append(JBRDScanComponent(
                        compIdx: compIdx,
                        dcTblIdx: dcIdx, acTblIdx: acIdx))
                }
                // last_needed_pass — U32(Val(0), Val(1), Val(2),
                //   BitsOffset(3, 3), default=kMaxNumPasses-1=10)
                let lastNeededPass = try r.readU32((
                    .literal(0), .literal(1),
                    .literal(2),
                    .offset(constant: 3, extraBits: 3)))
                box.scanInfo[i] = JBRDScanInfo(
                    ss: ss, se: se, ah: ah, al: al,
                    numComponents: numComps,
                    components: comps,
                    lastNeededPass: lastNeededPass)
            }

            // 9. restart_interval (only if any marker was 0xDD).
            if info.hasDRI {
                box.restartInterval = try r.read(bits: 16)
            }

            // 10. Per-scan reset_points + extra_zero_runs (the
            //     bit-exact reconstruction extras).
            for i in 0..<box.scanInfo.count {
                try budget.policy.checkpoint()
                // num_reset_points: U32(Val(0), BitsOffset(2, 1),
                //   BitsOffset(4, 4), BitsOffset(16, 20), default=0)
                let numResetPoints = try r.readU32((
                    .literal(0),
                    .offset(constant: 1, extraBits: 2),
                    .offset(constant: 4, extraBits: 4),
                    .offset(constant: 20, extraBits: 16)))
                try budget.reserveEvents(Int(numResetPoints))
                var resetPoints: [UInt32] = []
                resetPoints.reserveCapacity(Int(numResetPoints))
                var lastBlockIdx: Int = -1
                for _ in 0..<Int(numResetPoints) {
                    try budget.policy.checkpoint()
                    // Block index encoded as delta from
                    // last_block_idx + 1.
                    let delta = try r.readU32((
                        .literal(0),
                        .offset(constant: 1, extraBits: 3),
                        .offset(constant: 9, extraBits: 5),
                        .offset(constant: 41, extraBits: 28)))
                    let wideIndex = UInt64(lastBlockIdx + 1) + UInt64(delta)
                    guard wideIndex < UInt64(3 << 26) else { throw JBRDError.malformed("Block index overflow") }
                    let blockIdx = UInt32(wideIndex)
                    if blockIdx >= (3 << 26) {
                        throw JBRDError.invalidBlockIndex(blockIdx)
                    }
                    resetPoints.append(blockIdx)
                    lastBlockIdx = Int(blockIdx)
                }
                box.scanInfo[i].resetPoints = resetPoints

                // num_extra_zero_runs: same distribution as
                // num_reset_points.
                let numEZR = try r.readU32((
                    .literal(0),
                    .offset(constant: 1, extraBits: 2),
                    .offset(constant: 4, extraBits: 4),
                    .offset(constant: 20, extraBits: 16)))
                try budget.reserveEvents(Int(numEZR))
                var extraZeroRuns: [JBRDExtraZeroRun] = []
                extraZeroRuns.reserveCapacity(Int(numEZR))
                lastBlockIdx = -1
                for _ in 0..<Int(numEZR) {
                    try budget.policy.checkpoint()
                    // num_extra_zero_runs: U32(Val(1),
                    //   BitsOffset(2, 2), BitsOffset(4, 5),
                    //   BitsOffset(8, 20), default=1)
                    let numEZRThis = try r.readU32((
                        .literal(1),
                        .offset(constant: 2, extraBits: 2),
                        .offset(constant: 5, extraBits: 4),
                        .offset(constant: 20, extraBits: 8)))
                    // Block-idx delta (same encoding as reset).
                    let delta = try r.readU32((
                        .literal(0),
                        .offset(constant: 1, extraBits: 3),
                        .offset(constant: 9, extraBits: 5),
                        .offset(constant: 41, extraBits: 28)))
                    let wideIndex = UInt64(lastBlockIdx + 1) + UInt64(delta)
                    guard wideIndex < UInt64(3 << 26) else { throw JBRDError.malformed("Block index overflow") }
                    let blockIdx = UInt32(wideIndex)
                    if blockIdx > (3 << 26) {
                        throw JBRDError.invalidBlockIndex(blockIdx)
                    }
                    guard numEZRThis <= 4 else { throw JBRDError.malformed("Too many extra zero runs") }
                    extraZeroRuns.append(JBRDExtraZeroRun(
                        blockIdx: blockIdx,
                        numExtraZeroRuns: numEZRThis))
                    lastBlockIdx = Int(blockIdx)
                }
                box.scanInfo[i].extraZeroRuns = extraZeroRuns
            }

            // 11. Inter-marker data sizes (16 bits each).
            var interMarkerSizes: [Int] = []
            for _ in 0..<info.numInterMarker {
                let s = try r.read(bits: 16)
                try budget.reservePayload(Int(s))
                interMarkerSizes.append(Int(s))
            }

            // 12. tail_data_len — U32(Val(0), BitsOffset(8, 1),
            //     BitsOffset(16, 257), BitsOffset(22, 65793), default=0)
            let tailDataLen = try r.readU32((
                .literal(0),
                .offset(constant: 1, extraBits: 8),
                .offset(constant: 257, extraBits: 16),
                .offset(constant: 65793, extraBits: 22)))
            if tailDataLen > 4_260_096 {
                throw JBRDError.tailDataTooLarge(tailDataLen)
            }

            // 13. has_zero_padding_bit + padding bits.
            box.hasZeroPaddingBit = try r.readBit()
            if box.hasZeroPaddingBit {
                let nbit = try r.read(bits: 24)
                // Sanity: 1024 is libjxl's reserve cap for the
                // padding bits vector; the actual encoded count
                // can be larger but a runaway nbit suggests
                // corrupted input.
                if r.bitsRemaining < Int(nbit) {
                    throw JBRDError.truncated
                }
                guard Int(nbit) <= budget.policy.maximumPaddingBits else { throw JBRDError.resourceLimit }
                try budget.reserve(Int(nbit), stride: 4)
                var padding: [UInt8] = []
                padding.reserveCapacity(Int(min(nbit, 1024)))
                for _ in 0..<Int(nbit) {
                    padding.append(try r.readBit() ? 1 : 0)
                }
                box.paddingBits = padding
            }

            // Apply postponed actions (libjxl `if (visitor->IsReading())`):
            //   tail_data has its size now, but its actual bytes are
            //   in the Brotli payload (not the Bundle). We carry the
            //   size only; the bytes get filled in once the Brotli
            //   decoder lands.
            try budget.reservePayload(Int(tailDataLen))
            box.tailData = Data(count: Int(tailDataLen))
            // Same for inter_marker_data — we allocate the sized
            // empty slots ready to be filled by the Brotli reader.
            box.interMarkerData = interMarkerSizes.map {
                Data(count: $0)
            }

            // 14. Validation cross-checks (libjxl jpeg_data.cc:378-415).
            //     For each DHT in marker_order, walk the huffman_code
            //     entries up to is_last; record which DC/AC slot ids
            //     have been defined. For each SOS, verify the
            //     referenced DC/AC tables are already defined.
            try validateMarkerOrderTablesPrecedeSOS(box: box, policy: budget.policy)
        } catch let e as BitstreamError {
            throw JBRDError.bitstream(e)
        }
        return box
    }

    /// libjxl `jpeg_data.cc:378-415` cross-check: for every SOS marker
    /// in `marker_order`, the DHT markers that precede it must define
    /// every DC + AC table the SOS references. Progressive frames
    /// (SOF2 = 0xC2) relax the DC check for spectral-non-zero scans
    /// and the AC check for DC-only scans.
    private static func validateMarkerOrderTablesPrecedeSOS(
        box: JBRDBox, policy: JBRDPolicy
    ) throws {
        var dhtIndex = 0
        var scanIndex = 0
        var isProgressive = false
        var frameCount = 0
        var coefficientHistory = box.components.map { _ in Array(repeating: -1, count: 64) }
        // 4 DC + 4 AC table slots.
        var dcOk = [Bool](repeating: false, count: 4)
        var acOk = [Bool](repeating: false, count: 4)
        for marker in box.markerOrder {
            try policy.checkpoint()
            if (0xc0...0xc2).contains(marker) {
                frameCount += 1
                guard frameCount == 1 else { throw JBRDError.malformed("Repeated frame marker") }
                isProgressive = marker == 0xc2
            } else if marker == 0xC4 {
                // DHT segment — consume Huffman codes until
                // is_last fires.
                guard dhtIndex < box.huffmanCode.count else { throw JBRDError.malformed("Missing DHT tables") }
                var terminated = false
                while dhtIndex < box.huffmanCode.count {
                    let hc = box.huffmanCode[dhtIndex]
                    dhtIndex += 1
                    let isAC = (hc.slotId & 0x10) != 0
                    let id = hc.slotId & 0x0F
                    if isAC {
                        acOk[id] = true
                    } else {
                        dcOk[id] = true
                    }
                    if hc.isLast { terminated = true; break }
                }
                guard terminated else { throw JBRDError.malformed("Unterminated DHT tables") }
            } else if marker == 0xDA {
                // SOS segment — verify referenced tables.
                guard scanIndex < box.scanInfo.count else { throw JBRDError.malformed("Missing scan") }
                let si = box.scanInfo[scanIndex]
                scanIndex += 1
                guard frameCount == 1, si.ss <= si.se, si.ah <= 13, si.al <= 13 else {
                    throw JBRDError.malformed("Invalid frame or scan fields")
                }
                if isProgressive {
                    guard (si.ss == 0 ? si.se == 0 : si.numComponents == 1),
                          si.ah == 0 || si.ah == si.al + 1 else { throw JBRDError.malformed("Progressive scan fields") }
                } else {
                    guard si.ss == 0, si.se == 63, si.ah == 0, si.al == 0 else {
                        throw JBRDError.malformed("Sequential scan fields")
                    }
                }
                for k in 0..<Int(si.numComponents) {
                    let csi = si.components[k]
                    let ci = Int(csi.compIdx)
                    if si.ss > 0 && coefficientHistory[ci][0] < 0 { throw JBRDError.malformed("AC before DC") }
                    for coefficient in Int(si.ss)...Int(si.se) {
                        guard coefficientHistory[ci][coefficient] == (si.ah == 0 ? -1 : Int(si.ah)) else {
                            throw JBRDError.malformed("Invalid progressive scan history")
                        }
                        coefficientHistory[ci][coefficient] = Int(si.al)
                    }
                    let dcId = Int(csi.dcTblIdx)
                    let acId = Int(csi.acTblIdx)
                    let wantDC = !isProgressive || (si.ss == 0 && si.ah == 0)
                    if wantDC && !dcOk[dcId] {
                        throw JBRDError.malformed(
                            "DC Huffman table \(dcId) used before "
                            + "defined (scan \(scanIndex-1))")
                    }
                    let wantAC = !isProgressive
                        || (si.ss != 0) || (si.se != 0)
                    if wantAC && !acOk[acId] {
                        throw JBRDError.malformed(
                            "AC Huffman table \(acId) used before "
                            + "defined (scan \(scanIndex-1))")
                    }
                }
            }
        }
        guard frameCount == 1, dhtIndex == box.huffmanCode.count, scanIndex == box.scanInfo.count,
              coefficientHistory.allSatisfy({ $0[0] >= 0 }) else {
            throw JBRDError.malformed("Incomplete frame, scan or Huffman mapping")
        }
    }
}

/// Internal — running counts derived from the marker_order walk.
/// Mirrors libjxl's anonymous `JPEGInfo` struct in jpeg_data.cc.
private struct JPEGInfo {
    var numAppMarkers: Int = 0
    var numComMarkers: Int = 0
    var numScans: Int = 0
    var numInterMarker: Int = 0
    var hasDRI: Bool = false
}

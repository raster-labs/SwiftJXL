// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

struct ModularGradientTests {
    private func tree(branching: Bool, raw: UInt32 = 5, offset: Int64 = 0, multiplier: UInt32 = 1) -> ModularTree {
        func leaf(_ id: Int) -> ModularTreeNode {
            .init(property:-1,splitVal:0,leftChildOrLeafId:id,rightChild:0,predictor:raw == 0 ? .zero : .gradient,
                  predictorOffset:offset,multiplier:multiplier,rawPredictor:raw)
        }
        if !branching { return .init(nodes:[leaf(0)]) }
        // Alternate equivalent leaves through a real property decision. Both
        // contexts map to one histogram, so only the decoder loop differs.
        return .init(nodes:[.init(property:2,splitVal:1,leftChildOrLeafId:1,rightChild:2,
            predictor:.zero,predictorOffset:0,multiplier:1),leaf(0),leaf(1)])
    }
    private func stream(_ residuals: [Int32], zeroBit: Bool = false) throws -> (Data, EntropySectionHeader, MultiClusterCodebook) {
        let header = EntropySectionHeader(lz77:.disabled,contextMap:.trivial(numContexts:2),
            usePrefixCode:true,logAlphaSize:15,uintConfigs:[.raw4])
        let table = try PrefixCodeTable(lengths:zeroBit ? [0] : [UInt8](repeating:6,count:64))
        let book = MultiClusterCodebook(huffmanTables:[table],ansCounts:[],alphabetSizes:[table.alphabetSize])
        let writer = TokenStreamWriter(header:header,codebook:book)
        var bits = BitWriter()
        for value in residuals { try writer.writeToken(context:0,value:ZigZag.pack(value),to:&bits) }
        return (bits.finishToData(),header,book)
    }
    private func decode(_ data: Data, header: EntropySectionHeader, book: MultiClusterCodebook,
                        width: Int, height: Int, branching: Bool, raw: UInt32 = 5, offset: Int64 = 0,
                        multiplier: UInt32 = 1, maximum: Int32? = nil) throws -> [Int32] {
        var reader=BitReader(data), tokens=TokenStreamReader(header:header,codebook:book)
        var values=[Int32](repeating:0,count:width*height)
        try decodeModularChannel(width:width,height:height,staticChannel:0,groupId:0,
            tree:tree(branching:branching,raw:raw,offset:offset,multiplier:multiplier),stream:&tokens,
            from:&reader,sampleMaximum:maximum,out:&values)
        try tokens.finish()
        return values
    }
    @Test(arguments:[1,2,7,513],[0,1,2,3])
    func specialisedAndBranchingTreesAgreeAtSignedExtremes(_ width:Int,_ variant:Int) throws {
        for predictor: UInt32 in [0,5] {
            let patterns:[Int32]=[.min,.max,0,-1,1,12345,-12345]
            let residuals=(0..<(width*3)).map { patterns[$0 % patterns.count] }
            let offsets:[Int64]=[0,7,Int64(Int32.max),Int64(Int32.min)]
            let multipliers:[UInt32]=[1,2,256,0x80000000]
            let (data,header,book)=try stream(residuals)
            let specialised=try decode(data,header:header,book:book,width:width,height:3,branching:false,raw:predictor,
                offset:offsets[variant],multiplier:multipliers[variant])
            let generic=try decode(data,header:header,book:book,width:width,height:3,branching:true,raw:predictor,
                offset:offsets[variant],multiplier:multipliers[variant])
            #expect(specialised == generic)
            #expect(specialised[0] == Int32(truncatingIfNeeded: offsets[variant] &+
                Int64(Int32(truncatingIfNeeded:Int64(Int32.min) &* Int64(multipliers[variant])))))
        }
    }
    @Test(arguments:[1,3,513],[0,1,2])
    func directStoragePreservesRowsCropsEndiannessAndGuards(_ width:Int,_ mode:Int) throws {
        for predictor: UInt32 in [0,5] {
            let height=3
            for bits in [8,16] { for little in [false,true] {
                let maximum: Int = (1 << bits) - 1
                let sampleCount: Int = width * height
                let expectedSamples: [Int32] = (0..<sampleCount).map { index -> Int32 in
                    let columnTerm: Int = index * 71
                    let rowTerm: Int = (index / width) * 37
                    let sample: Int = (columnTerm + rowTerm) & maximum
                    return Int32(sample)
                }
                var residuals:[Int32]=[]
                for y in 0..<height { for x in 0..<width {
                    let i=y*width+x
                    let w=x>0 ? expectedSamples[i-1] : y>0 ? expectedSamples[i-width] : 0
                    let n=y>0 ? expectedSamples[i-width] : w
                    let nw=x>0 && y>0 ? expectedSamples[i-width-1] : w
                    let gradient=min(max(w &+ n &- nw,min(w,n)),max(w,n))
                    residuals.append(expectedSamples[i] &- (predictor == 0 ? 0 : gradient))
                } }
                let (data,header,book)=try stream(residuals)
                let stride=bits/8+(mode==0 ? 0 : 2), layout:ModularChannelLayout
                if mode==2 {
                    let parent=try ModularChannelLayout(width:width+2,height:height+2,offset:8,
                        rowBytes:(width+2)*stride+8,pixelStride:stride,storageBits:bits,littleEndian:little)
                    layout=try parent.rectangle(x:1,y:1,width:width,height:height)
                } else {
                    layout=try ModularChannelLayout(width:width,height:height,offset:8,
                        rowBytes:width*stride+(mode==0 ? 0 : 8),pixelStride:stride,storageBits:bits,littleEndian:little)
                }
                var expected=[UInt8](repeating:0xa5,count:layout.requiredBytes+8)
                for i in expectedSamples.indices {
                    let p=layout.offset+(i/width)*layout.rowBytes+(i%width)*stride,v=expectedSamples[i]
                    expected[p]=UInt8(truncatingIfNeeded:bits==8 || little ? v : v>>8)
                    if bits==16 { expected[p+1]=UInt8(truncatingIfNeeded:little ? v>>8 : v) }
                }
                for branching in [false,true] {
                    var actual=[UInt8](repeating:0xa5,count:expected.count)
                    try actual.withUnsafeMutableBytes { raw in
                        var output=BorrowedModularChannel(bytes:raw,layout:layout)
                        var reader=BitReader(data),tokens=TokenStreamReader(header:header,codebook:book)
                        try decodeModularChannel(width:width,height:height,staticChannel:0,groupId:0,
                            tree:tree(branching:branching,raw:predictor),stream:&tokens,from:&reader,
                            sampleMaximum:Int32(maximum),out:&output)
                        try tokens.finish()
                    }
                    let exact=actual==expected;#expect(exact)
                }
            } }
        }
    }
    @Test(arguments:[false,true])
    func precisionAndTruncationRejectOnBothPaths(_ branching:Bool) throws {
        for predictor: UInt32 in [0,5] {
            for invalid:Int32 in [-1,256,65536] {
                let (data,h,b)=try stream([invalid])
                #expect(throws:BitstreamError.self) {
                    try decode(data,header:h,book:b,width:1,height:1,branching:branching,raw:predictor,
                               maximum:invalid==65536 ? 65535 : 255)
                }
            }
            let (data,h,b)=try stream([.min,.max,1,-1,65535,-65535])
            for length in 0..<data.count {
                func rejection(_ useBranch: Bool) -> String? {
                    do {
                        _ = try decode(Data(data.prefix(length)),header:h,book:b,width:3,height:2,branching:useBranch,raw:predictor)
                        return nil
                    } catch {
                        // Prefix decoding may expose PrefixCodeError directly;
                        // HybridUint failures carry the channel's position wrapper.
                        #expect(error is PrefixCodeError || error is ModularChannelDecoderError)
                        return String(reflecting: type(of: error)) + ":" + String(describing: error)
                    }
                }
                let actual = rejection(branching)
                #expect(actual != nil)
                #expect(actual == rejection(!branching))
            }
        }
    }
    private struct CancellingSamples:ModularSampleBuffer {
        var values:[Int32]
        var writes=0
        var count:Int { values.count }
        subscript(index:Int)->Int32 {
            get { values[index] }
            set { values[index]=newValue;writes+=1;if writes==1 { withUnsafeCurrentTask { $0?.cancel() } } }
        }
    }
    private func ansStream(_ residuals: [Int32]) throws -> (Data, EntropySectionHeader, MultiClusterCodebook) {
        let distribution = try ANSDistribution(rawFrequencies:
            [UInt32](repeating: 1, count: HybridUintConfig.raw4.maxToken + 1))
        var histBits = BitWriter()
        let wire = try SpecANSDistribution.writeHistogram(
            distribution.frequencies.map(Int32.init), to: &histBits)
        let header = EntropySectionHeader(
            lz77: .disabled,
            contextMap: try ContextMap(numClusters: 1, map: [0, 0]),
            usePrefixCode: false,
            logAlphaSize: max(5, Int(ceilLog2(UInt32(wire.count)))),
            uintConfigs: [.raw4]
        )
        let book = MultiClusterCodebook(huffmanTables: [], ansCounts: [wire], alphabetSizes: [wire.count])
        var writer = try ANSTokenStreamWriter(header: header, codebook: book)
        for value in residuals {
            try writer.writeToken(context: 0, value: ZigZag.pack(value))
        }
        var bits = BitWriter()
        try writer.finish(to: &bits)
        return (bits.finishToData(), header, book)
    }

    @Test
    func ansSingleLeafGradientPreservesSignedWrappingOnTransformedPlanes() throws {
        // M4-AUD-03 regression: on a 2x2 signed transformed plane (sampleMaximum == nil),
        // row 0 = [-1, 1] (NW = -1, N = 1) and row 1 col 0 = Int32.max (W = 2147483647)
        // with residual = 0 at (1, 1) must wrap W &+ N &- NW = -2147483647 and clamp
        // to min(W, N) = 1, matching the generic wrapping Int32 predictor.
        let counterexampleResiduals: [Int32] = [
            -1, // (0, 0): left=0 -> val = -1 (NW)
            2,  // (1, 0): left=-1 -> val = 1 (N)
            Int32(bitPattern: UInt32(Int32.max) &+ 1), // (0, 1): top=-1 -> val = Int32.max (W)
            0   // (1, 1): residual = 0 -> wrapping gradient clamps to 1
        ]
        let (data0, header0, book0) = try ansStream(counterexampleResiduals)
        let checkReader = TokenStreamReader(header: header0, codebook: book0)
        #expect(checkReader.canUseSingleContextANS(context: 0))
        let specialised0 = try decode(
            data0, header: header0, book: book0,
            width: 2, height: 2, branching: false, raw: 5,
            offset: 0, multiplier: 1, maximum: nil
        )
        let generic0 = try decode(
            data0, header: header0, book: book0,
            width: 2, height: 2, branching: true, raw: 5,
            offset: 0, multiplier: 1, maximum: nil
        )
        #expect(specialised0 == [-1, 1, .max, 1])
        #expect(specialised0 == generic0)

        // Also test negative wrapping boundary (W = Int32.min, N = -1, NW = 1, residual = 0 -> -1)
        // and multi-row signed extremes through the single-context ANS fast path.
        let negativeBoundaryResiduals: [Int32] = [
            1,  // (0, 0): val = 1 (NW)
            -2, // (1, 0): left=1 -> val = -1 (N)
            Int32.min &- 1, // (0, 1): top=1 -> val = Int32.min (W)
            0   // (1, 1): W &+ N &- NW = 2147483646 -> clamps to max(W, N) = -1
        ]
        let (data1, header1, book1) = try ansStream(negativeBoundaryResiduals)
        let specialised1 = try decode(
            data1, header: header1, book: book1,
            width: 2, height: 2, branching: false, raw: 5,
            offset: 0, multiplier: 1, maximum: nil
        )
        let generic1 = try decode(
            data1, header: header1, book: book1,
            width: 2, height: 2, branching: true, raw: 5,
            offset: 0, multiplier: 1, maximum: nil
        )
        #expect(specialised1 == [1, -1, .min, -1])
        #expect(specialised1 == generic1)

        let patterns: [Int32] = [.max, .min, 0, -1, 1, 0x3FFF_FFFF, -0x3FFF_FFFF, 65535, -65535]
        let multiResiduals = (0..<(17 * 5)).map { patterns[($0 * 7 + 3) % patterns.count] }
        let (data2, header2, book2) = try ansStream(multiResiduals)
        let specialised2 = try decode(
            data2, header: header2, book: book2,
            width: 17, height: 5, branching: false, raw: 5,
            offset: 0, multiplier: 1, maximum: nil
        )
        let generic2 = try decode(
            data2, header: header2, book: book2,
            width: 17, height: 5, branching: true, raw: 5,
            offset: 0, multiplier: 1, maximum: nil
        )
        #expect(specialised2 == generic2)
    }

    @Test(arguments: [Int32(255), Int32(65535), Int32(0x3FFF_FFFF)])
    func ansSingleLeafGradientUnitTransformShortcutMatchesReference(_ maxSample: Int32) throws {
        let width = 19, height = 4
        let anchors: [Int32] = [0, 1, maxSample / 2, maxSample - 1, maxSample]
        let expectedSamples: [Int32] = (0..<(width * height)).map { idx in
            anchors[(idx * 5 + idx / width * 3) % anchors.count]
        }
        var residuals: [Int32] = []
        residuals.reserveCapacity(expectedSamples.count)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let w: Int32 = x > 0 ? expectedSamples[i - 1] : (y > 0 ? expectedSamples[i - width] : 0)
                let n: Int32 = y > 0 ? expectedSamples[i - width] : w
                let nw: Int32 = (x > 0 && y > 0) ? expectedSamples[i - width - 1] : w
                let predicted = min(max(w &+ n &- nw, min(w, n)), max(w, n))
                residuals.append(expectedSamples[i] &- predicted)
            }
        }
        let (data, header, book) = try ansStream(residuals)
        let specialised = try decode(
            data, header: header, book: book,
            width: width, height: height, branching: false, raw: 5,
            offset: 0, multiplier: 1, maximum: maxSample
        )
        let generic = try decode(
            data, header: header, book: book,
            width: width, height: height, branching: true, raw: 5,
            offset: 0, multiplier: 1, maximum: maxSample
        )
        #expect(specialised == expectedSamples)
        #expect(specialised == generic)
    }

    @Test(arguments:[false,true])
    func zeroBitTokensStillObserveCancellationWithin256Writes(_ branching:Bool) async throws {
        for predictor: UInt32 in [0,5] {
            let (data,h,b)=try stream([0],zeroBit:true)
            let task=Task {
                var reader=BitReader(data),tokens=TokenStreamReader(header:h,codebook:b)
                var output=CancellingSamples(values:[Int32](repeating:0,count:1024))
                do {
                    try decodeModularChannel(width:1024,height:1,staticChannel:0,groupId:0,
                        tree:tree(branching:branching,raw:predictor),stream:&tokens,from:&reader,out:&output)
                    Issue.record("Cancelled channel completed")
                } catch is CancellationError {
                    #expect(output.writes>0 && output.writes<=256)
                }
            }
            try await task.value
        }
    }
}

// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Bounded compressed-only assembler for independently encoded full frames.
/// No source sample pointers or decoded pixels enter this value.
package struct AnimationCodestreamBuilder {
    private var writer: BitWriter
    private let metadata: ImageMetadata
    private let metadataSignature: Data
    private let width: Int, height: Int
    private let work: ScalarEncodingWork
    private var finished = false
    package var byteCount: Int { (writer.bitCount + 7) / 8 }

    package init(first: AnimationFrameIndex, ticksNumerator: UInt32, ticksDenominator: UInt32, loopCount: UInt32,
                 work: ScalarEncodingWork) throws {
        self.metadata = first.image.metadata; width = first.image.width; height = first.image.height
        metadataSignature = first.image.codestream.subdata(in: first.preludeRange)
        self.work = work
        writer = try ScalarEncodingWork.$current.withValue(work) {
            var w = BitWriter()
            w.write(bits: 8, value: 0xff); w.write(bits: 8, value: 0x0a)
            try SizeHeader(xsize: UInt32(first.image.width), ysize: UInt32(first.image.height)).write(to: &w)
            let m = first.image.metadata
            try ImageMetadata(allDefault: false, orientation: m.orientation,
                intrinsicSize: m.intrinsicSize, preview: nil, animation: .init(tpsNumerator: ticksNumerator, tpsDenominator: ticksDenominator, numLoops: loopCount, haveTimecodes: false),
                bitDepth: m.bitDepth, modular16BitBufferSufficient: m.modular16BitBufferSufficient,
                extraChannels: m.extraChannels, xybEncoded: m.xybEncoded, colorEncoding: m.colorEncoding,
                intensityTarget: m.intensityTarget, minNits: m.minNits,
                relativeToMaxDisplay: m.relativeToMaxDisplay, linearBelow: m.linearBelow).write(to: &w)
            w.writeBit(true); w.alignToByte()
            try work.checkpoint()
            return w
        }
    }
    package mutating func append(_ index: AnimationFrameIndex, duration: UInt32, isLast: Bool) throws {
        try work.checkpoint()
        guard !finished, duration > 0, index.animation == nil, index.frames.count == 1,
              index.image.width == width, index.image.height == height, index.image.codestream.subdata(in: index.preludeRange) == metadataSignature else {
            throw ScalarModularError.invalidInput("Animation frames have inconsistent metadata or geometry")
        }
        let entry = try index.frame(at: 0), f = entry.header
        guard !entry.toc.hasPermutation, !f.loopFilter.hasCustomParameters,
              f.loopFilter.allDefault || f.loopFilter.epfIters == 0 else { throw ScalarModularError.unsupportedProfile }
        try ScalarEncodingWork.$current.withValue(work) {
            let header = FrameHeader(allDefault: false, frameType: f.frameType, encoding: f.encoding,
                flags: f.flags, colorTransform: f.colorTransform, chromaSubsampling: f.chromaSubsampling,
                upsampling: f.upsampling, extraChannelUpsampling: f.extraChannelUpsampling,
                groupSizeShift: f.groupSizeShift, xQmScale: f.xQmScale, bQmScale: f.bQmScale,
                passes: f.passes, dcLevel: f.dcLevel, customSizeOrOrigin: false,
                frameOrigin: f.frameOrigin, frameSize: nil, blendingInfo: f.blendingInfo,
                extraChannelBlendingInfo: f.extraChannelBlendingInfo,
                animationFrame: AnimationFrame(duration: duration), isLast: isLast,
                saveAsReference: 0, saveBeforeColorTransform: f.saveBeforeColorTransform,
                name: f.name, loopFilter: f.loopFilter)
            try header.write(to: &writer, context: .init(xybEncoded: metadata.xybEncoded,
                numExtraChannels: metadata.extraChannels.count, haveAnimation: true))
            try entry.toc.write(to: &writer)
            writer.appendBytes(index.image.codestream.subdata(in: entry.payloadRange))
            try work.checkpoint()
        }
        finished = isLast
    }
    package mutating func finish() throws -> Data {
        guard finished else { throw ScalarModularError.invalidInput("Animation has no final frame") }
        let data = writer.finishToData()
        try work.checkpoint()
        return data
    }
}

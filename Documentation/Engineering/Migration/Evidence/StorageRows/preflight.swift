import Foundation
import SwiftJXL

var checkedSamples = 0
var checkedPadding = 0
for width in [64, 512, 2048] {
    let height = width - 1, rowBytes = width * 2 + 8
    let descriptor = try ImageDescriptor.greyscale16(width: width, height: height,
        meaningfulBits: 16, rowBytes: rowBytes)
    let destination = try ImageDestination.allocate(descriptor: descriptor)
    let identity = destination.storage.allocationID
    let image = try destination.writeUInt16 { x, y in UInt16((x + y * width) & 65535) }
    guard identity == image.storage.allocationID else {
        throw CodecError(.internalFailure, "Allocation identity changed")
    }
    try image.storage.withUnsafeBytes { bytes in
        for y in 0..<height {
            for x in 0..<width {
                let expected = UInt16((x + y * width) & 65535)
                let offset = y * rowBytes + x * 2
                guard bytes[offset] == UInt8(truncatingIfNeeded: expected),
                      bytes[offset + 1] == UInt8(truncatingIfNeeded: expected >> 8) else {
                    throw CodecError(.internalFailure, "Independent sample byte mismatch")
                }
                checkedSamples += 1
            }
            for offset in (y * rowBytes + width * 2)..<((y + 1) * rowBytes) {
                guard bytes[offset] == 0 else {
                    throw CodecError(.internalFailure, "Padding changed")
                }
                checkedPadding += 1
            }
        }
    }
}
print("Checked \(checkedSamples) exact samples and \(checkedPadding) padding bytes; allocation identity preserved.")

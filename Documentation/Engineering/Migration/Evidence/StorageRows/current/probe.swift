import Foundation
import SwiftJXL

func trial(_ width: Int) throws -> [String: Double] {
    let height = width - 1
    let descriptor = try SwiftJXL.ImageDescriptor.greyscale16(width: width, height: height,
        meaningfulBits: 16, rowBytes: width * 2 + 8)
    let start = DispatchTime.now().uptimeNanoseconds
    let destination = try SwiftJXL.ImageDestination.allocate(descriptor: descriptor)
    let allocated = DispatchTime.now().uptimeNanoseconds
    let image = try destination.writeUInt16 { x, y in UInt16((x + y * width) & 65535) }
    let written = DispatchTime.now().uptimeNanoseconds
    var sum: UInt64 = 0
    for y in 0..<height {
        for x in 0..<width { sum += UInt64(try image.sampleUInt16(x: x, y: y)) }
    }
    let read = DispatchTime.now().uptimeNanoseconds
    let count = UInt64(width * height)
    let cycles = count / 65536, remainder = count % 65536
    let expected = cycles * 65535 * 65536 / 2 + remainder * (remainder == 0 ? 0 : remainder - 1) / 2
    guard sum == expected else { throw SwiftJXL.CodecError(.internalFailure, "Benchmark sample mismatch") }
    return ["allocate_ns": Double(allocated-start), "write_ns": Double(written-allocated),
            "read_ns": Double(read-written), "checksum": Double(sum),
            "pixel_capacity": Double(descriptor.requiredByteCount),
            "thermal_state": Double(ProcessInfo.processInfo.thermalState.rawValue)]
}
while let line = readLine() {
    guard let width = Int(line), width > 1 && width <= 2048 else { break }
    let bytes = try JSONSerialization.data(withJSONObject: trial(width), options: [.sortedKeys])
    FileHandle.standardOutput.write(bytes + Data([10]))
}

import Foundation
import SwiftJXLCore
@main struct Probe {
 static func main() throws {
  let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
  let budget = try ScalarOperationBudget(retainedBytes: data.count, maximumWorkspaceBytes: 128*1024*1024, maximumMemoryBytes: 256*1024*1024, maximumDecodedBytes: 128*1024*1024, maximumCompressedBytes: 64*1024*1024, deadline: .now.advanced(by: .seconds(30)))
  let envelope = try VarDCTFrameEnvelope.read(data, budget: budget)
  let layouts = try (0..<3).map { try ModularChannelLayout(width: envelope.width, height: envelope.height, offset: $0*2, rowBytes: envelope.width*6, pixelStride: 6, storageBits: 16, littleEndian: true) }
  var decoded = Data(count: envelope.width*envelope.height*6)
  try decoded.withUnsafeMutableBytes { try VarDCTPixelDecoder.decode(envelope, into: $0, layouts: layouts) }
  try decoded.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
 }
}

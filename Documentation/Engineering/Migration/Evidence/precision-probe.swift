import Foundation
import JXLSwiftContract
let descriptor = try ImageDescriptor.greyscale16(width: 3, height: 2, meaningfulBits: 12, rowBytes: 8)
let image = try ImageDestination.allocate(descriptor: descriptor).writeUInt16 { x, y in UInt16((y * 3 + x) * 819) }
let codec = JXLContractCodec()
let (data, _) = try codec.encode(image)
let inspected = try codec.inspect(data)
let record: [String: Any] = ["source_meaningful_bits": image.descriptor.meaningfulBits, "encoded_meaningful_bits": inspected.meaningfulBits, "precision_preserved": inspected.meaningfulBits == 12]
let json = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
print(String(decoding: json, as: UTF8.self))
exit(inspected.meaningfulBits == 12 ? 0 : 1)

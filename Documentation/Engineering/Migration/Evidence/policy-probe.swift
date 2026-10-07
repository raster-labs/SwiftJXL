import Foundation
import JXLSwiftContract

let descriptor = try ImageDescriptor.greyscale16(width: 3, height: 2, meaningfulBits: 16, rowBytes: 8)
let image = try ImageDestination.allocate(descriptor: descriptor).writeUInt16 { x, y in UInt16((y * 3 + x) * 819) }
let codec = JXLContractCodec()
var results: [[String: Any]] = []
@MainActor func rejection(_ name: String, category: CodecError.Category, operation: () throws -> Void) {
    do {
        try operation()
        results.append(["case": name, "requirement_met": false, "observed": "operation succeeded", "expected": String(describing: category)])
    } catch let error as CodecError {
        results.append(["case": name, "requirement_met": error.category == category, "observed": String(describing: error.category), "expected": String(describing: category)])
    } catch {
        results.append(["case": name, "requirement_met": false, "observed": String(describing: error), "expected": String(describing: category)])
    }
}
rejection("encode workspace limited to one byte", category: .resourceLimitExceeded) {
    _ = try codec.encode(image, options: .init(resourceLimits: ResourceLimits(maximumWorkspaceBytes: 1)))
}
rejection("encode admission limited to one byte", category: .resourceLimitExceeded) {
    _ = try codec.encode(image, options: .init(resourceLimits: ResourceLimits(maximumMemoryBytes: 1)))
}
rejection("encode requires unavailable accelerated backend", category: .backendUnavailable) {
    _ = try codec.encode(image, options: .init(executionPolicy: .required(.accelerated)))
}
let (encoded, _) = try codec.encode(image)
rejection("decode workspace limited to one byte", category: .resourceLimitExceeded) {
    _ = try codec.decode(encoded, options: .init(resourceLimits: ResourceLimits(maximumWorkspaceBytes: 1)))
}
rejection("decode requires unavailable accelerated backend", category: .backendUnavailable) {
    _ = try codec.decode(encoded, options: .init(executionPolicy: .required(.accelerated)))
}
let metadataImage = try Image(descriptor: descriptor, storage: image.storage,
    metadata: ImageMetadata(entries: ["interpretation": Data([42])], requiredKeys: ["interpretation"]))
do {
    let (data, _) = try codec.encode(metadataImage)
    let (decoded, _) = try codec.decode(data)
    results.append(["case": "preserve required image metadata or reject", "requirement_met": decoded.metadata == metadataImage.metadata,
        "observed": decoded.metadata == metadataImage.metadata ? "preserved" : "required metadata lost"])
} catch let error as CodecError {
    results.append(["case": "preserve required image metadata or reject", "requirement_met": error.category == .unsupportedFeature,
        "observed": String(describing: error.category)])
}
let json = try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys, .prettyPrinted])
print(String(decoding: json, as: UTF8.self))
exit(results.allSatisfy { $0["requirement_met"] as? Bool == true } ? 0 : 1)

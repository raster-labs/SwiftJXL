// SPDX-License-Identifier: Apache-2.0
// Test-only ordinary-build telemetry. Compile with the package identity used by the linked module (recorded in build.json).
import Foundation
import Darwin
import SwiftJXL
import SwiftJXLCore

private func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw NSError(domain: message, code: 1) }
}
private func heap() -> Int {
    var value = malloc_statistics_t(); malloc_zone_statistics(nil, &value)
    return Int(value.size_in_use)
}
private func snapshot(_ audit: ScalarStorageAudit) -> [String: Int] {
    let s = audit.snapshot
    return ["finalPixelAllocations": s.finalPixelAllocations, "finalPixelBytes": s.finalPixelBytes,
            "workingPlaneAllocations": s.workingPlaneAllocations, "workingPlaneBytes": s.workingPlaneBytes]
}
private func sample(_ x: Int, _ y: Int, _ c: Int, _ bits: Int) -> Int {
    (x * 71 + y * 108 + c * 113) & ((1 << bits) - 1)
}
private func descriptor(_ width: Int, _ height: Int, _ channels: Int, _ bits: Int, padding: Int,
                        limits: ResourceLimits) throws -> ImageDescriptor {
    let roles: [ComponentRole] = (channels < 3 ? [.grey] : [.red, .green, .blue]) + (channels % 2 == 0 ? [.alpha] : [])
    let row = width * channels * 2 + padding
    let plane = try PlaneDescriptor(width: width, height: height, components: Array(roles.indices),
        sampleStride: 2, pixelStride: channels * 2, rowBytes: row, byteCount: row * height)
    return try ImageDescriptor(width: width, height: height, meaningfulBits: bits, components: roles,
        colour: channels < 3 ? .greyscale : .rgb, alpha: channels % 2 == 0 ? .straight : .absent,
        planes: [plane], limits: limits)
}
private func source(_ d: ImageDescriptor, sentinel: UInt8, limits: ResourceLimits) throws -> Image {
    try ImageDestination.allocate(descriptor: d, limits: limits).write { raw in
        raw.initializeMemory(as: UInt8.self, repeating: sentinel)
        for y in 0..<d.height { for x in 0..<d.width { for c in d.components.indices {
            let p = y * d.planes[0].rowBytes + (x * d.components.count + c) * 2
            let v = sample(x, y, c, d.meaningfulBits)
            raw[p] = UInt8(truncatingIfNeeded: v); raw[p+1] = UInt8(truncatingIfNeeded: v >> 8)
        } } }
    }
}
private func validate(_ image: Image, padding: UInt8 = 0) throws {
    let d = image.descriptor, channels = d.components.count, row = d.planes[0].rowBytes
    try image.storage.withUnsafeBytes { raw in
        for y in 0..<d.height {
            for x in 0..<d.width { for c in 0..<channels {
                let p = y * row + (x * channels + c) * 2
                try require(Int(raw[p]) | Int(raw[p+1]) << 8 == sample(x, y, c, d.meaningfulBits), "Sample differs")
            } }
            for p in (y * row + d.width * channels * 2)..<min((y+1) * row, raw.count) {
                try require(raw[p] == padding, "Padding differs")
            }
        }
    }
}
private final class CancellingProvider: WritableImageStorage {
    let owner: OwnedImageStorage
    init(_ count: Int, limits: ResourceLimits) throws { owner = try OwnedImageStorage(byteCount: count, limits: limits) }
    var byteCount: Int { owner.byteCount }; var allocationID: UUID { owner.allocationID }
    func reserveWrite() throws -> StorageWriteLease { try owner.reserveWrite() }
    func withUnsafeMutableBytes<R>(lease: StorageWriteLease, _ body: (UnsafeMutableRawBufferPointer) throws -> R) throws -> R {
        try owner.withUnsafeMutableBytes(lease: lease) { bytes in
            withUnsafeCurrentTask { $0?.cancel() }
            return try body(bytes)
        }
    }
    func finishAndSeal(lease: StorageWriteLease) throws -> any ReadOnlyImageStorage { try owner.finishAndSeal(lease: lease) }
    func abortAndInvalidate(lease: StorageWriteLease) throws { try owner.abortAndInvalidate(lease: lease) }
}
@main struct OwningMemoryProbe {
    static func main() async throws {
        guard CommandLine.arguments.count == 5,
              let w = Int(CommandLine.arguments[1]), let h = Int(CommandLine.arguments[2]),
              let c = Int(CommandLine.arguments[3]), let bits = Int(CommandLine.arguments[4]),
              (1...2048).contains(w), (1...2048).contains(h), [1,3,4].contains(c), [12,16].contains(bits)
        else { throw NSError(domain: "Arguments: width height channels bits", code: 1) }
        let limits = try ResourceLimits(maximumWorkspaceBytes: 1024 * 1024 * 1024,
            maximumWorkers: 1, deadlineSeconds: 120, maximumMemoryBytes: 1536 * 1024 * 1024)
        let encodeOptions = EncodeOptions(resourceLimits: limits), decodeOptions = DecodeOptions(resourceLimits: limits)
        let d = try descriptor(w,h,c,bits,padding:16,limits:limits)
        let input = try source(d, sentinel: 0xa5, limits: limits)
        let encoder = try Encoder(), decoder = try Decoder()
        let encodeAudit = ScalarStorageAudit()
        let encoded = try await ScalarStorageAudit.$current.withValue(encodeAudit) { try await encoder.encode(input, options: encodeOptions) }
        try require(encodeAudit.snapshot.finalPixelAllocations == 0 && encoded.report.copyEvents.isEmpty, "Encode handoff allocation")
        let changedPadding = try source(d, sentinel: 0x5a, limits: limits)
        try require(try await encoder.encode(changedPadding, options: encodeOptions).data == encoded.data, "Padding changed codestream")
        // Warm the specific allocating path, then observe retained heap while its result is alive.
        _ = try await decoder.decode(encoded.data, options: decodeOptions)
        let allocatingAudit = ScalarStorageAudit(), allocatedBefore = heap()
        let allocated = try await ScalarStorageAudit.$current.withValue(allocatingAudit) { try await decoder.decode(encoded.data, options: decodeOptions) }
        let allocatedAfter = heap()
        try validate(allocated.image)
        try require(allocatingAudit.snapshot.finalPixelAllocations == 1 && allocatingAudit.snapshot.finalPixelBytes == w*h*c*2, "Allocating decode allocation count")
        let destination = try ImageDestination.allocate(descriptor: d, limits: limits)
        let callerAudit = ScalarStorageAudit(), callerBefore = heap()
        let decoded = try await ScalarStorageAudit.$current.withValue(callerAudit) { try await decoder.decode(encoded.data, into: destination, options: decodeOptions) }
        let callerAfter = heap()
        try validate(decoded.image)
        try require(decoded.image.storage.allocationID == destination.storage.allocationID && callerAudit.snapshot.finalPixelAllocations == 0 && decoded.report.copyEvents.isEmpty, "Caller allocation replaced/copied")
        try require(try await encoder.encode(decoded.image, options: encodeOptions).data == encoded.data, "Padded reencode differs")
        do { _ = try destination.storage.reserveWrite(); throw NSError(domain: "Sealed destination reused", code: 2) }
        catch let error as CodecError { try require(error.category == .storageUnavailable, "Wrong sealed error") }
        // One operation-local core budget records cumulative reservations, not an allocator peak.
        let budget = try ScalarOperationBudget(retainedBytes: encoded.data.count,
            maximumWorkspaceBytes: limits.maximumWorkspaceBytes, maximumMemoryBytes: limits.maximumMemoryBytes,
            maximumDecodedBytes: limits.maximumDecodedBytes, maximumCompressedBytes: limits.maximumCompressedBytes,
            deadline: .now.advanced(by: .seconds(120)))
        let plan = try ModularFrameDecoder.prepare(encoded.data, budget: budget)
        let budgetDestination = try ImageDestination.allocate(descriptor: d, limits: limits)
        let layouts = try (0..<c).map { try ModularChannelLayout(width:w,height:h,offset:$0*2,rowBytes:d.planes[0].rowBytes,pixelStride:c*2,storageBits:16,littleEndian:true) }
        _ = try budgetDestination.write { try plan.decode(into:$0,layouts:layouts) }
        // Deliberately denied admission must leave the caller's reserved destination usable.
        let denied = try ImageDestination.allocate(descriptor:d,limits:limits), deniedAudit = ScalarStorageAudit()
        do {
            _ = try await ScalarStorageAudit.$current.withValue(deniedAudit) {
                try await decoder.decode(encoded.data, into:denied, options:.init(resourceLimits:try ResourceLimits(maximumWorkspaceBytes:1)))
            }
            throw NSError(domain:"Admission accepted",code:3)
        } catch let error as CodecError { try require(error.category == .resourceLimitExceeded,"Wrong admission error") }
        _ = try denied.write { $0.initializeMemory(as:UInt8.self,repeating:0) }
        try require(deniedAudit.snapshot.finalPixelAllocations == 0 && deniedAudit.snapshot.workingPlaneAllocations == 0,"Denied allocation")
        let provider = try CancellingProvider(d.requiredByteCount,limits:limits)
        let cancelled = try ImageDestination(descriptor:d,storage:provider,limits:limits)
        let task = Task { try await decoder.decode(encoded.data,into:cancelled,options:decodeOptions) }
        do { _ = try await task.value; throw NSError(domain:"Cancellation published",code:4) } catch is CancellationError {}
        do { _ = try provider.reserveWrite(); throw NSError(domain:"Cancelled destination reused",code:5) }
        catch let error as CodecError { try require(error.category == .storageUnavailable,"Wrong invalidation error") }
        var simultaneous = 0
        if w <= 513 {
            try await withThrowingTaskGroup(of:Int.self) { group in
                for _ in 0..<4 { group.addTask {
                    let audit = ScalarStorageAudit()
                    let result = try await ScalarStorageAudit.$current.withValue(audit) { try await encoder.encode(input,options:encodeOptions) }
                    try require(result.data == encoded.data && audit.snapshot.finalPixelAllocations == 0,"Concurrent source differs")
                    let output = try ImageDestination.allocate(descriptor:d,limits:limits)
                    let decoded = try await decoder.decode(result.data,into:output,options:decodeOptions)
                    try validate(decoded.image)
                    try require(decoded.image.storage.allocationID == output.storage.allocationID,"Concurrent identity differs")
                    return 1
                } }
                for try await result in group { simultaneous += result }
            }
        }
        let report: [String:Any] = ["dimensions":[w,h],"channels":c,"bits":bits,"passed":true,
            "encode":snapshot(encodeAudit),"allocatingDecode":snapshot(allocatingAudit),"callerDecode":snapshot(callerAudit),
            "allocatedHeapBefore":allocatedBefore,"allocatedHeapAfter":allocatedAfter,"callerHeapBefore":callerBefore,"callerHeapAfter":callerAfter,
            "compressedBytes":encoded.data.count,"callerCapacity":destination.storage.byteCount,
            "decodeCumulativeWorkspaceReservation":budget.reservedWorkspaceBytes,"concurrentOperations":simultaneous,
            "maximumWorkspaceBytes":limits.maximumWorkspaceBytes,"maximumMemoryBytes":limits.maximumMemoryBytes,
            "checks":["every sample","zeroed output padding","input padding independence","caller allocation identity","allocation-site counters","sealed rejection","admission before planes","cancellation invalidation"],
            "note":"Ordinary optimised build; allocation-site plane counters and before/after live process-heap observations. Neither workspace peak nor exact global allocation counts. Other host work active; no latency or comparative RSS claim."]
        print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
    }
}

// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization

public struct ImageMetadata: Sendable, Equatable {
    public let entries: [String: Data]
    public let requiredKeys: Set<String>
    public static let empty = Self()
    public init(entries: [String: Data] = [:], requiredKeys: Set<String> = []) {
        self.entries = entries; self.requiredKeys = requiredKeys
    }
    @discardableResult
    func validate(limits: ResourceLimits, additionalBytes: Int = 0) throws -> Int {
        guard requiredKeys.isSubset(of: Set(entries.keys)) else {
            throw CodecError(.invalidArgument, "Required metadata has no value.")
        }
        var count = additionalBytes
        guard count <= limits.maximumMetadataBytes else {
            throw CodecError(.resourceLimitExceeded, "Metadata limit exceeded.")
        }
        for (key, value) in entries {
            count = try checkedAdd(count, checkedAdd(key.utf8.count, value.count))
            guard count <= limits.maximumMetadataBytes else {
                throw CodecError(.resourceLimitExceeded, "Metadata limit exceeded.")
            }
        }
        return count
    }
}

public struct Image: Sendable {
    public let descriptor: ImageDescriptor
    public let storage: any ReadOnlyImageStorage
    public let metadata: ImageMetadata

    /// `storage` must be a sealed owner, not an escaped pointer or mutable view.
    /// External providers are responsible for making that guarantee across adapters.
    public init(descriptor: ImageDescriptor, storage: any ReadOnlyImageStorage,
                metadata: ImageMetadata = .empty, limits: ResourceLimits = .default) throws {
        guard storage.byteCount >= descriptor.requiredByteCount else {
            throw CodecError(.incompatibleImageLayout, "Storage is shorter than the descriptor capacity.")
        }
        try descriptor.validate(limits: limits)
        let metadataBytes = try metadata.validate(limits: limits, additionalBytes: descriptor.iccProfile?.count ?? 0)
        guard storage.byteCount <= limits.maximumDecodedBytes,
              try checkedAdd(storage.byteCount, metadataBytes) <= limits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "Image exceeds the admission budget.")
        }
        try storage.withUnsafeBytes { bytes in
            guard bytes.count >= descriptor.requiredByteCount, bytes.count == storage.byteCount else {
                throw CodecError(.storageUnavailable, "Provider returned inconsistent capacity.")
            }
        }
        self.descriptor = descriptor; self.storage = storage; self.metadata = metadata
    }

    /// A safe sample accessor for the required greyscale profile; never reads padding.
    public func sampleUInt16(x: Int, y: Int) throws -> UInt16 {
        try validateGreyscale16(descriptor)
        guard x >= 0, y >= 0, x < descriptor.width, y < descriptor.height else {
            throw CodecError(.invalidArgument, "Sample coordinates are outside the image.")
        }
        let plane = descriptor.planes[0]
        // Descriptor validation proves these coordinate calculations fit in Int.
        let offset = plane.offset + y * plane.rowBytes + x * plane.pixelStride
        return try storage.withUnsafeBytes { bytes in
            guard bytes.count >= descriptor.requiredByteCount else {
                throw CodecError(.storageUnavailable, "Provider returned insufficient capacity.")
            }
            // The immutable descriptor proves every valid coordinate's two-byte
            // extent lies within requiredByteCount. The borrow capacity check
            // above therefore covers both loads, including a shortened provider.
            // Byte access also permits an odd physical base address.
            let first = UInt16(bytes[offset]), second = UInt16(bytes[offset + 1])
            return descriptor.byteOrder == .littleEndian
                ? first | (second << 8) : (first << 8) | second
        }
    }
}

/// Reserves the provider on construction; abandoned destinations abort on release.
/// Only one write call is accepted. A thrown fill or cancellation invalidates the
/// destination, and a sealed image independently retains its immutable owner.
public final class ImageDestination: Sendable {
    public let descriptor: ImageDescriptor
    public let storage: any WritableImageStorage
    private let lease: StorageWriteLease
    private let limits: ResourceLimits
    private let started = Mutex(false)

    public init(descriptor: ImageDescriptor, storage: any WritableImageStorage,
                limits: ResourceLimits = .default) throws {
        try descriptor.validate(limits: limits)
        guard storage.byteCount <= limits.maximumDecodedBytes,
              try checkedAdd(storage.byteCount, descriptor.iccProfile?.count ?? 0) <= limits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "Destination exceeds the admission budget.")
        }
        guard storage.byteCount >= descriptor.requiredByteCount else {
            throw CodecError(.incompatibleImageLayout, "Destination storage is too short.")
        }
        self.descriptor = descriptor; self.storage = storage; self.limits = limits
        self.lease = try storage.reserveWrite()
    }
    deinit { try? storage.abortAndInvalidate(lease: lease) }

    public static func allocate(descriptor: ImageDescriptor, limits: ResourceLimits = .default) throws -> ImageDestination {
        try descriptor.validate(limits: limits)
        guard try checkedAdd(descriptor.requiredByteCount, descriptor.iccProfile?.count ?? 0) <= limits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "Destination exceeds the admission budget.")
        }
        let storage = try OwnedImageStorage(byteCount: descriptor.requiredByteCount, limits: limits)
        return try Self(descriptor: descriptor, storage: storage, limits: limits)
    }

    /// Advanced unsafe fill boundary. Initialise every sample before returning.
    /// The pointer must not escape or be used by asynchronous/concurrent work.
    /// Ordinary callers should prefer `writeUInt16`, which validates sample values.
    /// The caller controls cancellation/work bounds inside this synchronous closure.
    public func write(_ body: (UnsafeMutableRawBufferPointer) throws -> Void) throws -> Image {
        try write(metadata: .empty, beforeSeal: {}, body)
    }

    func write(metadata: ImageMetadata, beforeSeal: () throws -> Void,
               _ body: (UnsafeMutableRawBufferPointer) throws -> Void) throws -> Image {
        let accepted = started.withLock { value in
            guard !value else { return false }
            value = true
            return true
        }
        guard accepted else { throw CodecError(.storageUnavailable, "Destination was already used.") }
        do {
            try Task.checkCancellation()
            try storage.withUnsafeMutableBytes(lease: lease) { bytes in
                guard bytes.count == storage.byteCount, bytes.count >= descriptor.requiredByteCount else {
                    throw CodecError(.storageUnavailable, "Provider returned inconsistent capacity.")
                }
                try body(bytes)
            }
            try Task.checkCancellation()
            try beforeSeal()
            let sealed = try storage.finishAndSeal(lease: lease)
            let image = try Image(descriptor: descriptor, storage: sealed, metadata: metadata, limits: limits)
            // External providers may perform bounded finalisation or validation
            // work. Cancellation during either callback must prevent publication.
            try Task.checkCancellation()
            return image
        } catch {
            try? storage.abortAndInvalidate(lease: lease)
            throw error
        }
    }

    /// Synthetic sample initialisation; this is not compression or decompression.
    /// A row is the maximum cancellation interval for the provided scalar writer.
    public func writeUInt16(_ sample: (Int, Int) throws -> UInt16) throws -> Image {
        try validateGreyscale16(descriptor)
        let plane = descriptor.planes[0]
        let maximum = UInt32(1) << descriptor.meaningfulBits
        let width = descriptor.width, height = descriptor.height
        let littleEndian = descriptor.byteOrder == .littleEndian
        // Descriptor construction checked this arithmetic and proves that every
        // two-byte sample lies inside this positive, non-overlapping row extent.
        let rowPayload = (width - 1) * plane.pixelStride + MemoryLayout<UInt16>.size
        return try write { bytes in
            for y in 0..<height {
                try Task.checkCancellation()
                let rowOffset = plane.offset + y * plane.rowBytes
                guard rowOffset >= 0, rowOffset <= bytes.count - rowPayload else {
                    throw CodecError(.storageUnavailable, "Sample row lies outside the retained allocation.")
                }
                for x in 0..<width {
                    let value = try sample(x, y)
                    guard UInt32(value) < maximum else {
                        throw CodecError(.invalidArgument, "Sample exceeds declared meaningful precision.")
                    }
                    let offset = rowOffset + x * plane.pixelStride
                    let low = UInt8(truncatingIfNeeded: value)
                    let high = UInt8(truncatingIfNeeded: value >> 8)
                    // The row guard covers both bytes, including strided samples.
                    // Raw byte writes also initialise external sample storage.
                    bytes[offset] = littleEndian ? low : high
                    bytes[offset + 1] = littleEndian ? high : low
                }
            }
        }
    }
}

private func validateGreyscale16(_ descriptor: ImageDescriptor) throws {
    guard descriptor.sampleType == .unsignedInteger, descriptor.storageBits == 16,
          descriptor.components == [.grey], descriptor.planes.count == 1 else {
        throw CodecError(.unsupportedFeature, "Sample helper requires unsigned 16-bit greyscale.")
    }
}

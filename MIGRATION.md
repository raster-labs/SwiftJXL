# Migrating applications from JXLSwift to SwiftJXL

The successor requires Swift 6.2 or later, qualifies Swift 6.4, and has Apple OS 26 deployment floors. This guide describes the development migration branch under contract **0.10.0**, not a stable release.

**Keep JXLSwift in production.** The public lossless scalar API is now connected and independently tested for unsigned greyscale: encode 9–16 meaningful bits, dimensions up to 512 × 512; decode/inspect 8–16 bits, dimensions up to 1024 × 1024. Storage is one UInt16 plane, little/big endian, with explicit offset, row padding and pixel stride. Decoder input is capped at 4 MiB and must contain one last Modular frame/group, no transforms, ICC, animation, extra channels, orientation changes or ancillary boxes. These are initial feature bounds, not a full JPEG XL implementation.

Colour is D65 greyscale with sRGB transfer and default tone mapping. Relative rendering intent is implicit; other standard intents are preserved in required metadata key `jpegXL.renderingIntent`, one byte (0 perceptual, 1 relative, 2 saturation, 3 absolute). The encoder honours that key even with `discardAncillary`. Unsupported required metadata or ICC always rejects. Other ancillary entries reject by default and may be discarded only explicitly.

`Encoder.capabilities` and `Decoder.capabilities` advertise this profile. Native transcoding remains unavailable. CLI file commands remain reserved and its capability report remains false until command integration. No merge, release, production switch or downstream application edit is implied.

## Baseline and dependency changes

This mapping was checked against [JXLSwift at `760697a54dd253da8e8466c3fd09ecf2c2d89aec`](https://github.com/Raster-Lab/JXLSwift/tree/760697a54dd253da8e8466c3fd09ecf2c2d89aec). The historical `v1.4.0` tag is a separate reference; do not assume it resolves to that SHA. Record your application's actual `Package.resolved` revision and inventory differences before applying this guide. Source inspection is not an executed predecessor regression result.

| Application setting | Earlier dependency | Successor preparation |
| --- | --- | --- |
| Repository | `https://github.com/Raster-Lab/JXLSwift.git` | `https://github.com/Raster-Lab/SwiftJXL.git` |
| Package product / module | `JXLSwift` | `SwiftJXL` |
| Import | `import JXLSwift` | `import SwiftJXL` in the new adapter |
| SwiftPM target dependency | `.product(name: "JXLSwift", package: "JXLSwift")` | `.product(name: "SwiftJXL", package: "SwiftJXL")` |
| Compiler | Swift 6.2 manifest | Swift 6.2 minimum, Swift 6.4 qualification, Swift 6 language mode and complete concurrency checking |
| Apple deployment targets | macOS 13, iOS/tvOS 16, watchOS 9, visionOS 1 | All listed Apple OS minima are 26.0 |
| Executables | `jxl-tool`, `jxl` | `swiftjxl-cli` provides help/version/capabilities only |

Use a local checkout during preparation: add `.package(path: "../SwiftJXL")` to your development manifest and the successor product to the adapter target. Adjust the path for your checkout. For reproducible remote evaluation, use the successor URL with `revision:` set to an actual reviewed full commit SHA; record it and the lockfile. Do not write `from: "2.1.0"` before that release exists. In Xcode, add the local package and link its `SwiftJXL` product to the evaluation target; update deployment settings deliberately.

The [current manifest](Package.swift) exports the dependency-free `SwiftJXL` library and diagnostic `swiftjxl-cli` executable. The [predecessor manifest](https://github.com/Raster-Lab/JXLSwift/blob/760697a54dd253da8e8466c3fd09ecf2c2d89aec/Package.swift) also declares the two CLI products and a `JXLPerfC` development target; their codec/performance commands have no successor replacement today. Keep payload-processing scripts on the earlier tools; see [current diagnostic CLI support](CLI.md). CompressionFamily, a sibling codec and an umbrella package are not successor prerequisites. Linux is an intended qualification target; see [platform requirements and evidence limits](Documentation/PLATFORMS.md).

## API mapping: available surface versus deferred behaviour

The names below are migration targets, not source-compatible aliases or evidence of codec support.

| Earlier call or value | Current successor surface | Migration action / limit |
| --- | --- | --- |
| `ImageFrame` / `JXLImage` | `ImageDescriptor`, `ImageDestination`, immutable `Image` | Map precision, components, colour, alpha, ICC, byte order and strides explicitly; no direct array replacement. |
| `JXLEncoder(options:)` or `JXLEncoder(configuration:)` | `try SwiftJXL.Encoder(configuration:)` | Separate `EncoderConfiguration` from per-call `EncodeOptions`. |
| `EncodingOptions`, `JXLConfiguration` | `EncoderConfiguration(mode:codecOptions:)` | Only `.lossless` is implemented; `CodecOptions` has no controls yet. Quality/distance, effort, progressive output, filters, container and frame settings are deferred. |
| `encoder.encode(frame)` → old `EncodedImage` | `try await encoder.encode(image, options:)` → new `EncodedImage` | Encoding works for the bounded scalar greyscale profile. `.data` remains the byte payload; `.encoding` and `.report` replace old `.stats` usage. |
| `JXLDecoder().decode(data)` → `ImageFrame` | `try SwiftJXL.Decoder()` then `try await decoder.decode(data, options:)` → `DecodedImage` | Use result `.image` and `.report` for the bounded scalar greyscale profile. |
| `decoder.inspect(data)` → `JXLInspection` | `try decoder.inspect(data, options:)` → `ImageInfo` | Supported-profile headers and output layout are inspected; arbitrary box/frame inspection remains unsupported. |
| `decodeAll`, `decodeFrame`, `inspectFrames`, `countFrames`, frame-array encoding | No current replacement | Retain predecessor for animation/multi-frame workflows; do not silently keep only frame zero. |
| `encodeLosslessJPEG(jpeg)` | `try await transcoder.transcode(jpeg, to: .jpegXL)` | Planned reversible JPEG recompression; current stub rejects. |
| `decodeLosslessJPEG(jxl)` → JPEG `Data` | `try await transcoder.transcode(jxl, to: .jpeg)` → `EncodedImage` | Planned autonomous reconstruction; use `.data` when implemented. Current capabilities are empty. |
| `EncoderError`, `DecoderError` | `CodecError.category`; separate `CancellationError` | Map application errors by category, never diagnostic string matching. |

Sources: [old frame and alias](https://github.com/Raster-Lab/JXLSwift/blob/760697a54dd253da8e8466c3fd09ecf2c2d89aec/Sources/JXLSwift/Codec/ImageFrame.swift), [old options/results](https://github.com/Raster-Lab/JXLSwift/blob/760697a54dd253da8e8466c3fd09ecf2c2d89aec/Sources/JXLSwift/Codec/EncodingOptions.swift), [old decoder](https://github.com/Raster-Lab/JXLSwift/blob/760697a54dd253da8e8466c3fd09ecf2c2d89aec/Sources/JXLSwift/Codec/JXLDecoder.swift), [new API](Sources/SwiftJXL/CodecAPI.swift) and [new transcoder](Sources/SwiftJXL/Transcoding.swift).

The old `EncodingOptions()` defaults to `.lossy(quality: 90)` and `JXLConfiguration()` to `quality: 0.9, lossless: false`. The successor default is lossless. Preserve the application's explicitly chosen fidelity when preparing its configuration; there is no automatic numerical quality/distance mapping, and no current successor lossy operation.

## Compilable preparation example

This standalone program constructs 12-bit samples in padded 16-bit storage and verifies a real scalar JPEG XL round trip.

```swift
// SPDX-License-Identifier: Apache-2.0
import Foundation
import SwiftJXL

enum ConsumerFailure: Error { case unexpectedResult }

@main
struct ContractConsumer {
    static func main() async throws {
        // Plain import, public members only; no testable import or sibling package.
        let descriptor = try SwiftJXL.ImageDescriptor.greyscale16(
            width: 3, height: 2, meaningfulBits: 12, rowBytes: 8)
        let destination = try SwiftJXL.ImageDestination.allocate(descriptor: descriptor)
        let image = try destination.write { bytes in
            for y in 0..<2 {
                for x in 0..<3 {
                    let value = UInt16((y * 3 + x) * 819)
                    bytes[y * 8 + x * 2] = UInt8(truncatingIfNeeded: value)
                    bytes[y * 8 + x * 2 + 1] = UInt8(value >> 8)
                }
            }
        }
        let last = try image.storage.withUnsafeBytes { bytes in
            UInt16(bytes[12]) | UInt16(bytes[13]) << 8
        }
        guard last == 4095, image.descriptor.meaningfulBits == 12 else {
            throw ConsumerFailure.unexpectedResult
        }
        let encoder = try SwiftJXL.Encoder(configuration: .init())
        let encoded = try await encoder.encode(image)
        let decoder = try SwiftJXL.Decoder(configuration: .init())
        let decoded = try await decoder.decode(encoded.data)
        guard try decoded.image.sampleUInt16(x: 2, y: 1) == 4095,
              decoded.image.descriptor.meaningfulBits == 12 else {
            throw ConsumerFailure.unexpectedResult
        }
        let transcoder = try SwiftJXL.Transcoder(configuration: .init())
        do {
            _ = try await transcoder.transcode(Data(), to: .jpegXL, options: .init())
            throw ConsumerFailure.unexpectedResult
        } catch let error as SwiftJXL.CodecError {
            guard error.category == .unsupportedFeature else { throw error }
        }
        print("Public consumer passed: owning UInt16 samples and lossless scalar JPEG XL.")
    }
}
```

For an existing reproducible consumer, run `xcrun swift run --package-path Examples/ContractConsumer` from this repository with Xcode's toolchain selected. Run `bash Scripts/validate.sh` for the repository's contract checks. The example uses only the public product and verifies precision and samples. Empty input now reports malformed input.

## Samples, ownership and operation policy

- Earlier frames use mutable, tightly packed interleaved `[UInt8]`. The successor owns sealed storage with explicit planes and strides. Allocating and filling from a legacy array is an application copy: account for it and budget both allocations. It is not proof of shared-storage hand-off. Advanced providers must enforce the [exclusive lease lifecycle](Documentation/MEMORY_CONTRACT.md); a pointer from an array or `Data.withUnsafeBytes` cannot survive its borrow or cross `await`.
- Preserve `storageBits` separately from `meaningfulBits`: 12-in-16 is not 8-bit display output. Do not infer precision from observed maxima. Respect byte order, row padding, component order, alpha interpretation and ICC semantics. A valid descriptor does not mean that a codec supports that layout. There is no automatic mapping of old `ColorSpace` tags to a fully qualified successor colour pipeline.
- Old `.int16` encoding level-shifts samples to unsigned values; `decode(_:signedOutput:)` explicitly reverses it. JPEG XL does not thereby gain native signed sample semantics. Preserve the external interpretation contract and test -32768, -1, 0 and 32767; never relabel unsigned output as signed or infer a replacement from `SampleType.signedInteger`. Float and signed codec coverage remain deferred.
- Supply application-sized `ResourceLimits` to descriptors, storage and operations. Include compressed data, padded pixel capacity, metadata, workspace and concurrent jobs in admission decisions. Watch has a smaller default profile. The scalar API enforces aggregate reservations and monotonic deadlines. It uses one worker. Conservative workspace bounds are documented in `Documentation/Engineering/Migration/RESOURCE_ADMISSION.md`; measured peak fields remain unknown.
- The [old async overloads](https://github.com/Raster-Lab/JXLSwift/blob/760697a54dd253da8e8466c3fd09ecf2c2d89aec/Sources/JXLSwift/Codec/AsyncOverloads.swift) call synchronous implementations. Current successor async entry points use `@concurrent`; keep UI work on its actor, callbacks `@Sendable`, and propagate `CancellationError` without converting it to success or retrying automatically. The scalar implementation checks cancellation/deadlines between bounded work units; callbacks run serially outside storage borrows.
- Default `copyPolicy` is `.requireSharedStorage`; `.allowCopy` permits value-preserving conversion only. Required unavailable acceleration reports `.backendUnavailable`. Treat `.resourceLimitExceeded`, layout, storage, input and feature errors distinctly. Optional report measurements are unknown when `nil`, not zero.

## Reversible JPEG is a separate migration gate

Pixel-lossless JPEG XL preserves decoded sample values. Reversible existing-JPEG recompression must restore **every original JPEG byte from the JXL alone**. Decoding JPEG to RGB and losslessly encoding those pixels cannot establish this guarantee or recover pixels lost in the original lossy JPEG. Do not substitute a quality setting, an original-JPEG sidecar or a pixel fallback for reconstruction.

The [pinned predecessor methods, tests and limitations](TRANSCODING.md) identify 8-bit DCT bridge paths, noncanonical-padding/metadata gaps and Brotli restrictions requiring qualification. Neither general 16-bit image descriptors nor the separate JPEG pixel decoder prove 12/16-bit or SOF3 JPEG bitstream reconstruction. The successor currently implements neither direction. Its future reversible path must preserve required reconstruction metadata; `discardAncillary` is already rejected by the stub.

## Staged application rollout and handover checklist

1. Record the application's earlier revision, supported OS versions, codec settings, frame/metadata requirements, CLI usage and fixtures. Keep its working dependency and output readers available. Applications supporting older OS versions should retain a separate legacy target/product or maintenance build; an availability check alone does not lower SwiftJXL's package deployment floor.
2. Add a separate successor adapter/evaluation target. During coexistence, use module-qualified types such as `JXLSwift.ImageFrame` and `SwiftJXL.Image`; also qualify common names such as `EncodedImage` and `CompressionMode`. The modules and suite storage protocols are distinct types, not interchangeable through casts.
3. Compile the preparation example and application adapters on required targets. Capture exact revisions, compiler, commands, exit results and skipped gates. Keep feature routing explicitly on JXLSwift today; do not interpret every new-codec error as permission for silent fallback or fidelity changes.
4. After later milestones, require capabilities for each operation/profile, reproduce the predecessor baseline and independently decode successor output. Compare every logical sample for lossless pixels, precision/colour/alpha/ICC interpretation, multi-frame timing, and errors for corrupt inputs. Define lossy tolerances before comparison.
5. Separately gate JPEG reconstruction on byte length and SHA-256/every-byte equality, with reverse execution given only the JXL. Test metadata, unsupported profiles and both independent interoperability directions. Preserve existing JPEG/JXL files until their successor reader/reconstruction coverage is proven.
6. Measure copied bytes, peak memory, cancellation, concurrent ownership and latency in the application. Test rollback before switching production routing. Remove the old dependency only when every required feature, deployment target and retained asset passes; retain a reviewed earlier revision for rollback.

Coding agents must read [AGENTS.md](AGENTS.md), inspect actual application usage and report each required feature as implemented/tested, deferred or unsupported. This guide authorises no codec implementation or edits to downstream applications by itself. Do not delete unmapped features, weaken fidelity tests, fabricate release tags or claim complete migration from a successful build. Update this guide, the README and change log whenever a later milestone changes these mappings.

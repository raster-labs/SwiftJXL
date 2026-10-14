// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

struct ModularEffortLimitTests {
    private enum Unusable: Error { case candidate }
    private func context(workspace: Int = 1024 * 1024,
                         cancellation: ScalarOperationCancellation? = nil,
                         expired: Bool = false, workers: Int = 1) throws -> ScalarEncodingWork {
        let budget = try ScalarOperationBudget(retainedBytes: 0,
            maximumWorkspaceBytes: workspace, maximumMemoryBytes: 16 * 1024 * 1024,
            maximumDecodedBytes: 1024 * 1024, maximumCompressedBytes: 1024 * 1024,
            deadline: .now.advanced(by: .seconds(expired ? -1 : 120)),
            maximumWorkers: workers, cancellation: cancellation)
        return ScalarEncodingWork(budget: budget, writerByteLimit: 1024 * 1024)
    }

    @Test func unusableCandidateRemainsOptionalButPolicyErrorsEscape() throws {
        #expect(try ModularEffortWork.candidate { 42 } == 42)
        let absent: Int? = try ModularEffortWork.candidate { throw Unusable.candidate }
        #expect(absent == nil)
        #expect(throws: CancellationError.self) {
            let _: Int? = try ModularEffortWork.candidate { throw CancellationError() }
        }
        do {
            let _: Int? = try ModularEffortWork.candidate { throw ScalarModularError.resourceLimit }
            Issue.record("Candidate swallowed resource rejection")
        } catch ScalarModularError.resourceLimit {}
    }

    @Test(arguments: [false, true])
    func cancellationDuringCandidateCannotReturnSuccessOrSkip(_ unusable: Bool) throws {
        let cancellation = ScalarOperationCancellation()
        let work = try context(cancellation: cancellation)
        #expect(throws: CancellationError.self) {
            try ScalarEncodingWork.$current.withValue(work) {
                let _: Int? = try ModularEffortWork.candidate {
                    cancellation.cancel()
                    if unusable { throw Unusable.candidate }
                    return 42
                }
            }
        }
    }

    @Test(arguments: [false, true])
    func writerFailureDuringCandidateCannotReturnSuccessOrSkip(_ unusable: Bool) throws {
        let work = try context()
        do {
            try ScalarEncodingWork.$current.withValue(work) {
                let _: Int? = try ModularEffortWork.candidate {
                    work.rejectGrowth()
                    if unusable { throw Unusable.candidate }
                    return 42
                }
            }
            Issue.record("Candidate hid writer overflow")
        } catch ScalarModularError.resourceLimit {}
    }

    @Test func expiredCandidateDoesNotStart() throws {
        let work = try context(expired: true)
        var invoked = false
        do {
            try ScalarEncodingWork.$current.withValue(work) {
                let _: Int? = try ModularEffortWork.candidate { invoked = true; return 42 }
            }
            Issue.record("Expired candidate succeeded")
        } catch ScalarModularError.resourceLimit {}
        #expect(!invoked)
    }

    @Test(arguments: [false, true])
    func propertyAdmissionHonoursExactBoundaryAndAccumulates(_ tree: Bool) throws {
        let width = 17, height = 9, channels = 3
        let planes = [[Int32]](repeating: [Int32](repeating: 7, count: width * height), count: channels)
        let bytes = try ModularEffortWork.propertyWorkspace(width: width, height: height,
                                                           channels: channels, tree: tree)
        let expected = width * height * channels * (tree ? 72 : 16)
            + (width + 2) * channels * 96 + (channels + 3) * 256
        #expect(bytes == expected)
        let exact = try context(workspace: bytes)
        let result = try ScalarEncodingWork.$current.withValue(exact) {
            try SpecModularEncoder.wpGreedyPerPixel(width: width, height: height,
                channels: planes, postCfg: .raw4, includeTreeProperties: tree)
        }
        #expect(result.tokens.count == width * height * channels)
        #expect(exact.budget.reservedWorkspaceBytes == bytes)
        for work in [exact, try context(workspace: bytes - 1)] {
            do {
                _ = try ScalarEncodingWork.$current.withValue(work) {
                    try SpecModularEncoder.wpGreedyPerPixel(width: width, height: height,
                        channels: planes, postCfg: .raw4, includeTreeProperties: tree)
                }
                Issue.record("Property pass exceeded its cumulative workspace")
            } catch ScalarModularError.resourceLimit {}
        }
    }

    @Test func propertyDimensionsAndPlaneLengthsRejectWithoutAllocation() throws {
        #expect(throws: ScalarModularError.self) {
            try ModularEffortWork.propertyWorkspace(width: Int.max, height: 2, channels: 4, tree: true)
        }
        #expect(throws: ScalarModularError.self) {
            try ModularEffortWork.propertyWorkspace(width: 0, height: 2, channels: 4, tree: false)
        }
        #expect(throws: ScalarModularError.self) {
            try SpecModularEncoder.wpGreedyPerPixel(width: 3, height: 2,
                channels: [[0]], postCfg: .raw4, includeTreeProperties: false)
        }
    }

    @Test(arguments: [2, 8])
    func groupedCandidateAdmissionFailureMustNotFallBackToBaseline(_ workers: Int) throws {
        let width = 513, height = 17
        var pixels = [Int32]()
        pixels.reserveCapacity(width * height)
        for index in 0..<(width * height) {
            let row = index / width
            let value = index * 71 + row * 37
            pixels.append(Int32(value & 65535))
        }
        let baseline = try context(workers: workers)
        let data = try ScalarEncodingWork.$current.withValue(baseline) {
            try SpecModularEncoder.encodeGrayscale16(width: width, height: height,
                bitsPerSample: 16, pixelsInt32: pixels, effort: 3)
        }
        #expect(!data.isEmpty)
        let baselineSlots = baseline.budget.reservedWorkspaceBytes
        #expect(baselineSlots > 0)
        // Effort 7 reaches the same baseline first, then needs another worker
        // result reservation for its activity candidate. Exhaust precisely the
        // baseline allowance: a blanket try? would return a successful fallback.
        let denied = try context(workspace: baselineSlots, workers: workers)
        do {
            _ = try ScalarEncodingWork.$current.withValue(denied) {
                try SpecModularEncoder.encodeGrayscale16(width: width, height: height,
                    bitsPerSample: 16, pixelsInt32: pixels, effort: 7)
            }
            Issue.record("Activity candidate hid workspace rejection and published baseline")
        } catch ScalarModularError.resourceLimit {}
        #expect(denied.budget.reservedWorkspaceBytes == baselineSlots)
    }
}

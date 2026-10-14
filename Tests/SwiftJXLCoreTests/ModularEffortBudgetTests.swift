// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJXLCore

struct ModularEffortBudgetTests {
    private func context(workspace: Int = 1024 * 1024 * 1024,
                         memory: Int = 2 * 1024 * 1024 * 1024,
                         workers: Int = 1) throws -> ScalarEncodingWork {
        let budget = try ScalarOperationBudget(retainedBytes: 0,
            maximumWorkspaceBytes: workspace, maximumMemoryBytes: memory,
            maximumDecodedBytes: 1024 * 1024, maximumCompressedBytes: 1024 * 1024,
            deadline: .now.advanced(by: .seconds(120)), maximumWorkers: workers)
        return ScalarEncodingWork(budget: budget, writerByteLimit: 1024 * 1024)
    }

    @Test(arguments: [4, 8, 9], [1, 2, 8])
    func cumulativeAdmissionHonoursExactAndAggregateLimits(_ effort: Int, _ workers: Int) throws {
        for (width, channels) in [(31, 1), (31, 4), (513, 1), (513, 4)] {
            let height = 9
            var pixels = [Int32]()
            for i in 0..<(width * height) {
                let value = i * 71 + (i / width) * 37
                pixels.append(Int32(value & 65535))
            }
            func encode(_ work: ScalarEncodingWork) throws -> Data {
                _ = try work.budget.admitModularEncoder(width: width, height: height, channels: channels)
                return try ScalarEncodingWork.$current.withValue(work) {
                    if channels == 1 {
                        return try SpecModularEncoder.encodeGrayscale16(width: width, height: height,
                            bitsPerSample: 16, pixelsInt32: pixels, effort: effort)
                    }
                    let values = pixels.map(UInt16.init)
                    return try SpecModularEncoder.encodeRGBA16(width: width, height: height,
                        bitsPerSample: 16, r: values, g: values, b: values, a: values, effort: effort)
                }
            }
            let generous = try context(workers: workers)
            let data = try encode(generous)
            let bound = generous.budget.reservedWorkspaceBytes
            let exact = try context(workspace: bound, workers: workers)
            #expect(try encode(exact) == data)
            #expect(exact.budget.reservedWorkspaceBytes == bound)
            let denied = try context(workspace: bound - 1, workers: workers)
            do {
                _ = try encode(denied)
                Issue.record("Higher-effort work exceeded its cumulative allowance")
            } catch ScalarModularError.resourceLimit {}
            // Output and workspace share the same aggregate memory ceiling.
            let aggregate = try context(workspace: bound, memory: bound, workers: workers)
            do {
                _ = try encode(aggregate)
                Issue.record("Higher-effort work ignored retained output memory")
            } catch ScalarModularError.resourceLimit {}
        }
    }

    @Test func checkedComponentBoundsRejectOverflow() throws {
        #expect(throws: ScalarModularError.self) {
            try ModularEffortWork.collectionWorkspace(width: Int.max, height: 2,
                channels: 4, groups: 1)
        }
        #expect(throws: ScalarModularError.self) {
            try ModularEffortWork.collectionWorkspace(width: 1, height: 1,
                channels: 1, groups: Int.max)
        }
        #expect(throws: ScalarModularError.self) {
            try ModularEffortWork.learnerWorkspace(samples: 256_001, leaves: 32)
        }
        #expect(throws: ScalarModularError.self) {
            try ModularEffortWork.learnerWorkspace(samples: 1, leaves: Int.max)
        }
        let work = try context(workspace: 1)
        do {
            try ScalarEncodingWork.$current.withValue(work) {
                try ModularEffortWork.reserve(samples: Int.max, bytesPerSample: 2)
            }
            Issue.record("Overflowed reservation succeeded")
        } catch ScalarModularError.resourceLimit {}
        #expect(work.budget.reservedWorkspaceBytes == 0)
    }

    @Test func activitySortPreservesTiesAndStopsDuringBoundedWork() throws {
        let input = (0..<8192).map { (key: ($0 * 73) % 101, order: $0) }
        var sorted = input
        try ModularEffortWork.sort(&sorted, by: { $0.key < $1.key })
        #expect(sorted.map(\.order) == input.sorted { $0.key < $1.key }.map(\.order))
        for stop in [4, 13, 24] {
            var checks = 0
            sorted = input
            #expect(throws: CancellationError.self) {
                try ModularEffortWork.sort(&sorted, by: { $0.key < $1.key }) {
                    checks += 1
                    if checks == stop { throw CancellationError() }
                }
            }
            #expect(checks == stop)
        }
    }

    @Test(arguments: [0, 1, 1023, 1024, 1025, 4097, 8192], [0, 1, 2])
    func boundedSortMatchesStableReference(_ count: Int, _ pattern: Int) throws {
        let input = (0..<count).map { i in
            (key: pattern == 0 ? 0 : pattern == 1 ? count - i : (i * 73) % 101, order: i)
        }
        var sorted = input
        try ModularEffortWork.sort(&sorted, by: { $0.key < $1.key })
        #expect(sorted.map(\.order) == input.sorted { $0.key < $1.key }.map(\.order))
    }

    @Test(arguments: [false, true])
    func policyFailuresEscapeThroughoutLearning(_ greedy: Bool) throws {
        // Uneven equal-property runs cross the 1,024-sample work blocks.
        let count = 8201
        var properties = [Int32](), tokens = [Int]()
        var pairs = [(wpProp: Int32, token: UInt32)]()
        for i in 0..<count {
            let band = (i * 73) % 16
            properties.append(Int32(band))
            tokens.append(band / 2)
            pairs.append((Int32(band), UInt32(band / 2)))
        }
        func learn(checkpoint: () throws -> Void) throws {
            if greedy {
                let result = try SpecModularEncoder.greedyTreeAndContexts(
                    propsFlat: properties, tokBucket: tokens, pixelCount: count,
                    propIndices: [15], maxTok: 7, maxLeaves: 16, minGain: 1,
                    checkpoint: checkpoint)
                #expect(result != nil)
            } else {
                let result = try SpecModularEncoder.learnedThresholdSets(
                    pairs: pairs, postCfg: .raw4, maxDepth: 3, checkpoint: checkpoint)
                #expect(!result.isEmpty)
            }
        }
        var total = 0
        try learn { total += 1 }
        #expect(total > 20)
        for stop in [1, total / 4, total / 2, total - 1] {
            for cancel in [false, true] {
                var checks = 0
                do {
                    try learn {
                        checks += 1
                        if checks == stop {
                            if cancel { throw CancellationError() }
                            throw ScalarModularError.resourceLimit
                        }
                    }
                    Issue.record("Learner swallowed a mid-work policy failure")
                } catch is CancellationError { #expect(cancel) }
                  catch ScalarModularError.resourceLimit { #expect(!cancel) }
                #expect(checks == stop)
            }
        }
    }
}

// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Raster-Lab.
import Foundation

/// Admission and work limits for the internal scalar decode profile.
/// Workspace accounting remains separate; this is not a complete public budget.
package struct ScalarDecodePolicy: Sendable {
    package let maximumCompressedBytes: Int
    package let maximumPixels: Int
    package let maximumDimension: Int
    package let maximumNestingDepth: Int
    package let maximumEntropyTableBytes: Int
    package let deadline: ContinuousClock.Instant

    package init(maximumCompressedBytes: Int = 4 * 1024 * 1024,
                 maximumPixels: Int = 1024 * 1024, maximumDimension: Int = 1024,
                 maximumNestingDepth: Int = 32,
                 maximumEntropyTableBytes: Int = 32 * 1024 * 1024,
                 deadline: ContinuousClock.Instant = ContinuousClock.now.advanced(by: .seconds(10))) throws {
        guard maximumCompressedBytes > 0, maximumPixels > 0,
              maximumDimension > 0, maximumNestingDepth > 0, maximumEntropyTableBytes > 0 else {
            throw ScalarModularError.invalidInput("Decode limits must be positive")
        }
        self.maximumCompressedBytes = min(maximumCompressedBytes, 4 * 1024 * 1024)
        self.maximumPixels = min(maximumPixels, 1024 * 1024)
        self.maximumDimension = min(maximumDimension, 1024)
        self.maximumNestingDepth = min(maximumNestingDepth, 32)
        self.maximumEntropyTableBytes = min(maximumEntropyTableBytes, 32 * 1024 * 1024)
        self.deadline = deadline
    }

    package func checkpoint() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw ScalarModularError.resourceLimit }
    }
}

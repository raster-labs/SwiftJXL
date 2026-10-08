// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Raster-Lab.

/// Deterministic scalar execution while the migrated algorithms are qualified.
/// No raw pointer escapes a borrow and no undeclared worker pool is created.
/// Replaces predecessor Codec/ParallelMap.swift at 57e81cb9e2411d1efac435b429a306a031744c1e.
func parallelMap<T: Sendable>(_ count: Int, _ work: @Sendable (Int) throws -> T) rethrows -> [T] {
    try (0..<max(0, count)).map(work)
}

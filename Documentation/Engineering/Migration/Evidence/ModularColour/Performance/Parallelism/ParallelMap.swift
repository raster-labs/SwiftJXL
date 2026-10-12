// Test-only serial control for the pinned predecessor. No production edit.
package func parallelMap<T: Sendable>(_ count: Int, _ work: @Sendable (Int) -> T) -> [T] {
    (0..<count).map(work)
}

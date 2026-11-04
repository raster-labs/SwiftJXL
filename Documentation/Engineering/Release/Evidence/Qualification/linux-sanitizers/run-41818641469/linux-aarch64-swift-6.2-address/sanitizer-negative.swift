// Deliberate test-only use-after-free; never linked into SwiftJXL.
let owner = UnsafeMutablePointer<Int>.allocate(capacity: 1)
owner.initialize(to: 42)
owner.deinitialize(count: 1)
owner.deallocate()
print(owner.pointee)

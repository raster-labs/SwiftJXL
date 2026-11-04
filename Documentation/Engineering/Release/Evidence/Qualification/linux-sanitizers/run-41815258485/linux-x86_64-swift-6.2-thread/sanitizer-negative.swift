// Deliberate test-only race; never linked into SwiftJXL.
import Glibc
nonisolated(unsafe) var shared = 0
func writer(_: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
  for _ in 0..<10000 { shared += 1 }; return nil
}
var first = pthread_t(), second = pthread_t()
pthread_create(&first, nil, writer, nil)
pthread_create(&second, nil, writer, nil)
pthread_join(first, nil)
pthread_join(second, nil)
print(shared)

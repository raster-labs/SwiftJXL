import Glibc
// Test-only standalone control: each argv owner lives through posix_spawn,
// every spawned PID is reaped, and no process-global state is mutated.
struct SpawnFailure: Error { let operation: String; let code: Int32 }
func spawnAndJoin() throws {
    var pid: pid_t = 0
    guard let executable = strdup("/bin/true") else { throw SpawnFailure(operation: "strdup", code: ENOMEM) }
    defer { free(executable) }
    var arguments: [UnsafeMutablePointer<CChar>?] = [executable, nil]
    let launched = arguments.withUnsafeMutableBufferPointer { argv in
        posix_spawn(&pid, executable, nil, nil, argv.baseAddress!, environ)
    }
    guard launched == 0 else { throw SpawnFailure(operation: "spawn", code: launched) }
    var status: Int32 = 0
    var waited: pid_t
    repeat { waited = waitpid(pid, &status, 0) } while waited == -1 && errno == EINTR
    guard waited == pid && status == 0 else { throw SpawnFailure(operation: "wait", code: status) }
}
for _ in 0..<100 { try spawnAndJoin() }
print("posix-process-completed")

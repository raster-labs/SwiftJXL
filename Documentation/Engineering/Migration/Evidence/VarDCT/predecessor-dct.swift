import Foundation
import JXLSwift
struct Vector: Codable {
 let rows: Int; let cols: Int; let pattern: Int
 let input: [Float]; let forward: [Float]; let inverse: [Float]
 let scalarForward: [Float]; let scalarInverse: [Float]
}
@main struct Probe {
 static func main() throws {
  var results: [Vector] = []
  for (r,c) in [(2,2),(4,4),(8,8),(16,16),(32,32),(64,64),(4,8),(8,4),(8,16),(16,8),(16,32),(32,16)] {
   for pattern in 0..<3 {
    let input = (0..<(r*c)).map { i -> Float in
     if pattern == 0 { return i == 0 ? 0.75 : 0 }
     if pattern == 1 { return 0.25 }
     return Float((i * 71 + i / c * 37) % 257 - 128) / 128
    }
    var f=input, inv=input, sf=input, si=input
    AccelerateDCT.dct2D(&f, rows:r, cols:c)
    AccelerateDCT.idct2D(&inv, rows:r, cols:c)
    LibjxlDCT.dct2D(&sf, rows:r, cols:c)
    LibjxlIDCT.idct2D(&si, rows:r, cols:c)
    results.append(Vector(rows:r,cols:c,pattern:pattern,input:input,forward:f,inverse:inv,scalarForward:sf,scalarInverse:si))
   }
  }
  let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
  try encoder.encode(results).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
 }
}

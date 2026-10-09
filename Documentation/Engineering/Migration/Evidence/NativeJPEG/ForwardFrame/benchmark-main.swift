import Foundation
var rows: [[String: Any]] = []
for (name, directory) in [("gray", "JPEG"), ("progressive-edge", "JPEG"), ("quant16", "JPEGBridge"), ("multigroup-420", "JPEGBridge")] {
 let source = try Data(contentsOf: URL(fileURLWithPath: "Tests/SwiftJXLCoreTests/Fixtures/\(directory)/\(name).jpg"))
 let decoded = try JPEGCoefficientDecoder.decode(source, policy: JPEGCoefficientPolicy())
 let view = try JPEGBridgeCoefficients(frame: decoded.frame, coefficients: decoded.coefficients, quantisation: decoded.quantisation, policy: JPEGBridgePolicy(deadline: .now.advanced(by: .seconds(120))))
 let expected = try JPEGBridgeFrameWriter.write(view, policy: JPEGBridgePolicy())
 let iterations = name == "multigroup-420" ? 3 : 40
 for _ in 0..<3 { guard try JPEGBridgeFrameWriter.write(view, policy: JPEGBridgePolicy()) == expected else { throw JPEGEntropyError.malformed } }
 var samples: [Double] = []
 for _ in 0..<7 {
  let start = ContinuousClock.now
  for _ in 0..<iterations { guard try JPEGBridgeFrameWriter.write(view, policy: JPEGBridgePolicy()) == expected else { throw JPEGEntropyError.malformed } }
  let duration = start.duration(to: .now).components
  samples.append((Double(duration.seconds)*1e6+Double(duration.attoseconds)/1e12)/Double(iterations))
 }
 rows.append(["fixture":name,"codestreamBytes":expected.count,"sourceJPEGBytes":source.count,"warmups":3,"iterationsPerTrial":iterations,"medianMicroseconds":samples.sorted()[3],"samplesMicroseconds":samples])
}
print(String(decoding: try JSONSerialization.data(withJSONObject: ["scope":"Native coefficient-to-JXL frame writer with byte comparison; JPEG decoding and reconstruction metadata excluded", "trials":7, "fixtures":rows], options:[.prettyPrinted,.sortedKeys]), as: UTF8.self))

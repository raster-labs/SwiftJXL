import Foundation
import JXLSwift
@main struct Probe {
 static func main() async throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]);var results:[[String:String]]=[]
  for file in try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter({$0.lastPathComponent.hasSuffix(".independent.jxl")}).sorted(by:{$0.path<$1.path}) {
   var r=["name":file.lastPathComponent]
   do {let frame=try await JXLDecoder().decode(Data(contentsOf:file));try Data(frame.data).write(to:file.appendingPathExtension("decoded"));r["decode"]="accepted";r["bits"]=String(frame.pixelType.bitsPerSample);r["channels"]=String(frame.channels)}catch{r["decode"]="rejected: \(error)"}
   results.append(r)
  }
  let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys];try e.encode(results).write(to:root.appendingPathComponent("independent-predecessor-results.json"))
 }
}

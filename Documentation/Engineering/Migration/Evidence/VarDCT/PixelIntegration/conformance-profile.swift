import Foundation
@testable import SwiftJXLCore
@main struct Probe {
 static func main() throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]); var results:[[String:String]]=[]
  for dir in try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).sorted(by:{$0.path<$1.path}) {
   let input=dir.appendingPathComponent("input.jxl");guard FileManager.default.fileExists(atPath:input.path) else {continue}
   var record=["name":dir.lastPathComponent]
   do {
    let data=try Data(contentsOf:input)
    let budget=try ScalarOperationBudget(retainedBytes:data.count,maximumWorkspaceBytes:128*1024*1024,maximumMemoryBytes:256*1024*1024,maximumDecodedBytes:128*1024*1024,maximumCompressedBytes:64*1024*1024,deadline:.now.advanced(by:.seconds(10)))
    let stream:Data;switch try parseJXLContainer(data){case .naked:stream=data;case .iso(let boxes):stream=try extractCodestream(from:boxes,in:data)}
    var reader=BitReader(stream,startingAt:16,deadline:budget.deadline,budget:budget)
    let size=try SizeHeader.read(from:&reader), meta=try ImageMetadata.read(from:&reader)
    record["dimensions"]="\(size.xsize)x\(size.ysize)";record["metadata"]="bits=\(meta.bitDepth.bitsPerSample),xyb=\(meta.xybEncoded),ICC=\(meta.colorEncoding.useICC),space=\(meta.colorEncoding.colorSpace),transfer=\(meta.colorEncoding.transferFunction),orientation=\(meta.orientation),extras=\(meta.extraChannels.count),animation=\(meta.animation != nil),intensity=\(meta.intensityTarget)"
    let envelope=try VarDCTFrameEnvelope.read(data,budget:budget)
    record["envelope"]="accepted";record["frame"]="DCgroups=\(envelope.dcGroupsX)x\(envelope.dcGroupsY),passes=\(envelope.frame.passes.numPasses),gab=\(envelope.frame.loopFilter.gab),epf=\(envelope.frame.loopFilter.epfIters),flags=\(envelope.frame.flags),sections=\(envelope.sectionCount)"
   }catch{record["envelope"]="rejected: \(error)"}
   results.append(record)
  }
  let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];try encoder.encode(results).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
 }
}

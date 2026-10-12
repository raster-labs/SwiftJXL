import Foundation
@testable import SwiftJXLCore
@main struct Probe {
 static func budget(_ retained:Int=0)throws->ScalarOperationBudget {try ScalarOperationBudget(retainedBytes:retained,maximumWorkspaceBytes:256*1024*1024,maximumMemoryBytes:512*1024*1024,maximumDecodedBytes:128*1024*1024,maximumCompressedBytes:32*1024*1024,deadline:.now.advanced(by:.seconds(30)))}
 static func main()throws {
  let fixtures=URL(fileURLWithPath:CommandLine.arguments[1]),out=URL(fileURLWithPath:CommandLine.arguments[2]);try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true);var results:[[String:String]]=[]
  for width in [17,64,257] {for channels in [1,2,3,4] where width<257 || channels%2==1 {for bits in [8,16] {
   let height=width==64 ? 64:9,name="enc-\(width)-\(channels)-\(bits)",step=bits/8,maximum=(1<<bits)-1
   var record=["name":name,"width":String(width),"height":String(height),"channels":String(channels),"bits":String(bits)]
   do {
    let input:Data
    if width<257 {input=try Data(contentsOf:fixtures.appendingPathComponent("pred-\(width)-\(channels)-\(bits).input"))}
    else {var data=Data();for y in 0..<height {for x in 0..<width {for c in 0..<channels {let value=((x*19+y*37+c*11)%256)*maximum/255;data.append(UInt8(value&255));if step==2{data.append(UInt8(value>>8))}}}};input=data}
    let layouts=try (0..<channels).map {try ModularChannelLayout(width:width,height:height,offset:$0*step,rowBytes:width*channels*step,pixelStride:channels*step,storageBits:bits,littleEndian:true)}
    let operation=try budget(input.count)
    let encoded=try input.withUnsafeBytes {try VarDCTPixelEncoder.encode($0,layouts:layouts,bitsPerSample:bits,grayscale:channels<=2,alphaAssociated:channels%2==0 ? false:nil,distance:1,gaborish:true,adaptiveQuantisation:true,dcSmoothing:true,budget:operation)}
    try encoded.write(to:out.appendingPathComponent(name+".jxl"));try input.write(to:out.appendingPathComponent(name+".input"))
    record["encodedBytes"]=String(encoded.count);record["admittedWorkspaceBytes"]=String(operation.reservedWorkspaceBytes)
    let envelope=try VarDCTFrameEnvelope.read(encoded,budget:budget(encoded.count));var decoded=Data(count:input.count)
    try decoded.withUnsafeMutableBytes {try VarDCTPixelDecoder.decode(envelope,into:$0,layouts:layouts)}
    try decoded.write(to:out.appendingPathComponent(name+".decoded"));record["status"]="accepted"
   }catch{record["status"]="rejected: \(error)"}
   results.append(record)
  }}}
  let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys];try e.encode(results).write(to:out.appendingPathComponent("results.json"))
 }
}

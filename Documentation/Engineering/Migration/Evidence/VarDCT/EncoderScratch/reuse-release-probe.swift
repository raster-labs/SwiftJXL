import Foundation
import SwiftJXLCore
@main struct Probe {
 static func encode(_ input:Data,_ size:Int,_ channels:Int,_ mode:Int)throws->(Int,Int) {
  let layout=try (0..<channels).map {try ModularChannelLayout(width:size,height:size,offset:$0,rowBytes:size*channels,pixelStride:channels,storageBits:8,littleEndian:true)}
  let operation=try ScalarOperationBudget(retainedBytes:input.count,maximumWorkspaceBytes:512*1024*1024,maximumMemoryBytes:1024*1024*1024,maximumDecodedBytes:512*1024*1024,maximumCompressedBytes:128*1024*1024,deadline:.now.advanced(by:.seconds(120)))
  do {let data=try input.withUnsafeBytes {try VarDCTPixelEncoder.encode($0,layouts:layout,bitsPerSample:8,grayscale:channels<=2,alphaAssociated:channels%2==0 ? false:nil,distance:1,gaborish:true,adaptiveQuantisation:true,dcSmoothing:true,smallStrategySearch:mode>0,largeStrategySearch:mode==2,budget:operation)};return(data.count,operation.reservedWorkspaceBytes)}
  catch {print("rejected size=\(size) mode=\(mode) admitted=\(operation.reservedWorkspaceBytes) error=\(error)");throw error}
 }
 static func main()throws {
  let destination=URL(fileURLWithPath:CommandLine.arguments[1]);var results:[[String:String]]=[]
  if CommandLine.arguments[2]=="admission" {
   for size in [128,256,512] { for channels in [1,3] { for textured in [false,true] {
    let input=Data((0..<(size*size*channels)).map {UInt8(textured ? ((($0/channels)%size)*17+(($0/channels)/size)*13+($0%channels)*71)%256:127)})
    var r=["size":String(size),"textured":String(textured),"channels":String(channels)]
    do {let output=try encode(input,size,channels,2);r["status"]="accepted";r["compressedBytes"]=String(output.0);r["admittedWorkspaceBytes"]=String(output.1)}catch{r["status"]="rejected: \(error)"}
    results.append(r);try save(results,to:destination)
   }}}
  }else{
   let input=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2]))
   for _ in 0..<5 {for mode in 0..<3 {_ = try encode(input,64,4,mode)}}
   for repeatIndex in 0..<20 {for step in 0..<3 {
    let mode=(step+repeatIndex)%3,start=DispatchTime.now().uptimeNanoseconds
    let output=try encode(input,64,4,mode)
    let elapsed=DispatchTime.now().uptimeNanoseconds-start
    results.append(["mode":["fixedDCT8","singleCell","hierarchical"][mode],"iteration":String(repeatIndex),"nanoseconds":String(elapsed),"compressedBytes":String(output.0),"admittedWorkspaceBytes":String(output.1)])
   }}
   try save(results,to:destination)
  }
 }
 static func save(_ rows:[[String:String]],to url:URL)throws {let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys];try e.encode(rows).write(to:url)}
}

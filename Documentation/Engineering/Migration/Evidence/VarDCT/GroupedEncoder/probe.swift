// SPDX-License-Identifier: Apache-2.0
import Foundation
@testable import SwiftJXLCore
@main struct Probe {
 static func budget() throws -> ScalarOperationBudget {
  try ScalarOperationBudget(retainedBytes:0, maximumWorkspaceBytes:1024*1024*1024, maximumMemoryBytes:1536*1024*1024,
   maximumDecodedBytes:128*1024*1024, maximumCompressedBytes:32*1024*1024, deadline:.now.advanced(by:.seconds(120)))
 }
 static func main() throws {
  let out=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
  let cases=[(257,17,4,8,false),(17,257,2,16,false),(257,259,4,8,false),(2057,9,3,8,false),(9,2057,1,16,false),(2057,9,4,16,true),(4096,9,4,8,false),(9,4096,2,16,true),(257,9,2,8,false),(257,9,2,16,false),(257,9,4,8,false),(257,9,4,16,false)]
  var results:[[String:String]]=[]
  for (w,h,ch,bits,large) in cases {
   let zero = w == 257 && h == 9
   let name="\(zero ? "enczero" : "encgroup")-\(w)-\(h)-\(ch)-\(bits)-\(large ? 1:0)", step=bits/8
   var input=Data(count:w*h*ch*step)
   for y in 0..<h {for x in 0..<w {for c in 0..<ch {
    let value = zero ? 0 : ch%2 == 0 && c == ch-1 ? (x*17+y*31)%256 : (x/8+y/8+c*37)%256
    let sample=value*(bits==16 ? 257:1),i=((y*w+x)*ch+c)*step
    input[i]=UInt8(sample&255);if step==2 {input[i+1]=UInt8(sample>>8)}
   }}}
   let layouts=try (0..<ch).map {try ModularChannelLayout(width:w,height:h,offset:$0*step,rowBytes:w*ch*step,pixelStride:ch*step,storageBits:bits,littleEndian:true)}
   let encoded=try input.withUnsafeBytes {try VarDCTPixelEncoder.encode($0,layouts:layouts,bitsPerSample:bits,grayscale:ch<=2,alphaAssociated:ch%2==0 ? false:nil,distance:1,gaborish:large,adaptiveQuantisation:large,dcSmoothing:large,smallStrategySearch:large,largeStrategySearch:large,budget:budget())}
   try encoded.write(to:out.appendingPathComponent(name+".jxl"));try input.write(to:out.appendingPathComponent(name+".input"))
   let envelope=try VarDCTFrameEnvelope.read(encoded,budget:budget());var decoded=Data(count:input.count)
   try decoded.withUnsafeMutableBytes {try VarDCTPixelDecoder.decode(envelope,into:$0,layouts:layouts)}
   try decoded.write(to:out.appendingPathComponent(name+".decoded"))
   results.append(["name":name,"width":String(w),"height":String(h),"channels":String(ch),"bits":String(bits),"large":String(large),"status":"accepted"])
   print(name,encoded.count)
  }
  try JSONEncoder().encode(results).write(to:out.appendingPathComponent("results.json"))
 }
}

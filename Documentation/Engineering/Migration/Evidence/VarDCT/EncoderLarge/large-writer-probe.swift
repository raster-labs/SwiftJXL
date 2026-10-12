import Foundation
@testable import SwiftJXLCore
@main struct Probe {
 static func budget()throws->ScalarOperationBudget {try ScalarOperationBudget(retainedBytes:0,maximumWorkspaceBytes:256*1024*1024,maximumMemoryBytes:512*1024*1024,maximumDecodedBytes:128*1024*1024,maximumCompressedBytes:32*1024*1024,deadline:.now.advanced(by:.seconds(30)))}
 static func main()throws {
  let out=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true);var results:[[String:String]]=[]
  for id in [4,5,6,7,8,9,10,11,18,19,20] {
   let operation=try budget(), plan=try VarDCTLargeAnalysis(identifier:id,budget:operation)
   let width=plan.columns,height=plan.rows,bx=width/8,by=height/8,cells=bx*by,count=width*height,name="writer-\(id)",bits=16,channels=3
   let input=Data(count:count*6),layouts=try (0..<3).map {try ModularChannelLayout(width:width,height:height,offset:$0*2,rowBytes:width*6,pixelStride:6,storageBits:16,littleEndian:true)}
   let order=try VarDCTOrders.natural(width:max(bx,by),height:min(bx,by),budget:operation)
   var dc=[[Int32]](repeating:[Int32](repeating:0,count:cells),count:3),ac=[[Int32]](repeating:[Int32](repeating:0,count:count),count:3)
   for i in 0..<cells {dc[1][i]=Int32(360+3*(i%bx)+2*(i/bx))}
   for c in 0..<3 {for k in stride(from:cells,to:count,by:13) {ac[c][order[k]]=Int32((k+c)%7-3)}}
   let transform=VarDCTStrategyMap.Transform(identifier:id,x:0,y:0,cellsX:bx,cellsY:by,quantisation:5,coefficientOffset:0)
   let coefficients=VarDCTPixelEncoder.Coefficients(width:width,height:height,blocksX:bx,blocksY:by,bits:16,grayscale:false,hasAlpha:false,globalScale:5111,quantAC:[5],strategies:[Int32(id)],gaborish:false,dcSmoothing:false,dc:dc,ac:ac,transforms:[transform])
   let encoded=try input.withUnsafeBytes { bytes in try ScalarEncodingWork.$current.withValue(.init(budget:operation,writerByteLimit:1024*1024)) { try VarDCTFrameWriter(coefficients:coefficients,source:VarDCTBorrowedSource(bytes:bytes,layouts:layouts,maximum:65535),budget:operation,limit:1024*1024).write() }}
   try encoded.write(to:out.appendingPathComponent(name+".jxl"));try input.write(to:out.appendingPathComponent(name+".input"))
   let envelope=try VarDCTFrameEnvelope.read(encoded,budget:budget());var decoded=Data(count:input.count)
   try decoded.withUnsafeMutableBytes {try VarDCTPixelDecoder.decode(envelope,into:$0,layouts:layouts)}
   try decoded.write(to:out.appendingPathComponent(name+".decoded"))
   results.append(["name":name,"width":String(width),"height":String(height),"bits":String(bits),"channels":String(channels),"status":"accepted","strategy":String(id)])
  }
  try JSONEncoder().encode(results).write(to:out.appendingPathComponent("results.json"))
 }
}

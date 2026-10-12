import Foundation
@testable import SwiftJXLCore
@main struct Probe {
 static func floatInverse(_ x:Float,_ y:Float,_ b:Float)->(R:Double,G:Double,B:Double) {
  let bias:Float=0.0037930732552754493, root:Float=0.1559542005492486184
  let l=y+x+root,m=y-x+root,n=b+root
  let ll=(-bias).addingProduct(l*l,l),mm=(-bias).addingProduct(m*m,m),nn=(-bias).addingProduct(n*n,n)
  let r=(Float(11.031566901960783)*ll).addingProduct(-9.866943921568629,mm).addingProduct(-0.16462299647058826,nn)
  let g=(Float(-3.254147380392157)*ll).addingProduct(4.418770392156863,mm).addingProduct(-0.16462299647058826,nn)
  let bb=(Float(-3.6588512862745097)*ll).addingProduct(2.7129230470588235,mm).addingProduct(1.9459282392156863,nn)
  return(Double(r),Double(g),Double(bb))
 }
 static func main() throws {
  let input=URL(fileURLWithPath:CommandLine.arguments[1]), output=URL(fileURLWithPath:CommandLine.arguments[2])
  try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
  var results:[[String:String]]=[]
  for file in try FileManager.default.contentsOfDirectory(at:input,includingPropertiesForKeys:nil).filter({$0.pathExtension=="jxl"}).sorted(by:{$0.path<$1.path}) {
   let name=file.deletingPathExtension().lastPathComponent
   var record=["name":name]
   do {
    let data=try Data(contentsOf:file)
    let budget=try ScalarOperationBudget(retainedBytes:data.count,maximumWorkspaceBytes:128*1024*1024,maximumMemoryBytes:256*1024*1024,maximumDecodedBytes:128*1024*1024,maximumCompressedBytes:64*1024*1024,deadline:.now.advanced(by:.seconds(30)))
    let envelope=try VarDCTFrameEnvelope.read(data,budget:budget)
    record["stage"]="envelope";record["filters"]="gab=\(envelope.frame.loopFilter.gab),epf=\(envelope.frame.loopFilter.epfIters),flags=\(envelope.frame.flags)"
    let coefficients=try VarDCTCoefficients.read(envelope)
    record["stage"]="coefficients";record["sharpness"]=String(describing:Set(coefficients.sharpness));record["quant"]=String(describing:[coefficients.globalScale,coefficients.quantDC,UInt32(coefficients.dcExtraPrecision)])
    let planes=try VarDCTReconstruction.xyb(coefficients)
    var floating=Data(); for plane in planes { for sample in plane { var bits=sample.bitPattern.littleEndian; withUnsafeBytes(of:&bits){floating.append(contentsOf:$0)} } }; try floating.write(to:output.appendingPathComponent(name+".xyb"))
    let gray=envelope.metadata.colorEncoding.colorSpace == .grayscale
    let channels=(gray ? 1:3)+(coefficients.alpha == nil ? 0:1)
    let bits=Int(envelope.metadata.bitDepth.bitsPerSample), maximum=(1<<bits)-1, step=bits<=8 ? 1:2
    record["width"]=String(envelope.width);record["height"]=String(envelope.height);record["bits"]=String(bits);record["channels"]=String(channels)
    var pixels=Data();pixels.reserveCapacity(envelope.width*envelope.height*channels*step)
    func append(_ value:Int) {pixels.append(UInt8(value&255));if step==2{pixels.append(UInt8(value>>8))}}
    for i in planes[0].indices {
     let rgb=try CommandLine.arguments.count>3 ? floatInverse(planes[0][i],planes[1][i],planes[2][i]):DefaultOpsin.inverse((X:Double(planes[0][i]),Y:Double(planes[1][i]),B:Double(planes[2][i])))
     for value in (gray ? [rgb.R]:[rgb.R,rgb.G,rgb.B]) {
      let linear=min(1,max(0,value));let srgb=linear<=0.0031308 ? linear*12.92:1.055*pow(linear,1/2.4)-0.055
      append(min(maximum,max(0,Int((srgb*Double(maximum)).rounded()))))
     }
     if let alpha=coefficients.alpha {append(Int(alpha[i]))}
    }
    try pixels.write(to:output.appendingPathComponent(name+".decoded"));try data.write(to:output.appendingPathComponent(name+".jxl"))
    record["decode"]="accepted";record["stage"]="pixels";record["admittedWorkspaceBytes"]=String(budget.reservedWorkspaceBytes)
   }catch{record["decode"]="rejected: \(error)"}
   results.append(record)
  }
  let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys];try e.encode(results).write(to:output.appendingPathComponent("results.json"))
 }
}

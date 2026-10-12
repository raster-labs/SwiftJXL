import Foundation
import JXLSwift
@main struct Probe {
 static func main() async throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  var results:[[String:String]]=[]
  for channels in [1,2,3,4] { for bits in [8,16] { for width in [17,64] {
   let height=width == 17 ? 9:64, name="pred-\(width)-\(channels)-\(bits)"
   var frame=ImageFrame(width:width,height:height,channels:channels,pixelType:bits == 8 ? .uint8:.uint16,colorSpace:channels<3 ? .grayscale:.sRGB,alphaChannels:channels%2 == 0 ? 1:0)
   for y in 0..<height { for x in 0..<width { for c in 0..<channels {
    let value = (x*17+y*23+c*71)%256
    frame.setPixel(x:x,y:y,channel:c,value:UInt16(bits == 8 ? value:value*257))
   } } }
   var record=["name":name,"channels":String(channels),"bits":String(bits),"width":String(width),"height":String(height)]
   try Data(frame.data).write(to:root.appendingPathComponent(name+".input"))
   do {
    let encoded=try await JXLEncoder(options:EncodingOptions(mode:.distance(1),effort:.falcon,containerWrap:false,gaborish:false)).encode(frame)
    try encoded.data.write(to:root.appendingPathComponent(name+".jxl")); record["encode"]="accepted"; record["bytes"]=String(encoded.data.count)
    do { let decoded=try await JXLDecoder().decode(encoded.data); try Data(decoded.data).write(to:root.appendingPathComponent(name+".decoded")); record["decode"]="accepted";record["decodedBits"]=String(decoded.pixelType.bitsPerSample);record["decodedChannels"]=String(decoded.channels) }
    catch {record["decode"]="rejected: \(error)"}
   } catch {record["encode"]="rejected: \(error)"}
   results.append(record)
  } } }
  let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys];try e.encode(results).write(to:root.appendingPathComponent("results.json"))
 }
}

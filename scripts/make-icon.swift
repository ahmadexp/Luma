import AppKit

let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
let source = NSImage(contentsOf:root.appendingPathComponent("build/checks/overview.png"))!
let directory = root.appendingPathComponent("build/AppIcon.iconset")
try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
for base in [16,32,128,256,512] {
    for scale in [1,2] {
        let size = base * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
        let factor = Double(size)/1024
        let rect = NSRect(x:54*factor,y:54*factor,width:916*factor,height:916*factor)
        let shape = NSBezierPath(roundedRect:rect,xRadius:205*factor,yRadius:205*factor)
        NSColor(red:0.065,green:0.064,blue:0.18,alpha:1).setFill()
        shape.fill()
        shape.addClip()
        source.draw(in:NSRect(x:-8*factor,y:111*factor,width:1040*factor,height:780*factor),from:.zero,operation:.sourceOver,fraction:1)
        NSColor(red:0.50,green:0.82,blue:0.97,alpha:0.45).setStroke()
        shape.lineWidth = 3*factor
        shape.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent(filename))
    }
}

// Modern ICNS entries may contain PNG data directly.
let entries = [("icp4","icon_16x16.png"),("icp5","icon_32x32.png"),("icp6","icon_32x32@2x.png"),("ic07","icon_128x128.png"),("ic08","icon_256x256.png"),("ic09","icon_512x512.png"),("ic10","icon_512x512@2x.png")]
func bigEndianLength(_ count: Int) -> Data {
    var value = UInt32(count).bigEndian
    return withUnsafeBytes(of:&value) { Data($0) }
}
var body = Data()
for (tag,filename) in entries {
    let png = try Data(contentsOf:directory.appendingPathComponent(filename))
    body.append(Data(tag.utf8)); body.append(bigEndianLength(png.count+8)); body.append(png)
}
var icon = Data("icns".utf8)
icon.append(bigEndianLength(body.count+8)); icon.append(body)
try icon.write(to:root.appendingPathComponent("Resources/AppIcon.icns"))

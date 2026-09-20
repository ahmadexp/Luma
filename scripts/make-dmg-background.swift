import AppKit

let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:640,pixelsHigh:400,
    bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,
    bytesPerRow:0,bitsPerPixel:0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
let bounds = NSRect(x:0,y:0,width:640,height:400)
NSGradient(starting:NSColor(srgbRed:0.91,green:0.97,blue:0.98,alpha:1),
    ending:NSColor(srgbRed:0.98,green:0.98,blue:1,alpha:1))!.draw(in:bounds,angle:90)

func label(_ text:String, y:CGFloat, size:CGFloat, weight:NSFont.Weight = .regular,
           color:NSColor = NSColor(srgbRed:0.13,green:0.19,blue:0.25,alpha:1)) {
    let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
    (text as NSString).draw(in:NSRect(x:30,y:y,width:580,height:40),withAttributes:[
        .font:NSFont.systemFont(ofSize:size,weight:weight),.foregroundColor:color,.paragraphStyle:paragraph
    ])
}
label("LUMA",y:321,size:30,weight:.semibold)
label("A world within.",y:295,size:14)
let arrow = NSBezierPath()
arrow.move(to:NSPoint(x:285,y:215)); arrow.line(to:NSPoint(x:350,y:215))
arrow.move(to:NSPoint(x:338,y:227)); arrow.line(to:NSPoint(x:350,y:215)); arrow.line(to:NSPoint(x:338,y:203))
arrow.lineWidth = 3; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
NSColor(srgbRed:0.1,green:0.57,blue:0.59,alpha:1).setStroke(); arrow.stroke()
label("Drag Luma to Applications",y:70,size:18,weight:.medium)
label("Apple silicon · macOS 26 or later",y:41,size:12)
label("Created by Ahmad Byagowi",y:8,size:12)
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))

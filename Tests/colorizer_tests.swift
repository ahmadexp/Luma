import AppKit

@main
struct ColorizerTests {
    static func bytes(_ samples: [Float], _ width: Int, _ height: Int,
                      palette: FractalPalette = .aurora, phase: Double = 0,
                      density: Double = 1, relief: Double = 0,
                      mapping: FractalColorizer.Mapping? = nil, adaptive: Bool = true) -> Data {
        FractalColorizer.image(samples:samples,width:width,height:height,palette:palette,
                               phase:phase,density:density,relief:relief,
                               mapping:mapping,adaptive:adaptive)!.dataProvider!.data! as Data
    }

    static func colorCount(_ image: Data) -> Int {
        var colors = Set<UInt32>()
        for i in stride(from:0,to:image.count,by:4) {
            colors.insert(UInt32(image[i]) | UInt32(image[i+1]) << 8 | UInt32(image[i+2]) << 16)
        }
        return colors.count
    }

    static func adaptiveRange() {
        let width = 128, height = 64, count = width*height
        let samples = (0..<count).map { Float(50_000+4*Double($0)/Double(count-1)) }
        let mapping = FractalColorizer.estimateMapping(samples:samples,width:width,height:height)
        precondition(mapping.scale > 256 && mapping.scale <= 1_000_000 && mapping.origin.isFinite)
        let fixed = bytes(samples,width,height,mapping:.fixed)
        let calibrated = bytes(samples,width,height,mapping:mapping)
        let fixedColors = colorCount(fixed), adaptiveColors = colorCount(calibrated)
        precondition(adaptiveColors > 128 && adaptiveColors > fixedColors*4,"A narrow deep field still lacks palette contrast")
        precondition(calibrated == bytes(samples,width,height),"Explicit and estimated mappings disagree")
        precondition(fixed == bytes(samples,width,height,mapping:mapping,adaptive:false),"Disabling adaptation did not ignore the mapping")
        let old = original(samples,width,height,.aurora).dataProvider!.data! as Data
        for i in old.indices { precondition(abs(Int(old[i])-Int(fixed[i])) <= 1,"Fixed mapping changed the legacy palette") }
        var largestStep = 0
        for i in stride(from:4,to:calibrated.count,by:4) {
            for channel in 0..<3 { largestStep = max(largestStep,abs(Int(calibrated[i+channel])-Int(calibrated[i+channel-4]))) }
        }
        precondition(largestStep <= 4,"Affine mapping introduced discontinuous color bands")

        let translated = samples.map { $0+100_000 }
        let shifted = FractalColorizer.estimateMapping(samples:translated,width:width,height:height)
        precondition(shifted.scale > 256 && colorCount(bytes(translated,width,height,mapping:shifted)) > 128,
                     "Adding a large iteration offset destroyed adaptive contrast")
        let extraNarrow = (0..<count).map { Float(100+0.01*Double($0)/Double(count-1)) }
        let highGain = FractalColorizer.estimateMapping(samples:extraNarrow,width:width,height:height)
        precondition(highGain.scale > 10_000 && colorCount(bytes(extraNarrow,width,height,mapping:highGain)) > 128,
                     "Legitimate narrow distributions cannot use sufficient gain")

        let bimodal = (0..<count).map { index -> Float in
            let base = index/width < height/2 ? 50_000.0 : 50_003.6
            return Float(base+0.4*Double(index%width)/Double(width-1))
        }
        var majorityChanged = bimodal
        for x in 0..<width { majorityChanged[height/2*width+x] = bimodal[x] }
        let before = FractalColorizer.estimateMapping(samples:bimodal,width:width,height:height)
        let after = FractalColorizer.estimateMapping(samples:majorityChanged,width:width,height:height)
        precondition(abs(after.origin-before.origin)*max(after.scale,before.scale) < 0.03,
                     "A bimodal majority change caused a large hue rotation")

        var outliers = samples
        outliers[64] = 900_000; outliers[192] = 0
        outliers[320] = .nan; outliers[448] = .infinity; outliers[576] = -1
        let robust = FractalColorizer.estimateMapping(samples:outliers,width:width,height:height)
        precondition(abs(robust.scale/mapping.scale-1) < 0.05,"Sparse outliers distorted the color range")
        let colored = bytes(outliers,width,height,phase:0.25,density:1.5,relief:0.8,mapping:robust)
        precondition(colored == bytes(outliers,width,height,phase:1.25,density:1.5,relief:0.8,mapping:robust))
        precondition(colored != bytes(outliers,width,height,phase:0.25,density:1,relief:0.8,mapping:robust))
        for index in [320,448,576] { precondition(Array(colored[(index*4)..<(index*4+4)]) == [6,9,18,255]) }
        for index in stride(from:3,to:colored.count,by:4) { precondition(colored[index] == 255) }

        for value: Float in [-1,0,8000,.nan,.infinity] {
            let flat = [Float](repeating:value,count:count)
            precondition(FractalColorizer.estimateMapping(samples:flat,width:width,height:height) == .fixed)
            precondition(bytes(flat,width,height) == bytes(flat,width,height,adaptive:false),"Flat fields gained invented colors")
        }
        let quantized = (0..<count).map { Float(8000)+Float($0%8)*Float(8000).ulp }
        precondition(FractalColorizer.estimateMapping(samples:quantized,width:width,height:height) == .fixed,
                     "Near-uniform Float quantization was amplified")
        let unsafe = FractalColorizer.Mapping(origin:Double.greatestFiniteMagnitude,scale:1_000_000)
        precondition(unsafe == .fixed && bytes(samples,width,height,mapping:unsafe) == fixed)
        precondition(FractalColorizer.Mapping(origin:.nan,scale:200) == .fixed)
        precondition(FractalColorizer.Mapping(origin:1,scale:.infinity) == .fixed)
        precondition(FractalColorizer.estimateMapping(samples:[],width:Int.max,height:2) == .fixed)

        let target = FractalColorizer.Mapping(origin:mapping.origin+0.01,scale:mapping.scale*1.1)
        let smoothed = mapping.smoothed(toward:target,amount:0.2)
        precondition(smoothed.origin == target.origin,"A lagging range center would amplify hue pumping")
        precondition(smoothed.scale > mapping.scale && smoothed.scale < target.scale)
        let reduced = FractalColorizer.Mapping(origin:1,scale:10000).smoothed(toward:FractalColorizer.Mapping(origin:2,scale:2),amount:0.2)
        precondition(reduced.scale <= 3,"Broadening views retain excessive contrast")
        precondition(mapping.smoothed(toward:.fixed,amount:0.2) == .fixed)
        precondition(mapping.smoothed(toward:target,amount:0) == mapping)
        print("Adaptive contrast, large offsets, high gain, quantization guards, outliers, controls, and temporal anchors: passed (\(fixedColors) to \(adaptiveColors) colors)")
    }

    static func controls() {
        let samples: [Float] = [-1,0,0.2,1,2,4,8,16,32,64,128,256,512,1024,8192,50000]
        for palette in FractalPalette.allCases {
            let normal = bytes(samples,4,4,palette:palette)
            let implicit = FractalColorizer.image(samples:samples,width:4,height:4,palette:palette)!.dataProvider!.data! as Data
            precondition(normal == implicit,"Explicit defaults must preserve the default image")
            let shifted = bytes(samples,4,4,palette:palette,phase:0.25)
            precondition(shifted != normal,"Phase must change exterior colors")
            precondition(shifted == bytes(samples,4,4,palette:palette,phase:1.25))
            precondition(shifted == bytes(samples,4,4,palette:palette,phase:-0.75))
            precondition(normal == bytes(samples,4,4,palette:palette,phase:.nan))
            precondition(normal == bytes(samples,4,4,palette:palette,phase:.infinity))
            precondition(normal == bytes(samples,4,4,palette:palette,density:.nan))
            precondition(normal == bytes(samples,4,4,palette:palette,density:.infinity))
            precondition(bytes(samples,4,4,palette:palette,density:0.2) == bytes(samples,4,4,palette:palette,density:-20))
            precondition(bytes(samples,4,4,palette:palette,density:3) == bytes(samples,4,4,palette:palette,density:20))
            precondition(normal != bytes(samples,4,4,palette:palette,density:2),"Density must change palette frequency")
            precondition(normal == bytes(samples,4,4,palette:palette,relief:.nan))
            precondition(normal == bytes(samples,4,4,palette:palette,relief:-1))
            precondition(bytes(samples,4,4,palette:palette,relief:1) == bytes(samples,4,4,palette:palette,relief:5))
            precondition(Array(shifted.prefix(4)) == [6,9,18,255],"Interior colors must remain dark")
        }
        print("Phase wrapping, density bounds, finite inputs, and default compatibility: passed")
    }

    static func relief() {
        let rising: [Float] = [10,20,40,20,40,80,40,80,160]
        let falling = Array(rising.reversed())
        let normal = bytes(rising,3,3)
        let light = bytes(rising,3,3,relief:1)
        let dark = bytes(falling,3,3,relief:1)
        let center = 4*4
        let brightness: (Data) -> Int = { Int($0[center])+Int($0[center+1])+Int($0[center+2]) }
        precondition(brightness(light) > brightness(normal),"Upper-left facing slopes should catch the light")
        precondition(brightness(dark) < brightness(normal),"Opposite slopes should remain shaded")
        for image in [normal,light,dark] {
            precondition(image.count == 36)
            for offset in stride(from:3,to:image.count,by:4) { precondition(image[offset] == 255) }
        }
        let boundary: [Float] = [.nan,-1,.infinity,-1,40,-1,-.infinity,-1,.nan]
        let flat = bytes(boundary,3,3)
        precondition(flat == bytes(boundary,3,3,relief:1),"Invalid and interior neighbors must not create cliffs")
        for index in boundary.indices where index != 4 {
            precondition(Array(flat[(index*4)..<(index*4+4)]) == [6,9,18,255])
        }
        let constant = [Float](repeating:40,count:9)
        precondition(bytes(constant,3,3) == bytes(constant,3,3,relief:1),"A flat field must retain its colors")
        for (width,height) in [(1,1),(1,7),(7,1),(2,2)] {
            let samples = (0..<(width*height)).map { Float($0)*3 }
            let image = bytes(samples,width,height,phase:0.4,density:1.8,relief:1)
            precondition(image.count == width*height*4)
            for offset in stride(from:3,to:image.count,by:4) { precondition(image[offset] == 255) }
        }
        precondition(bytes([40],1,1) == bytes([40],1,1,relief:1))
        precondition(FractalColorizer.image(samples:[],width:0,height:0,palette:.aurora) == nil)
        precondition(FractalColorizer.image(samples:[1],width:-1,height:1,palette:.aurora) == nil)
        precondition(FractalColorizer.image(samples:[1],width:2,height:2,palette:.aurora) == nil)
        precondition(FractalColorizer.image(samples:[],width:Int.max,height:2,palette:.aurora) == nil)
        print("Relief lighting, boundary protection, alpha, invalid samples, and tiny images: passed")
    }

    static func original(_ samples: [Float], _ width: Int, _ height: Int, _ palette: FractalPalette) -> CGImage {
        let stops = palette.stops
        var rgba = [UInt8](repeating:255,count:width*height*4)
        for i in samples.indices {
            let nu = Double(samples[i]), offset = i*4
            if nu < 0 || !nu.isFinite { rgba[offset]=6; rgba[offset+1]=9; rgba[offset+2]=18; continue }
            let phase = sqrt(max(0,nu))*0.075 + nu*0.00045
            let t = (phase-floor(phase))*Double(stops.count)
            let base = Int(t)%stops.count
            let a = stops[base], b = stops[(base+1)%stops.count]
            let f = t-floor(t), blend = f*f*(3-2*f)
            rgba[offset] = UInt8(max(0,min(255,a.0+(b.0-a.0)*blend)))
            rgba[offset+1] = UInt8(max(0,min(255,a.1+(b.1-a.1)*blend)))
            rgba[offset+2] = UInt8(max(0,min(255,a.2+(b.2-a.2)*blend)))
        }
        let provider = CGDataProvider(data:Data(rgba) as CFData)!
        return CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent)!
    }
    static func main() {
        adaptiveRange()
        controls()
        relief()
        let width = 1250, height = 839
        var samples = [Float](repeating:0,count:width*height)
        for i in samples.indices {
            let whole = Float((i*7919)%50000)
            let fraction = Float(i%101)*Float(0.01)
            samples[i] = i%13 == 0 ? Float(-1) : whole+fraction
        }
        samples[1] = .nan; samples[2] = .infinity; samples[3] = -.infinity
        var checksum = 0
        for palette in FractalPalette.allCases {
            let a = original(samples,width,height,palette).dataProvider!.data! as Data
            let b = FractalColorizer.image(samples:samples,width:width,height:height,palette:palette)!.dataProvider!.data! as Data
            var worst = 0
            for i in a.indices { worst = max(worst,abs(Int(a[i])-Int(b[i]))) }
            precondition(worst <= 1,"Palette changed by more than one channel level")
            print("\(palette.title): maximum channel difference \(worst)")
        }
        let shaded = bytes(samples,width,height,phase:0.25,density:1.4,relief:0.8)
        precondition(shaded == bytes(samples,width,height,phase:0.25,density:1.4,relief:0.8),
                     "Parallel height and color passes must be deterministic")
        for index in samples.indices {
            let offset = index*4
            precondition(shaded[offset+3] == 255)
            if samples[index] < 0 || !samples[index].isFinite {
                precondition(shaded[offset] == 6 && shaded[offset+1] == 9 && shaded[offset+2] == 18,
                             "Relief must preserve all interior and invalid pixels")
            }
        }
        print("Parallel relief determinism and full-frame interior/alpha preservation: passed")
        var baseline = [Double](), optimized = [Double]()
        for iteration in 0..<8 {
            let start = ProcessInfo.processInfo.systemUptime
            let a = original(samples,width,height,.aurora)
            let middle = ProcessInfo.processInfo.systemUptime
            let b = FractalColorizer.image(samples:samples,width:width,height:height,palette:.aurora)!
            let end = ProcessInfo.processInfo.systemUptime
            checksum += a.width+b.width
            if iteration > 0 { baseline.append((middle-start)*1000); optimized.append((end-middle)*1000) }
        }
        let old = baseline.sorted()[baseline.count/2], new = optimized.sorted()[optimized.count/2]
        print(String(format:"1250x839 color median: original %.3f ms, optimized %.3f ms, speedup %.2fx (checksum %d)",old,new,old/new,checksum))
    }
}

import CoreGraphics
import Foundation

enum FractalColorizer {
    struct Mapping: Equatable {
        let origin: Double
        let scale: Double
        static let fixed = Mapping(origin:0,scale:1)

        init(origin: Double, scale: Double) {
            if origin.isFinite && abs(origin) <= Double(Float.greatestFiniteMagnitude)
                && scale.isFinite && scale > 1 {
                self.origin = origin
                self.scale = min(1_000_000,scale)
            } else { self.origin = 0; self.scale = 1 }
        }

        /// Smooth contrast, while anchoring the current field's robust center.
        /// Lagging that anchor would amplify tiny iteration changes into large
        /// hue rotations. Broadening fields shed excess gain promptly.
        func smoothed(toward target: Mapping, amount: Double) -> Mapping {
            let fraction = amount.isFinite ? min(1,max(0,amount)) : 1
            if fraction == 0 { return self }
            if fraction == 1 || target.scale == 1 { return target }
            let interpolated = exp(log(scale)+(log(target.scale)-log(scale))*fraction)
            let bounded = min(interpolated,min(scale*1.8,target.scale*1.5))
            return Mapping(origin:target.origin,scale:bounded)
        }
    }

    @inline(__always)
    private static func palettePhase(_ value: Double) -> Double {
        sqrt(value)*0.075+value*0.00045
    }

    /// Estimate once per escape field, then reuse for recoloring and export.
    /// Quantiles ignore isolated outliers. A minimum number of distinct values
    /// and representable Float steps prevents magnifying quantization noise.
    static func estimateMapping(samples: [Float], width: Int, height: Int) -> Mapping {
        guard width > 0, height > 0 else { return .fixed }
        let (count, overflow) = width.multipliedReportingOverflow(by:height)
        guard !overflow, count == samples.count else { return .fixed }
        let columns = min(64,width), rows = min(48,height)
        var values = [Float](); values.reserveCapacity(columns*rows)
        for y in 0..<rows {
            let row = min(height-1,Int((Double(y)+0.5)*Double(height)/Double(rows)))*width
            for x in 0..<columns {
                let column = min(width-1,Int((Double(x)+0.5)*Double(width)/Double(columns)))
                let value = samples[row+column]
                if value >= 0 && value.isFinite { values.append(value) }
            }
        }
        guard values.count >= 128 else { return .fixed }
        values.sort()
        let lowerIndex = Int(Double(values.count-1)*0.02)
        let upperIndex = Int(Double(values.count-1)*0.98)
        let lower = values[lowerIndex], upper = values[upperIndex]
        let valueSpan = Double(upper)-Double(lower)
        let resolution = max(Double(lower.ulp),Double(upper.ulp))
        guard valueSpan > 0 && valueSpan >= 128*resolution else { return .fixed }
        var distinct = 1
        for index in (lowerIndex+1)...upperIndex where values[index] != values[index-1] {
            distinct += 1
            if distinct >= 64 { break }
        }
        guard distinct >= 64 else { return .fixed }
        let lowerPhase = palettePhase(Double(lower)), upperPhase = palettePhase(Double(upper))
        let phaseSpan = upperPhase-lowerPhase
        guard phaseSpan > 0 && phaseSpan < 0.75 else { return .fixed }
        // Fade into calibration smoothly. Already broad views retain their
        // existing colors; compressed distributions use most of one cycle.
        let blend = min(1,max(0,(0.75-phaseSpan)/0.55))
        let smooth = blend*blend*(3-2*blend)
        let gain = 1+(0.9/phaseSpan-1)*smooth
        guard gain > 1.001 else { return .fixed }
        // A midrange anchor stays continuous when two distinct populations
        // exchange majority. A sample median can jump between those clusters.
        return Mapping(origin:lowerPhase+phaseSpan*0.5,scale:gain)
    }

    // A shared table avoids repeating palette interpolation at every pixel.
    // Sampling the midpoint of 65,536 bins changes a color channel by at most
    // one 8-bit level relative to the original continuous palette.
    private static let tableSize = 65_536
    private static let tables: [FractalPalette: [UInt32]] = {
        var result: [FractalPalette: [UInt32]] = [:]
        for palette in FractalPalette.allCases {
            let stops = palette.stops
            result[palette] = (0..<tableSize).map { index in
                let t = (Double(index)+0.5)/Double(tableSize)*Double(stops.count)
                let base = Int(t)
                let a = stops[base], b = stops[(base+1)%stops.count]
                let fraction = t-Double(base)
                let f = fraction*fraction*(3-2*fraction)
                let r = UInt32(a.0+(b.0-a.0)*f)
                let g = UInt32(a.1+(b.1-a.1)*f)
                let blue = UInt32(a.2+(b.2-a.2)*f)
                return (r | (g << 8) | (blue << 16) | 0xff000000).littleEndian
            }
        }
        return result
    }()

    // Relief lights the escape field in image space. It does not change the
    // fractal calculation or imply a geometric height for the Mandelbrot set.
    @inline(__always)
    private static func litColor(_ color: UInt32, index: Int, width: Int, height: Int,
                                 heights: UnsafeBufferPointer<Float>, strength: Double) -> UInt32 {
        let center = heights[index]
        let x = index % width, y = index / width
        let left = x > 0 && heights[index-1] >= 0 ? heights[index-1] : center
        let right = x+1 < width && heights[index+1] >= 0 ? heights[index+1] : center
        let top = y > 0 && heights[index-width] >= 0 ? heights[index-width] : center
        let bottom = y+1 < height && heights[index+width] >= 0 ? heights[index+width] : center
        let dx = Double(right-left)*0.5, dy = Double(bottom-top)*0.5
        if dx == 0 && dy == 0 { return color }
        // Softly limit steep gradients and omit interior/invalid neighbors.
        // This prevents a false vertical cliff around the unescaped region.
        let sx = 14*dx/(1+4*abs(dx)), sy = 14*dy/(1+4*abs(dy))
        let lightZ = 0.7035623639735145
        let diffuse = max(0,(0.45*sx+0.55*sy+lightZ)/sqrt(1+sx*sx+sy*sy))
        let brightness = 1+strength*(0.32+0.68*diffuse/lightZ-1)
        let packed = UInt32(littleEndian:color)
        let r = UInt32(min(255,max(0,Double(packed & 255)*brightness)))
        let g = UInt32(min(255,max(0,Double((packed >> 8) & 255)*brightness)))
        let b = UInt32(min(255,max(0,Double((packed >> 16) & 255)*brightness)))
        return (r | (g << 8) | (b << 16) | 0xff000000).littleEndian
    }

    static func image(samples: [Float], width: Int, height: Int, palette: FractalPalette,
                      phase: Double = 0, density: Double = 1, relief: Double = 0,
                      mapping: Mapping? = nil, adaptive: Bool = true) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by:height)
        guard !overflow, samples.count == pixelCount, pixelCount <= Int.max/4 else { return nil }
        let offset = phase.isFinite ? phase-floor(phase) : 0
        let frequency = density.isFinite ? min(3,max(0.2,density)) : 1
        let strength = relief.isFinite ? min(1,max(0,relief)) : 0
        let calibration = adaptive ? (mapping ?? estimateMapping(samples:samples,width:width,height:height)) : .fixed
        let table = tables[palette]!
        var data = Data(count:samples.count*4)
        let taskCount = samples.count < 65_536 ? 1 : min(8,ProcessInfo.processInfo.activeProcessorCount)
        // The default path allocates no height field and performs no lighting.
        var heights = strength > 0 ? [Float](repeating:-1,count:pixelCount) : []
        samples.withUnsafeBufferPointer { input in
            if strength > 0 {
                heights.withUnsafeMutableBufferPointer { field in
                    let target = field
                    let heightRows: (Int) -> Void = { task in
                        let first = input.count*task/taskCount
                        let end = input.count*(task+1)/taskCount
                        for index in first..<end {
                            let nu = Double(input[index])
                            target[index] = nu >= 0 && nu.isFinite ? Float(log1p(nu)) : -1
                        }
                    }
                    if taskCount == 1 { heightRows(0) }
                    else { DispatchQueue.concurrentPerform(iterations:taskCount,execute:heightRows) }
                }
            }
            table.withUnsafeBufferPointer { colors in
              heights.withUnsafeBufferPointer { field in
                data.withUnsafeMutableBytes { storage in
                    let output = storage.bindMemory(to:UInt32.self)
                    let colorRows: (Int) -> Void = { task in
                        let first = input.count*task/taskCount
                        let end = input.count*(task+1)/taskCount
                        for index in first..<end {
                            let nu = Double(input[index])
                            if nu < 0 || !nu.isFinite {
                                output[index] = UInt32(0xff120906).littleEndian
                            } else {
                                let original = sqrt(nu)*0.075 + nu*0.00045
                                let adjusted = calibration.scale == 1 ? original
                                    : calibration.origin+(original-calibration.origin)*calibration.scale
                                let cycle = adjusted*frequency+offset
                                let bin = Int((cycle-floor(cycle))*Double(tableSize))
                                let color = colors[min(tableSize-1,bin)]
                                output[index] = strength > 0
                                    ? litColor(color,index:index,width:width,height:height,heights:field,strength:strength)
                                    : color
                            }
                        }
                    }
                    if taskCount == 1 { colorRows(0) }
                    else { DispatchQueue.concurrentPerform(iterations:taskCount,execute:colorRows) }
                }
              }
            }
        }
        guard let provider = CGDataProvider(data:data as CFData) else { return nil }
        return CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,
                       space:CGColorSpace(name:CGColorSpace.sRGB)!,
                       bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent)
    }
}

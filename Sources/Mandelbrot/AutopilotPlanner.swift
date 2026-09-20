import CoreGraphics
import Foundation

enum AutopilotPlanner {
    struct Analysis {
        /// Centered image coordinates: x points right, y points upward.
        /// Nil means the field contains no coherent region worth following.
        let target: CGPoint?
        /// Interest of the selected neighborhood, in 0...1.
        let score: Double
        /// Approximate escaped fraction among finite, sampled input values.
        let escapedFraction: Double
        /// Robust range of log(1 + smooth escape iteration), before normalization.
        let variation: Double
        let hasStructure: Bool
        /// A heuristic, not an interior-membership test. True for wholly
        /// unescaped fields or substantial unescaped areas with late escapes.
        let needsMoreIterations: Bool
    }

    private struct Integral {
        let stride: Int
        let values: [Double]
        init(_ input: [Double], width: Int, height: Int) {
            stride = width+1
            var result = [Double](repeating:0,count:(width+1)*(height+1))
            for y in 0..<height {
                var row = 0.0
                for x in 0..<width {
                    row += input[y*width+x]
                    result[(y+1)*stride+x+1] = result[y*stride+x+1]+row
                }
            }
            values = result
        }
        @inline(__always)
        func sum(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Double {
            values[y1*stride+x1]-values[y0*stride+x1]-values[y1*stride+x0]+values[y0*stride+x0]
        }
    }

    /// Samples no more than 96x64 cells, with nine robust source probes per
    /// cell. Palette-independent scoring favors supported texture and curved
    /// boundaries, rather than isolated extrema or a single smooth edge.
    /// A previous target gives similar-quality nearby candidates a modest
    /// advantage. It cannot override a substantially more interesting region.
    static func analyze(samples: [Float], width: Int, height: Int, iterationLimit: Int,
                        previousTarget: CGPoint? = nil) -> Analysis {
        let empty = Analysis(target:nil,score:0,escapedFraction:0,variation:0,
                             hasStructure:false,needsMoreIterations:false)
        guard width > 0, height > 0, iterationLimit > 0 else { return empty }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by:height)
        guard !overflow, pixelCount == samples.count else { return empty }
        let columns = min(96,width), rows = min(64,height), count = columns*rows
        let stepX = Double(width)/Double(columns), stepY = Double(height)/Double(rows)
        let spreadX = max(1,Int(stepX/3)), spreadY = max(1,Int(stepY/3))
        var occupancy = [Double](repeating:0,count:count)
        var heights = [Double](repeating:0,count:count)
        var usable = [Double](repeating:0,count:count)
        var quality = [Double](repeating:0,count:count)
        var exteriorHeights = [Double](); exteriorHeights.reserveCapacity(count)
        var finiteSamples = 0, escapedSamples = 0, lateSamples = 0
        let lateThreshold = max(1,Double(iterationLimit)*0.82)
        for y in 0..<rows {
            let centerY = min(height-1,Int((Double(y)+0.5)*stepY))
            for x in 0..<columns {
                let centerX = min(width-1,Int((Double(x)+0.5)*stepX))
                var finite = 0, escaped = 0
                var total = 0.0, low = Double.infinity, high = -Double.infinity
                for dy in -1...1 {
                    let row = min(height-1,max(0,centerY+dy*spreadY))*width
                    for dx in -1...1 {
                        let value = Double(samples[row+min(width-1,max(0,centerX+dx*spreadX))])
                        guard value.isFinite else { continue }
                        finite += 1
                        if value >= 0 {
                            escaped += 1
                            if value >= lateThreshold { lateSamples += 1 }
                            let h = log1p(value)
                            total += h; low = min(low,h); high = max(high,h)
                        }
                    }
                }
                finiteSamples += finite; escapedSamples += escaped
                let index = y*columns+x
                quality[index] = Double(finite)/9
                occupancy[index] = finite > 0 ? Double(escaped)/Double(finite) : 0
                if escaped >= 3 && finite >= 5 && occupancy[index] >= 0.5 {
                    // Trimming both extrema removes a one-pixel spike without
                    // erasing a coherent filament across neighboring cells.
                    heights[index] = (total-low-high)/Double(escaped-2)
                    usable[index] = 1
                    exteriorHeights.append(heights[index])
                }
            }
        }
        guard finiteSamples > 0 else { return empty }
        let escapedFraction = Double(escapedSamples)/Double(finiteSamples)
        let needsMore = escapedSamples == 0 ||
            (escapedFraction < 0.88 && Double(lateSamples)/Double(max(1,escapedSamples)) > 0.15)
        exteriorHeights.sort()
        let last = max(0,exteriorHeights.count-1)
        let low = exteriorHeights.isEmpty ? 0 : exteriorHeights[Int(Double(last)*0.005)]
        let high = exteriorHeights.isEmpty ? 0 : exteriorHeights[Int(Double(last)*0.995)]
        let variation = max(0,high-low)
        let hasHeightRange = variation > 1e-7
        for index in 0..<count {
            heights[index] = hasHeightRange && usable[index] > 0
                ? min(1.5,max(-0.5,(heights[index]-low)/variation)) : 0
        }
        func result(_ target: CGPoint? = nil, _ score: Double = 0) -> Analysis {
            Analysis(target:target,score:score,escapedFraction:escapedFraction,variation:variation,
                     hasStructure:target != nil,needsMoreIterations:needsMore)
        }
        guard columns >= 9, rows >= 9 else { return result() }
        var edges = [Double](repeating:0,count:count)
        var curvature = [Double](repeating:0,count:count)
        var support = [Double](repeating:0,count:count)
        var signal = [Double](repeating:0,count:count)
        var weightedHeight = [Double](repeating:0,count:count)
        var heightSquared = [Double](repeating:0,count:count)
        for y in 1..<(rows-1) {
            for x in 1..<(columns-1) {
                let i = y*columns+x
                guard quality[i] >= 0.55 else { continue }
                let neighbors = [i-1,i+1,i-columns,i+columns]
                var boundaryEdge = 0.0, boundaryLap = 0.0, heightEdge = 0.0, heightLap = 0.0
                let center = occupancy[i], h = heights[i]
                for n in neighbors {
                    if quality[n] >= 0.55 {
                        boundaryEdge += abs(occupancy[n]-center)
                        boundaryLap += occupancy[n]-center
                        if hasHeightRange && usable[i] > 0 && usable[n] > 0 {
                            heightEdge += abs(heights[n]-h)
                            heightLap += heights[n]-h
                        }
                    }
                }
                let edge = min(1,0.75*boundaryEdge+heightEdge)
                let curve = min(1,2*abs(boundaryLap)+2.5*abs(heightLap))
                edges[i] = edge; curvature[i] = curve
                signal[i] = curve*sqrt(edge)
                support[i] = curve > 0.08 && edge > 0.035 ? 1 : 0
                weightedHeight[i] = h*usable[i]; heightSquared[i] = h*h*usable[i]
            }
        }
        let edgeSum = Integral(edges,width:columns,height:rows)
        let curveSum = Integral(curvature,width:columns,height:rows)
        let supportSum = Integral(support,width:columns,height:rows)
        let heightSum = Integral(weightedHeight,width:columns,height:rows)
        let squareSum = Integral(heightSquared,width:columns,height:rows)
        let usableSum = Integral(usable,width:columns,height:rows)
        let qualitySum = Integral(quality,width:columns,height:rows)
        let radius = min(5,(min(columns,rows)-3)/2)
        let diameter = radius*2+1, area = Double(diameter*diameter)
        let previous = previousTarget.flatMap { p -> CGPoint? in
            p.x.isFinite && p.y.isFinite && abs(p.x) <= 0.5 && abs(p.y) <= 0.5 ? p : nil
        }
        var bestRank = 0.0, bestScore = 0.0, bestX = 0, bestY = 0
        for y in stride(from:radius+1,to:rows-radius-1,by:2) {
            for x in stride(from:radius+1,to:columns-radius-1,by:2) {
                let x0 = x-radius, y0 = y-radius, x1 = x+radius+1, y1 = y+radius+1
                guard qualitySum.sum(x0,y0,x1,y1)/area >= 0.8 else { continue }
                let coverage = supportSum.sum(x0,y0,x1,y1)/area
                guard coverage >= 0.12 else { continue }
                let coherence = min(1,max(0,(coverage-0.06)/0.28))
                let n = usableSum.sum(x0,y0,x1,y1)
                let mean = n > 0 ? heightSum.sum(x0,y0,x1,y1)/n : 0
                let variance = n > 0 ? max(0,squareSum.sum(x0,y0,x1,y1)/n-mean*mean) : 0
                let score = min(1,(0.60*curveSum.sum(x0,y0,x1,y1)/area
                    + 0.25*edgeSum.sum(x0,y0,x1,y1)/area
                    + 0.15*min(1,2*sqrt(variance)))*coherence)
                let px = (Double(x)+0.5)/Double(columns)-0.5
                let py = 0.5-(Double(y)+0.5)/Double(rows)
                var rank = score*(1+0.025*exp(-(px*px+py*py)/0.12))
                if let previous {
                    let dx = px-Double(previous.x), dy = py-Double(previous.y)
                    rank *= 1+0.22*exp(-(dx*dx+dy*dy)/0.025)
                }
                if rank > bestRank { bestRank = rank; bestScore = score; bestX = x; bestY = y }
            }
        }
        guard bestScore >= 0.085 else { return result() }
        // Select a supported feature inside the winning neighborhood. A plain
        // centroid can land in the empty middle of a ring of interesting detail.
        var featureRank = 0.0, targetX = bestX, targetY = bestY
        for y in (bestY-radius)...(bestY+radius) {
            for x in (bestX-radius)...(bestX+radius) {
                let i = y*columns+x
                guard support[i] > 0 else { continue }
                let dx = Double(x-bestX), dy = Double(y-bestY)
                var rank = signal[i]*(0.6+0.4*exp(-(dx*dx+dy*dy)/Double(radius*radius)))
                if let previous {
                    let px = (Double(x)+0.5)/Double(columns)-0.5-Double(previous.x)
                    let py = 0.5-(Double(y)+0.5)/Double(rows)-Double(previous.y)
                    rank *= 1+0.18*exp(-(px*px+py*py)/0.012)
                }
                if rank > featureRank { featureRank = rank; targetX = x; targetY = y }
            }
        }
        let target = CGPoint(x:(Double(targetX)+0.5)/Double(columns)-0.5,
                             y:0.5-(Double(targetY)+0.5)/Double(rows))
        return result(target,bestScore)
    }
}

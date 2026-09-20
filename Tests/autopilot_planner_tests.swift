import CoreGraphics
import Foundation

@main
struct AutopilotPlannerTests {
    static let width = 384, height = 256
    static func plan(_ samples: [Float], previous: CGPoint? = nil) -> AutopilotPlanner.Analysis {
        AutopilotPlanner.analyze(samples:samples,width:width,height:height,iterationLimit:1200,previousTarget:previous)
    }
    static func field(_ value: (Int,Int) -> Float) -> [Float] {
        (0..<(width*height)).map { value($0%width,$0/width) }
    }
    static func textured(_ x: Int, _ y: Int, centerX: Int, centerY: Int, amplitude: Double = 1) -> Float? {
        guard abs(x-centerX) < 48, abs(y-centerY) < 40 else { return nil }
        let wave = sin(Double(x-centerX)*0.20)*cos(Double(y-centerY)*0.23)
        return Float(80+amplitude*(32*wave+12*sin(Double(x+y)*0.33)))
    }
    static func basic() {
        for value: Float in [0,25,800,-1] {
            let result = plan([Float](repeating:value,count:width*height))
            precondition(result.target == nil && !result.hasStructure,"Solid field created a target")
            precondition(result.score == 0 && result.variation == 0)
            precondition(result.escapedFraction == (value < 0 ? 0 : 1))
            precondition(result.needsMoreIterations == (value < 0))
        }
        let invalid = plan([Float](repeating:.nan,count:width*height))
        precondition(invalid.target == nil && !invalid.needsMoreIterations && invalid.escapedFraction == 0)
        let gradient = plan(field { x,_ in Float(exp(2+Double(x)*0.004)-1) })
        precondition(gradient.target == nil,"A smooth gradient was mistaken for fractal texture")
        var noise = [Float](repeating:25,count:width*height)
        noise[height/2*width+width/2] = 100000
        noise[10] = .nan; noise[20] = .infinity; noise[30] = -.infinity
        precondition(plan(noise).target == nil,"Isolated noise created an interesting region")
        let capped = plan(field { x,_ in x < width/2 ? -1 : 1160 })
        precondition(capped.needsMoreIterations,"Late escapes beside unresolved pixels must suggest more iterations")
        for (w,h,values) in [(0,0,[Float]()),(1,1,[Float(4)]),(3,3,[Float](repeating:10,count:9)),(Int.max,2,[Float]())] {
            let result = AutopilotPlanner.analyze(samples:values,width:w,height:h,iterationLimit:1200)
            precondition(result.target == nil && result.score.isFinite && result.variation.isFinite)
        }
        print("Flat fields, gradients, isolated noise, nonfinite values, dimensions, and iteration hints: passed")
    }
    static func interestAndOrientation() {
        let hotspot = field { x,y in textured(x,y,centerX:286,centerY:65) ?? 20 }
        let topRight = plan(hotspot)
        guard let target = topRight.target else { preconditionFailure("All-escaped textured hotspot was missed") }
        precondition(topRight.hasStructure && topRight.escapedFraction == 1 && topRight.variation > 0)
        precondition(target.x > 0.1 && target.y > 0.06,"Target coordinates are not centered and y-up")
        precondition(abs(target.x) < 0.49 && abs(target.y) < 0.49)
        let repeated = plan(hotspot)
        precondition(target == repeated.target && topRight.score == repeated.score,"Planner is not deterministic")
        let boundaryOnly = plan(field { x,y in
            guard abs(x-286) < 48 && abs(y-65) < 40 else { return 80 }
            return (x/12+y/12)%2 == 0 ? -1 : 80
        })
        precondition(boundaryOnly.hasStructure && boundaryOnly.target != nil && boundaryOnly.variation == 0,
                     "Coherent escape/interior texture requires no escape-height variation")
        let circle = field { x,y in
            let dx = x-96, dy = y-160
            return dx*dx+dy*dy < 50*50 ? -1 : 20
        }
        var combined = circle
        for y in 0..<height { for x in 0..<width {
            if let value = textured(x,y,centerX:286,centerY:65) { combined[y*width+x] = value }
        } }
        combined[12*width+12] = 1_000_000
        let selected = plan(combined)
        guard let choice = selected.target else { preconditionFailure("Combined field lost its texture") }
        precondition(choice.x > 0.1 && choice.y > 0.06,"Simple circle or isolated noise beat the textured cluster")
        precondition(topRight.score > plan(circle).score,"Texture should outrank a single smooth boundary")
        print(String(format:"Hotspot orientation and texture preference: passed (score %.3f, target %.3f, %.3f)",topRight.score,target.x,target.y))
    }
    static func hysteresis() {
        let twins = field { x,y in
            textured(x,y,centerX:96,centerY:128) ?? textured(x,y,centerX:288,centerY:128) ?? 20
        }
        let first = plan(twins,previous:CGPoint(x:0.25,y:0))
        guard let target = first.target else { preconditionFailure("Twin hotspots were missed") }
        precondition(target.x > 0,"Previous-target preference was ignored")
        let perturbed = field { x,y in
            textured(x,y,centerX:96,centerY:128,amplitude:1.015) ?? textured(x,y,centerX:288,centerY:128) ?? 20
        }
        let second = plan(perturbed,previous:target)
        guard let next = second.target else { preconditionFailure("Small input change removed the target") }
        precondition(next.x > 0 && hypot(next.x-target.x,next.y-target.y) < 0.15,
                     "Small score changes caused a jump between distant hotspots")
        let invalidPrevious = plan(twins,previous:CGPoint(x:Double.nan,y:Double.infinity))
        precondition(invalidPrevious.target == plan(twins).target,"Invalid previous target was not ignored")
        print("Spatial hysteresis and deterministic invalid-target handling: passed")
    }
    static func realFields() {
        let cases: [(String,String,String,String,Int,Bool)] = [
            ("Mandelbrot overview","-0.65","0","3.5",900,false),
            ("Mandelbrot spiral","-0.743643887037151","0.131825904205330","0.000025",1500,false),
            ("Deep Julia detail","-1.768667862837488812627419470","0.001645580546820209430325900","1.6e-21",50000,false),
            ("Julia dragon","0","0","3.5",1200,true)
        ]
        for (name,real,imag,span,iterations,julia) in cases {
            let viewport = mb_viewport_create()!, control = mb_render_control_create()!
            precondition(mb_viewport_set(viewport,real,imag,span) == 1)
            var values = [Float](repeating:-1,count:width*height)
            let ok = julia ? mb_render_julia(viewport,"-0.8","0.156",Int32(width),Int32(height),Int32(iterations),&values,control)
                           : mb_render(viewport,Int32(width),Int32(height),Int32(iterations),&values,control)
            precondition(ok == 1)
            let result = AutopilotPlanner.analyze(samples:values,width:width,height:height,iterationLimit:iterations)
            mb_render_control_destroy(control); mb_viewport_destroy(viewport)
            precondition(result.hasStructure && result.target != nil,"Real fractal structure was missed: \(name)")
            print(String(format:"%@: target (%+.3f,%+.3f), score %.3f, escaped %.3f, variation %.4f",name,result.target!.x,result.target!.y,result.score,result.escapedFraction,result.variation))
        }
    }
    static func performance() {
        let w = 1250, h = 839
        let values = (0..<(w*h)).map { index -> Float in
            let x = Double(index%w), y = Double(index/w)
            return Float(100+40*sin(x*0.026)*cos(y*0.034))
        }
        var times = [Double](), checksum = 0.0
        for run in 0..<9 {
            let start = ProcessInfo.processInfo.systemUptime
            let result = AutopilotPlanner.analyze(samples:values,width:w,height:h,iterationLimit:1200)
            let elapsed = (ProcessInfo.processInfo.systemUptime-start)*1000
            checksum += result.score
            if run > 0 { times.append(elapsed) }
        }
        print(String(format:"1250x839 planner median %.3f ms (checksum %.3f)",times.sorted()[times.count/2],checksum))
    }
    static func main() {
        basic(); interestAndOrientation(); hysteresis(); realFields(); performance()
        print("All autopilot planner checks passed.")
    }
}

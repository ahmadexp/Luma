import AppKit
import Foundation

@main
struct AutopilotIntegrationTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(),message)
    }
    static func pump(_ duration: TimeInterval) {
        let end = Date(timeIntervalSinceNow:duration)
        while Date() < end { _ = RunLoop.main.run(mode:.default,before:min(end,Date(timeIntervalSinceNow:0.005))) }
    }
    static func wait(_ message: String, timeout: TimeInterval = 20, _ predicate: () -> Bool) {
        let end = Date(timeIntervalSinceNow:timeout)
        while !predicate() && Date() < end { pump(0.005) }
        check(predicate(),"Timed out: " + message)
    }
    static func median(_ values: [Double]) -> Double { values.sorted()[values.count/2] }
    static func main() {
        let suite = "com.local.luma.autopilot-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!
        let model = ExplorerModel(defaults:defaults)
        defer { model.stopAnimations(); defaults.removePersistentDomain(forName:suite) }
        model.quality = .fine
        model.resize(to:CGSize(width:900,height:600))
        model.visit(.deepTest)
        wait("normal deep frame") { !model.isRendering && model.image != nil }
        var baseline: [Double] = []
        for _ in 0..<3 {
            let start = ProcessInfo.processInfo.systemUptime
            model.zoom(factor:0.97)
            wait("fine deep keyframe") { !model.isRendering }
            baseline.append((ProcessInfo.processInfo.systemUptime-start)*1000)
        }
        let normalPixels = (model.image?.width ?? 0)*(model.image?.height ?? 0)
        model.toggleFlight()
        var seen = 0, flightTimes: [Double] = [], flightPixels: [Double] = []
        let flightDeadline = Date(timeIntervalSinceNow:15)
        while model.flightFramesCompleted < 22 && Date() < flightDeadline {
            pump(0.005)
            if model.flightFramesCompleted != seen {
                seen = model.flightFramesCompleted
                if seen >= 6 { flightTimes.append(model.flightRenderMilliseconds); flightPixels.append(Double(model.flightPixelCount)) }
            }
        }
        check(model.flightFramesCompleted >= 22,"Continuous center flight stalled")
        check(!flightTimes.isEmpty,"No flight measurements")
        model.stopFlight()
        let stopped = model.coordinateStrings.span
        wait("full detail after pausing") { !model.isRendering }
        pump(0.2)
        check(model.coordinateStrings.span == stopped,"A prefetched camera leaked after stop")
        check((model.image?.width ?? 0)*(model.image?.height ?? 0) == normalPixels,"Pause did not restore Fine resolution")
        print(String(format:"Deep-view normal Fine pipeline: %.1f ms, %d pixels; adaptive flight compute: %.1f ms, %.0f pixels; %.2fx shorter compute/pipeline latency (different working resolutions)",median(baseline),normalPixels,median(flightTimes),median(flightPixels),median(baseline)/median(flightTimes)))

        model.quality = .draft
        model.visit(.overview)
        wait("overview") { !model.isRendering }
        model.toggleAutopilot()
        var sawSteering = false
        let start = Date(), deadline = Date(timeIntervalSinceNow:12)
        while model.flightFramesCompleted < 32 && Date() < deadline {
            pump(0.01)
            if let target = model.autopilotTarget, abs(target.x)+abs(target.y)>0.04 { sawSteering = true }
        }
        check(model.isAutopiloting && model.isFlying,"Autopilot stopped unexpectedly")
        check(model.flightFramesCompleted >= 32,"Autopilot stopped publishing frames")
        check(sawSteering,"Autopilot never steered toward interesting detail")
        check(model.flightTransition != nil,"Autopilot omitted smooth motion metadata")
        print("Autopilot overview: \(model.flightFramesCompleted) frames in \(String(format:"%.2f",Date().timeIntervalSince(start))) s, \(model.zoomLabel), \(model.flightRecoveries) recovery decisions")
        model.pan(dx:0.01,dy:0)
        check(!model.isFlying && !model.isAutopiloting,"Manual navigation did not take over")
        wait("manual override") { !model.isRendering }

        check(model.loadCoordinates(real:"3",imag:"3",span:"0.00001"),"Blank view setup failed")
        wait("blank view") { !model.isRendering }
        model.toggleAutopilot()
        wait("uninteresting-region recovery",timeout:12) { model.flightRecoveries >= 6 && model.autopilotTarget != nil }
        check(model.isAutopiloting,"Recovery stopped autopilot")
        model.stopAnimations()
        wait("recovery pause") { !model.isRendering }
        print("Flat-region recovery, manual takeover, and stop cancellation: passed")

        model.visitJulia(.dragon)
        wait("Julia setup") { !model.isRendering }
        model.toggleAutopilot()
        wait("Julia autopilot",timeout:12) { model.flightFramesCompleted >= 12 && model.autopilotTarget != nil }
        model.stopAnimations()
        wait("Julia pause") { !model.isRendering }
        check(model.fractalMode == .julia,"Julia autopilot changed fractal family")
        check(model.errorMessage == nil,"Autopilot reported a render error")
        model.toggleFlight()
        wait("flight before explicit quality edit") { model.flightFramesCompleted >= 2 }
        model.iterations = 512
        model.render()
        model.stopFlight()
        check(model.iterations == 512,"Stopping flight discarded an explicit iteration edit")
        wait("edited-detail pause") { !model.isRendering }
        print("Julia steering, paused full-detail rendering, and retained explicit iteration edits: passed")
        print("All autopilot integration checks passed.")
    }
}

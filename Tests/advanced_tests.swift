import AppKit
import Foundation

@main
struct AdvancedTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description:message) }
    }
    static func pump(_ seconds: TimeInterval) {
        let end = Date(timeIntervalSinceNow:seconds)
        while Date() < end { RunLoop.main.run(until:min(end,Date(timeIntervalSinceNow:0.01))) }
    }
    static func wait(_ message: String, timeout: TimeInterval = 10, until done: () -> Bool) throws {
        let deadline = Date(timeIntervalSinceNow:timeout)
        while !done() && Date() < deadline { pump(0.01) }
        try check(done(),"Timed out: \(message)")
    }
    static func sameCamera(_ a: (real:String,imag:String,span:String),
                           _ b: (real:String,imag:String,span:String)) -> Bool {
        a.real == b.real && a.imag == b.imag && a.span == b.span
    }

    static func sessionsAndBookmarks(_ defaults: UserDefaults) throws {
        let model = ExplorerModel(defaults:defaults)
        defer { model.stopAnimations() }
        let prefix = "-0."+String(repeating:"1",count:380)
        try check(model.loadCoordinates(real:prefix+"23456789",imag:"0.0000001234567890123456789",span:"1e-400"),
                  "Deep coordinates were rejected")
        model.iterations = 1600
        model.palette = .violet; model.quality = .draft
        model.colorPhase = 0.375; model.colorDensity = 1.65; model.relief = 0.6
        model.recolor()
        guard let data = model.encodedLocation() else { throw Failure(description:"Location encoding failed") }
        let state = try JSONDecoder().decode(SavedLocation.self,from:data)
        try check(state.real.hasPrefix(prefix),"Session lost decimal digits beyond Double precision")
        try check(state.span.count > 0 && state.zoom == model.zoomLabel,"Session omitted camera metadata")
        try check(state.cameraBits == model.precision,"Session omitted its original camera precision")

        let restored = ExplorerModel(defaults:defaults)
        defer { restored.stopAnimations() }
        try check(restored.coordinateStrings.real.hasPrefix(prefix),"Last-session restore lost deep coordinates")
        try check(restored.precision > 1300,"Restored camera lost arbitrary precision")
        try check(restored.applyLocation(state),"Encoded session could not be applied")
        try check(restored.coordinateStrings.real.hasPrefix(prefix),"JSON round trip truncated the camera")
        try check(restored.zoomLabel == model.zoomLabel,"JSON round trip changed zoom depth")
        try check(restored.palette == .violet && restored.quality == .draft && restored.iterations == 1600,
                  "JSON round trip changed render settings")
        try check(restored.colorPhase == 0.375 && restored.colorDensity == 1.65 && restored.relief == 0.6,
                  "JSON round trip changed color controls")
        let exactCamera = model.coordinateStrings
        for _ in 0..<10 {
            guard let encoded = restored.encodedLocation() else { throw Failure(description:"Repeated location encoding failed") }
            let next = try JSONDecoder().decode(SavedLocation.self,from:encoded)
            try check(restored.applyLocation(next),"Repeated session restore failed")
            try check(sameCamera(restored.coordinateStrings,exactCamera) && restored.precision == model.precision,
                      "Repeated session restore changed camera values or increased precision")
        }
        var legacyJSON = try JSONSerialization.jsonObject(with:data) as! [String:Any]
        legacyJSON.removeValue(forKey:"cameraBits")
        let legacy = try JSONDecoder().decode(SavedLocation.self,from:JSONSerialization.data(withJSONObject:legacyJSON))
        try check(legacy.cameraBits == nil && restored.applyLocation(legacy),"Legacy sessions without precision metadata stopped loading")
        try check(restored.coordinateStrings.real.hasPrefix(prefix),"Legacy session import truncated deep coordinates")
        let unchanged = restored.encodedLocation()
        var invalidStates: [SavedLocation] = []
        var invalid = state; invalid.span = "0"; invalidStates.append(invalid)
        invalid = state; invalid.real = "not a coordinate"; invalidStates.append(invalid)
        invalid = state; invalid.juliaImag = "nan"; invalidStates.append(invalid)
        invalid = state; invalid.version = 999; invalidStates.append(invalid)
        invalid = state; invalid.iterations = .infinity; invalidStates.append(invalid)
        invalid = state; invalid.iterations = 255; invalidStates.append(invalid)
        invalid = state; invalid.colorDensity = 0; invalidStates.append(invalid)
        invalid = state; invalid.colorPhase = .nan; invalidStates.append(invalid)
        invalid = state; invalid.relief = 2; invalidStates.append(invalid)
        invalid = state; invalid.cameraBits = 0; invalidStates.append(invalid)
        invalid = state; invalid.cameraBits = Int.max; invalidStates.append(invalid)
        invalid = state; invalid.cameraBits = Int(Int32.max); invalidStates.append(invalid)
        for invalid in invalidStates {
            try check(!restored.applyLocation(invalid),"Invalid location was accepted")
            try check(restored.encodedLocation() == unchanged,"Invalid location partially changed model state")
        }

        restored.saveBookmark(name:"  Precision test  ")
        restored.saveBookmark(name:"   ")
        try check(restored.bookmarks.count == 1 && restored.bookmarks[0].name == "Precision test",
                  "Bookmark naming or empty-name handling failed")
        let reloaded = ExplorerModel(defaults:defaults)
        defer { reloaded.stopAnimations() }
        try check(reloaded.bookmarks.count == 1,"Bookmarks did not survive model reload")
        try check(reloaded.bookmarks[0].id == restored.bookmarks[0].id,"Bookmark identity changed")
        reloaded.visit(.overview)
        reloaded.restoreBookmark(reloaded.bookmarks[0])
        try check(reloaded.coordinateStrings.real.hasPrefix(prefix) && reloaded.relief == 0.6,
                  "Bookmark restore lost camera or style")
        reloaded.deleteBookmark(reloaded.bookmarks[0])
        let empty = ExplorerModel(defaults:defaults)
        defer { empty.stopAnimations() }
        try check(empty.bookmarks.isEmpty,"Bookmark deletion was not persisted")
        print("Exact camera precision over 10 restores, legacy import, atomic rejection, and bookmarks: passed")
    }

    static func modesAndAnimations(_ model: ExplorerModel) throws {
        model.quality = .draft
        model.resize(to:CGSize(width:320,height:240))
        model.visit(.seahorse)
        let mandelbrot = model.coordinateStrings
        model.toggleJuliaPicker()
        try check(model.isPickingJulia,"Julia portal selection did not start")
        model.pickJulia(at:.zero)
        try check(model.fractalMode == .julia && !model.isPickingJulia &&
                  model.juliaReal == mandelbrot.real && model.juliaImag == mandelbrot.imag,
                  "Julia portal did not preserve the selected exact parameter")
        model.switchMode(.mandelbrot)
        try check(sameCamera(model.coordinateStrings,mandelbrot),"Returning from the portal lost the Mandelbrot view")
        model.switchMode(.julia)
        try check(model.fractalMode == .julia,"Julia mode switch failed")
        model.switchMode(.mandelbrot)
        try check(model.fractalMode == .mandelbrot && sameCamera(model.coordinateStrings,mandelbrot),
                  "Returning from Julia lost the Mandelbrot camera")
        model.goBack()
        try check(model.fractalMode == .julia,"Navigation history lost the fractal mode")
        let unchanged = model.encodedLocation()
        try check(!model.applyJuliaParameter(real:"nan",imag:"0"),"Invalid Julia parameter was accepted")
        try check(model.encodedLocation() == unchanged,"Rejected Julia parameter changed the view")
        for destination in JuliaDestination.allCases {
            model.visitJulia(destination)
            try check(model.fractalMode == .julia && model.juliaReal == destination.real && model.juliaImag == destination.imag,
                      "Julia destination did not apply its parameter")
        }
        try wait("Julia final render") { !model.isRendering && model.image != nil }
        try check(model.image?.width == 640 && model.image?.height == 480,"Julia image dimensions do not match the viewport")
        try check(model.errorMessage == nil,"Julia rendering reported an error")

        let initialSpan = model.coordinateStrings.span
        model.toggleFlight()
        try check(model.isFlying,"Zoom flight did not start")
        try wait("zoom flight advance",timeout:3) { model.coordinateStrings.span != initialSpan }
        model.stopFlight()
        let stoppedSpan = model.coordinateStrings.span
        pump(0.25)
        try check(!model.isFlying && model.coordinateStrings.span == stoppedSpan,"Zoom flight continued after stopping")
        try wait("final flight frame") { !model.isRendering }

        let phase = model.colorPhase
        let initialColors = model.image!.dataProvider!.data! as Data
        model.toggleColorCycle()
        try wait("color cycle advance",timeout:2) { model.colorPhase != phase }
        try check(model.isColorCycling && !model.isRendering,"Color cycling unexpectedly restarted fractal rendering")
        try wait("animated relief image update",timeout:3) {
            guard let image = model.image else { return false }
            return (image.dataProvider!.data! as Data) != initialColors
        }
        model.stopAnimations()
        let stoppedPhase = model.colorPhase
        pump(0.15)
        try check(!model.isColorCycling && !model.isFlying && model.colorPhase == stoppedPhase,
                  "Animation timers continued after stopping")
        print("Julia destinations/portal, mode/history restoration, rendering, zoom flight, and animated relief: passed")
    }

    static func exports(_ model: ExplorerModel, directory: URL) throws {
        let output = directory.appendingPathComponent("export.png")
        model.exportImage(to:output)
        try check(model.isExporting,"High-resolution export did not start")
        try wait("PNG export",timeout:20) { !model.isExporting }
        try check(model.exportProgress == 1,"Successful export did not reach full progress")
        let data = try Data(contentsOf:output)
        guard let png = NSBitmapImageRep(data:data) else { throw Failure(description:"Export is not a readable PNG") }
        try check(png.pixelsWide == 3840 && png.pixelsHigh == 2880,"Default export is not 4K or lost the viewport aspect ratio")
        let cancelled = directory.appendingPathComponent("cancelled.png")
        model.exportImage(to:cancelled,longEdge:1024)
        try check(model.isExporting,"Cancellation test export did not start")
        model.cancelExport()
        pump(0.3)
        try check(!model.isExporting && model.exportProgress == 0,"Cancelled export retained active progress")
        try check(!FileManager.default.fileExists(atPath:cancelled.path),"A cancelled export wrote a file")
        print("3840x2880 PNG export, completion, and cancellation without output: passed")
    }

    static func run() throws {
        let suite = "com.local.luma.advanced-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName:suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("luma-advanced-tests-\(UUID().uuidString)",isDirectory:true)
        defer {
            defaults.removePersistentDomain(forName:suite)
            try? FileManager.default.removeItem(at:directory)
        }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try sessionsAndBookmarks(defaults)
        let model = ExplorerModel(defaults:defaults)
        defer { model.cancelExport(); model.stopAnimations() }
        try modesAndAnimations(model)
        try exports(model,directory:directory)
        print("All advanced application smoke tests passed.")
    }

    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("Advanced test failure: \(error)\n".utf8))
            exit(1)
        }
    }
}

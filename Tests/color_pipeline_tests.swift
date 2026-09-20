import AppKit
import Foundation

@main
struct ColorPipelineTests {
    static func pump(_ duration: TimeInterval) {
        let end = Date(timeIntervalSinceNow:duration)
        while Date() < end { _ = RunLoop.main.run(mode:.default,before:min(end,Date(timeIntervalSinceNow:0.005))) }
    }
    static func wait(_ message: String, _ predicate: () -> Bool) {
        let end = Date(timeIntervalSinceNow:20)
        while !predicate() && Date() < end { pump(0.005) }
        precondition(predicate(),message)
    }
    static func colors(_ image: CGImage) -> Int {
        let data = image.dataProvider!.data! as Data
        var colors = Set<UInt32>()
        for i in stride(from:0,to:data.count,by:4) {
            let rgb = UInt32(data[i]) | UInt32(data[i+1])<<8 | UInt32(data[i+2])<<16
            if rgb != 0x120906 { colors.insert(rgb) }
        }
        return colors.count
    }
    static func main() throws {
        let suite = "com.local.luma.color-pipeline." + UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!
        let model = ExplorerModel(defaults:defaults)
        defer { model.stopAnimations(); defaults.removePersistentDomain(forName:suite) }
        let output = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/color-range-checks")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        precondition(model.adaptiveColorRange)
        model.quality = .draft; model.iterations = 2200
        model.resize(to:CGSize(width:320,height:240))
        precondition(model.loadCoordinates(real:"-2",imag:"0",span:"1e-400"))
        wait("Deep adaptive image") { !model.isRendering && model.image != nil }
        let adaptive = model.image!, adaptivePNG = ExplorerModel.pngData(adaptive)
        let coordinates = model.coordinateStrings
        model.adaptiveColorRange = false; model.recolor()
        wait("Fixed recolor") { model.image !== adaptive }
        let fixed = model.image!
        precondition(!model.isRendering,"A color toggle must not rerender fractal orbits")
        precondition(model.coordinateStrings.real == coordinates.real && model.coordinateStrings.span == coordinates.span)
        precondition(colors(adaptive) > colors(fixed)*3,"Adaptive mapping did not restore deep color range")
        try ExplorerModel.pngData(fixed).write(to:output.appendingPathComponent("fixed-e400.png"))
        try adaptivePNG.write(to:output.appendingPathComponent("adaptive-e400.png"))
        print("Deep field: fixed \(colors(fixed)) distinct exterior colors; adaptive \(colors(adaptive)) colors")

        model.adaptiveColorRange = true; model.recolor()
        wait("Adaptive recolor") { model.image !== fixed }
        precondition(ExplorerModel.pngData(model.image!) == adaptivePNG,"Recoloring changed a field's exposure")
        model.visit(.overview)
        wait("Overview") { !model.isRendering }
        model.goBack()
        wait("Cached deep image") { !model.isRendering }
        precondition(model.elapsedLabel == "Cached")
        precondition(ExplorerModel.pngData(model.image!) == adaptivePNG,"Frame cache lost adaptive exposure")
        let exported = output.appendingPathComponent("matching-export.png")
        model.exportImage(to:exported,longEdge:640)
        wait("Consistent export") { !model.isExporting }
        let exportData = try Data(contentsOf:exported)
        precondition(exportData == adaptivePNG,"Export did not preserve the displayed exposure")

        model.adaptiveColorRange = false; model.recolor(); model.saveBookmark(name:"Fixed range")
        let reopened = ExplorerModel(defaults:defaults)
        precondition(!reopened.adaptiveColorRange,"Session did not preserve the color-range toggle")
        reopened.adaptiveColorRange = true
        reopened.restoreBookmark(reopened.bookmarks[0])
        precondition(!reopened.adaptiveColorRange,"Bookmark did not preserve the color-range toggle")
        var legacy = try JSONSerialization.jsonObject(with:model.encodedLocation()!) as! [String:Any]
        legacy.removeValue(forKey:"adaptiveColorRange")
        let restored = try JSONDecoder().decode(SavedLocation.self,from:JSONSerialization.data(withJSONObject:legacy))
        precondition(model.applyLocation(restored) && model.adaptiveColorRange,"Legacy locations should use adaptive range")
        wait("Legacy restore") { !model.isRendering }
        model.toggleFlight()
        wait("Adaptive flight") { model.flightFramesCompleted >= 12 }
        model.stopFlight()
        wait("Adaptive pause") { !model.isRendering }
        precondition(colors(model.image!) > colors(fixed)*3,"Color range collapsed during flight")
        precondition(model.errorMessage == nil)
        print("Stable recoloring, cached exposure, matching PNG export, session/bookmark compatibility, and flight: passed")
    }
}

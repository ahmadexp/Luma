import AppKit

func runRenderChecks() {
    let output = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/checks")
    try! FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
    let camera = mb_viewport_create()!
    let control = mb_render_control_create()!
    if CommandLine.arguments.contains("--no-acceleration") { mb_render_control_set_acceleration(control,0) }
    defer { mb_render_control_destroy(control); mb_viewport_destroy(camera) }
    for place in FractalDestination.allCases {
        let (r,i,s) = place.location
        precondition(mb_viewport_set(camera,r,i,s) == 1)
        let width = 800, height = 600
        var samples = [Float](repeating:-1,count:width*height)
        let start = ProcessInfo.processInfo.systemUptime
        precondition(mb_render(camera,Int32(width),Int32(height),place == .deepTest ? 50_000 : 2000,&samples,control) == 1)
        guard let image = ExplorerModel.makeImage(samples:samples,width:width,height:height,palette:.aurora) else { fatalError("Image failed") }
        try! ExplorerModel.pngData(image).write(to:output.appendingPathComponent("\(place.rawValue).png"))
        let escaped = samples.filter { $0 >= 0 }.count
        print("\(place.rawValue): \(mb_viewport_precision(camera)) bits, \(escaped)/\(samples.count) escaped, \(String(format:"%.3f",ProcessInfo.processInfo.systemUptime-start)) s")
    }
    for place in JuliaDestination.allCases {
        precondition(mb_viewport_set(camera,"0","0","3.5") == 1)
        let width = 1000, height = 700
        var samples = [Float](repeating:-1,count:width*height)
        let start = ProcessInfo.processInfo.systemUptime
        precondition(mb_render_julia(camera,place.real,place.imag,Int32(width),Int32(height),1200,&samples,control) == 1)
        guard let image = FractalColorizer.image(samples:samples,width:width,height:height,palette:.aurora,phase:0.12,density:1.2,relief:0.3) else { fatalError("Julia image failed") }
        try! ExplorerModel.pngData(image).write(to:output.appendingPathComponent("julia-\(place.rawValue).png"))
        print("Julia \(place.rawValue): \(String(format:"%.3f",ProcessInfo.processInfo.systemUptime-start)) s")
    }
}

func runPipelineChecks() {
    let suite = "com.local.luma.pipeline-tests." + UUID().uuidString
    let defaults = UserDefaults(suiteName:suite)!
    defer { defaults.removePersistentDomain(forName:suite) }
    func waitFor(_ message: String, until predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(30)
        while !predicate() && Date() < deadline {
            _ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.005))
        }
        precondition(predicate(),message)
    }
    let model = ExplorerModel(defaults:defaults)
    model.quality = .draft
    model.resize(to:CGSize(width:640,height:400))
    waitFor("Initial rendering failed") { !model.isRendering && model.image != nil }
    model.visit(.deepTest)
    waitFor("Deep view failed") { !model.isRendering }
    precondition(model.iterations == 50_000)
    print("Deep Julia pipeline: \(model.elapsedLabel), \(model.status)")
    let first = model.image
    model.palette = model.palette == .ember ? .lagoon : .ember
    model.recolor()
    waitFor("Asynchronous recoloring failed") { model.image !== first }
    model.reset()
    waitFor("Overview cache restoration failed") { !model.isRendering }
    precondition(model.elapsedLabel == "Cached")
    model.goBack()
    waitFor("Deep view cache restoration failed") { !model.isRendering }
    precondition(model.iterations == 50_000)
    precondition(model.elapsedLabel == "Cached")
    // Rapidly replace pending renders and a recolor. Only the latest camera
    // and color request may publish their results.
    model.zoom(factor:0.5)
    model.palette = .violet
    model.recolor()
    model.reset()
    waitFor("Superseded render blocked navigation") { !model.isRendering }
    precondition(model.selectedDestination == FractalDestination.overview.rawValue)
    precondition(model.elapsedLabel == "Cached")
    print("Pipeline checks passed: render, background recolor, frame cache, history detail, superseded navigation")
}

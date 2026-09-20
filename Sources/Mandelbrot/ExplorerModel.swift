import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum FractalPalette: String, CaseIterable, Identifiable, Codable {
    case aurora, ember, lagoon, violet, monochrome
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var stops: [(Double, Double, Double)] {
        switch self {
        case .aurora: return [(9,14,39),(30,28,93),(105,57,154),(49,153,218),(125,236,224),(249,238,172),(240,143,79),(85,36,112)]
        case .ember: return [(13,8,25),(65,18,58),(163,39,66),(240,100,52),(255,190,101),(255,242,195),(173,72,92),(45,17,55)]
        case .lagoon: return [(4,17,37),(10,55,98),(13,126,159),(57,215,206),(194,255,219),(228,236,159),(30,153,152),(11,52,85)]
        case .violet: return [(12,9,38),(42,25,91),(112,54,178),(204,110,226),(255,203,230),(232,235,255),(117,155,235),(47,36,109)]
        case .monochrome: return [(7,11,18),(39,49,67),(105,123,144),(201,215,225),(249,246,230),(142,153,164),(45,58,77)]
        }
    }
    var colors: [Color] { stops.map { Color(red:$0.0/255,green:$0.1/255,blue:$0.2/255) } }
}

enum RenderQuality: String, CaseIterable, Identifiable, Codable {
    case draft, balanced, fine
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var pixelBudget: Double { switch self { case .draft: return 420_000; case .balanced: return 1_050_000; case .fine: return 2_800_000 } }
}

enum FractalDestination: String, CaseIterable, Identifiable {
    case overview, seahorse, spiral, elephant, deepTest
    var id: String { rawValue }
    var title: String {
        switch self { case .overview: return "The whole set"; case .seahorse: return "Seahorse Valley"; case .spiral: return "Spiral garden"; case .elephant: return "Elephant Valley"; case .deepTest: return "Deep Julia" }
    }
    var subtitle: String {
        switch self { case .overview: return "Where every journey begins"; case .seahorse: return "Braided filaments and tiny worlds"; case .spiral: return "An intricate, curling coastline"; case .elephant: return "Golden trunks on the eastern edge"; case .deepTest: return "A 10²¹× journey beyond floating point" }
    }
    var location: (String, String, String) {
        switch self {
        case .overview: return ("-0.65", "0", "3.5")
        case .seahorse: return ("-0.7435", "0.1314", "0.006")
        case .spiral: return ("-0.743643887037151", "0.131825904205330", "0.000025")
        case .elephant: return ("0.273", "0.008", "0.008")
        case .deepTest: return ("-1.768667862837488812627419470", "0.001645580546820209430325900", "1.6e-21")
        }
    }
}

private final class CameraSnapshot {
    let pointer: OpaquePointer
    init(_ source: OpaquePointer) { pointer = mb_viewport_clone(source)! }
    deinit { mb_viewport_destroy(pointer) }
}

private final class RenderJob {
    let camera: CameraSnapshot
    let control: OpaquePointer
    init(_ viewport: OpaquePointer) {
        camera = CameraSnapshot(viewport)
        control = mb_render_control_create()!
    }
    func cancel() { mb_render_control_cancel(control) }
    deinit { mb_render_control_destroy(control) }
}

private struct ColorStyle: Equatable {
    let palette: FractalPalette
    let phase: Double
    let density: Double
    let relief: Double
    let adaptive: Bool
    func image(_ samples: [Float], _ width: Int, _ height: Int, mapping: FractalColorizer.Mapping? = nil) -> CGImage? {
        FractalColorizer.image(samples:samples,width:width,height:height,palette:palette,phase:phase,density:density,relief:relief,mapping:mapping,adaptive:adaptive)
    }
}

private struct CachedFrame {
    let key: String
    let samples: [Float]
    let width: Int
    let height: Int
    let image: CGImage?
    let style: ColorStyle
    let mapping: FractalColorizer.Mapping
    let precision: Int
    let wideExponent: Bool
    var byteCount: Int { samples.count*8 }
}

private struct NavigationSnapshot {
    let camera: CameraSnapshot
    let mode: FractalMode
    let juliaReal: String
    let juliaImag: String
    let iterations: Double
}

final class ExplorerModel: ObservableObject {
    @Published var image: CGImage?
    @Published var isRendering = false
    @Published var status = "Preparing your first view"
    @Published var precision = 128
    @Published var zoomLabel = "1×"
    @Published var elapsedLabel = ""
    @Published var palette = FractalPalette.aurora
    @Published var iterations: Double = 900 {
        didSet { if isFlying && !settingFlightIterations { flightUserIterations = iterations } }
    }
    @Published var quality = RenderQuality.balanced
    @Published var selectedDestination = FractalDestination.overview.rawValue
    @Published var canGoBack = false
    @Published var showCoordinateEditor = false { didSet { if showCoordinateEditor { stopFlight() } } }
    @Published var showBookmarkEditor = false { didSet { if showBookmarkEditor { stopAnimations() } } }
    @Published var errorMessage: String?
    @Published var fractalMode = FractalMode.mandelbrot
    @Published var juliaReal = "-0.8"
    @Published var juliaImag = "0.156"
    @Published var isPickingJulia = false
    @Published var isFlying = false
    @Published var flightSpeed = 1.0
    @Published var isAutopiloting = false
    @Published var autopilotStatus = "Ready to find a trail"
    @Published var autopilotTarget: CGPoint?
    @Published var flightFPSLabel = ""
    @Published var flightTransition: FlightTransition?
    private(set) var flightFramesCompleted = 0
    private(set) var flightRenderMilliseconds = 0.0
    private(set) var flightPixelCount = 0
    private(set) var flightRecoveries = 0
    @Published var colorPhase = 0.0
    @Published var colorDensity = 1.0
    @Published var relief = 0.0
    @Published var adaptiveColorRange = true
    @Published var isColorCycling = false
    @Published var bookmarks: [FractalBookmark] = []
    @Published var isExporting = false
    @Published var exportProgress = 0.0

    private let preferences: UserDefaults
    private var viewport = mb_viewport_create()!
    private var history: [NavigationSnapshot] = []
    private var mandelbrotReturn: NavigationSnapshot?
    private var lastHistoryTime = 0.0
    private var size = CGSize(width:900,height:680)
    private var generation = 0
    private var pending: DispatchWorkItem?
    private var currentJob: RenderJob?
    private let queue = DispatchQueue(label:"com.local.luma.render",qos:.userInitiated)
    private let colorQueue = DispatchQueue(label:"com.local.luma.color",qos:.userInitiated)
    private let exportQueue = DispatchQueue(label:"com.local.luma.export",qos:.utility)
    private var colorGeneration = 0
    private var coloring = false
    private var colorAgain = false
    private var frames: [CachedFrame] = []
    private var field: [Float] = []
    private var fieldRenderGeneration = -1
    private var fieldMapping = FractalColorizer.Mapping.fixed
    private var fieldGeneration = 0
    private var fieldWidth = 0
    private var fieldHeight = 0
    private var settingFlightIterations = false
    private var flightUserIterations: Double?
    private var flightEpoch = 0
    private var flightPresentedState: NavigationSnapshot?
    private var flightAnalysis: AutopilotPlanner.Analysis?
    private var flightPublishAfter = 0.0
    private var flightPixels = 320_000.0
    private var flightEstimate = 0.10
    private var flightRequestedLimit = 0
    private var flightSize = CGSize.zero
    private var flightQuality = RenderQuality.balanced
    private var flightUninterestingFrames = 0
    private var flightTimeouts = 0
    private var flightTrailIndex = 0
    private var flightWatchdog: DispatchWorkItem?
    private var cycleTimer: Timer?
    private var exportTimer: Timer?
    private var exportJob: RenderJob?
    private var exportGeneration = 0
    private var style: ColorStyle { ColorStyle(palette:palette,phase:colorPhase,density:colorDensity,relief:relief,adaptive:adaptiveColorRange) }
    private var snapshot: NavigationSnapshot {
        NavigationSnapshot(camera:CameraSnapshot(viewport),mode:fractalMode,juliaReal:juliaReal,juliaImag:juliaImag,iterations:iterations)
    }

    init(defaults: UserDefaults = .standard) {
        preferences = defaults
        if let saved = defaults.string(forKey:"palette"), let p = FractalPalette(rawValue:saved) { palette = p }
        let (r,i,s) = FractalDestination.overview.location
        _ = mb_viewport_set(viewport,r,i,s)
        if let data = defaults.data(forKey:"luma.bookmarks.v1"), let saved = try? JSONDecoder().decode([FractalBookmark].self,from:data) { bookmarks = saved }
        if let data = defaults.data(forKey:"luma.lastLocation.v1"), let saved = try? JSONDecoder().decode(SavedLocation.self,from:data), let camera = validatedCamera(saved) {
            mb_viewport_destroy(viewport)
            viewport = camera
            assignSettings(saved)
            selectedDestination = ""
        }
        updateReadouts()
    }
    deinit {
        pending?.cancel(); currentJob?.cancel(); exportJob?.cancel()
        flightWatchdog?.cancel(); cycleTimer?.invalidate(); exportTimer?.invalidate()
        mb_viewport_destroy(viewport)
    }

    private static func coordinates(_ camera: OpaquePointer) -> (real:String,imag:String,span:String) {
        guard let text = mb_viewport_describe(camera) else { return ("","","") }
        defer { mb_string_free(text) }
        guard let object = try? JSONSerialization.jsonObject(with:Data(String(cString:text).utf8)) as? [String:Any] else { return ("","","") }
        return (object["real"] as? String ?? "",object["imag"] as? String ?? "",object["span"] as? String ?? "")
    }
    var coordinateStrings: (real:String,imag:String,span:String) { Self.coordinates(viewport) }
    var savedLocation: SavedLocation {
        let c = coordinateStrings
        return SavedLocation(mode:fractalMode,real:c.real,imag:c.imag,span:c.span,juliaReal:juliaReal,juliaImag:juliaImag,iterations:iterations,palette:palette,quality:quality,colorPhase:colorPhase,colorDensity:colorDensity,relief:relief,zoom:zoomLabel,cameraBits:Int(mb_viewport_precision(viewport)),adaptiveColorRange:adaptiveColorRange)
    }
    func encodedLocation() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        return try? encoder.encode(savedLocation)
    }
    private func persistLocation() {
        guard !isFlying && !isColorCycling else { return }
        if let data = encodedLocation() { preferences.set(data,forKey:"luma.lastLocation.v1") }
    }
    // Validate into temporary cameras before changing any visible state.
    private func validatedCamera(_ state: SavedLocation) -> OpaquePointer? {
        guard state.version == 1, state.iterations.isFinite, (256...1_000_000).contains(state.iterations),
              state.colorPhase.isFinite, (0...1).contains(state.colorPhase), state.colorDensity.isFinite,
              (0.2...3).contains(state.colorDensity), state.relief.isFinite, (0...1).contains(state.relief),
              [state.real,state.imag,state.span,state.juliaReal,state.juliaImag].allSatisfy({ !$0.isEmpty && $0.count <= 100_000 }) else { return nil }
        let camera = mb_viewport_create()!, parameter = mb_viewport_create()!
        defer { mb_viewport_destroy(parameter) }
        let restored: Int32
        if let bits = state.cameraBits {
            guard bits >= 128 && bits <= Int(Int32.max) else { mb_viewport_destroy(camera); return nil }
            restored = mb_viewport_restore(camera,state.real,state.imag,state.span,Int32(bits))
        } else { restored = mb_viewport_set(camera,state.real,state.imag,state.span) }
        guard restored == 1,
              mb_viewport_set(parameter,state.juliaReal,state.juliaImag,"3.5") == 1 else { mb_viewport_destroy(camera); return nil }
        return camera
    }
    private func assignSettings(_ state: SavedLocation) {
        fractalMode = state.mode; juliaReal = state.juliaReal; juliaImag = state.juliaImag
        iterations = state.iterations; palette = state.palette; quality = state.quality
        colorPhase = state.colorPhase; colorDensity = state.colorDensity; relief = state.relief
        adaptiveColorRange = state.adaptiveColorRange ?? true
    }
    @discardableResult func applyLocation(_ state: SavedLocation) -> Bool {
        guard let camera = validatedCamera(state) else { errorMessage = "This location has invalid coordinates or unsupported settings."; return false }
        stopAnimations(); remember(force:true)
        if fractalMode == .mandelbrot && state.mode == .julia { mandelbrotReturn = snapshot }
        mb_viewport_destroy(viewport); viewport = camera
        assignSettings(state); selectedDestination = ""; isPickingJulia = false
        updateReadouts(); persistLocation(); render()
        return true
    }
    func saveBookmark(name: String) {
        let name = name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        bookmarks.append(FractalBookmark(id:UUID(),name:String(name.prefix(120)),location:savedLocation))
        storeBookmarks(); status = "Location saved"
    }
    func restoreBookmark(_ bookmark: FractalBookmark) { _ = applyLocation(bookmark.location) }
    func deleteBookmark(_ bookmark: FractalBookmark) { bookmarks.removeAll { $0.id == bookmark.id }; storeBookmarks() }
    private func storeBookmarks() { if let data = try? JSONEncoder().encode(bookmarks) { preferences.set(data,forKey:"luma.bookmarks.v1") } }
    func importLocation() {
        stopAnimations()
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            do {
                let values = try url.resourceValues(forKeys:[.fileSizeKey])
                guard (values.fileSize ?? 0) <= 2*1024*1024 else { throw CocoaError(.fileReadTooLarge) }
                let state = try JSONDecoder().decode(SavedLocation.self,from:Data(contentsOf:url))
                _ = self.applyLocation(state)
            } catch { self.errorMessage = "Could not open this location: " + error.localizedDescription }
        }
    }
    func exportLocation() {
        stopAnimations()
        guard let data = encodedLocation() else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Luma-Location.json"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try data.write(to:url,options:.atomic) } catch { self?.errorMessage = error.localizedDescription }
        }
    }

    func resize(to newSize: CGSize) {
        guard newSize.width > 8, newSize.height > 8, abs(newSize.width-size.width)>1 || abs(newSize.height-size.height)>1 || image == nil else { return }
        size = newSize; render()
    }
    private func remember(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        if force || now-lastHistoryTime > 0.65 {
            history.append(snapshot)
            if history.count > 60 { history.removeFirst() }
            canGoBack = true
        }
        lastHistoryTime = now
    }
    func zoom(factor: Double, anchor: CGPoint = .zero) {
        guard factor.isFinite, factor > 0 else { return }
        stopFlight(); remember()
        mb_viewport_zoom(viewport,min(16,max(0.0625,factor)),Double(anchor.x),Double(anchor.y),Double(size.height/size.width))
        selectedDestination = ""; updateReadouts(); render()
    }
    func pan(dx: Double, dy: Double) {
        guard dx.isFinite, dy.isFinite else { return }
        stopFlight(); remember()
        mb_viewport_pan(viewport,-dx,-dy,Double(size.height/size.width))
        selectedDestination = ""; updateReadouts(); render()
    }
    func reset() {
        if fractalMode == .mandelbrot { visit(.overview) }
        else {
            stopFlight(); remember(force:true)
            _ = mb_viewport_set(viewport,"0","0","3.5")
            updateReadouts(); render()
        }
    }
    private func restore(_ prior: NavigationSnapshot) {
        mb_viewport_destroy(viewport); viewport = mb_viewport_clone(prior.camera.pointer)!
        fractalMode = prior.mode; juliaReal = prior.juliaReal; juliaImag = prior.juliaImag; iterations = prior.iterations
        selectedDestination = ""; isPickingJulia = false; updateReadouts(); render()
    }
    func goBack() {
        stopFlight()
        guard let prior = history.popLast() else { return }
        restore(prior); canGoBack = !history.isEmpty
    }
    func visit(_ destination: FractalDestination) {
        stopFlight(); remember(force:true); isPickingJulia = false; fractalMode = .mandelbrot
        let (r,i,s) = destination.location
        _ = mb_viewport_set(viewport,r,i,s)
        selectedDestination = destination.rawValue
        iterations = destination == .deepTest ? 50_000 : (destination == .spiral ? 1500 : 900)
        updateReadouts(); render()
    }
    func switchMode(_ mode: FractalMode) {
        guard mode != fractalMode else { return }
        stopFlight(); remember(force:true); isPickingJulia = false
        if mode == .julia {
            mandelbrotReturn = snapshot; fractalMode = .julia
            _ = mb_viewport_set(viewport,"0","0","3.5")
            iterations = 1200; selectedDestination = ""; updateReadouts(); render()
        } else if let prior = mandelbrotReturn { restore(prior) }
        else {
            fractalMode = .mandelbrot
            let (r,i,s) = FractalDestination.overview.location
            _ = mb_viewport_set(viewport,r,i,s)
            iterations = 900; selectedDestination = ""; updateReadouts(); render()
        }
    }
    @discardableResult func applyJuliaParameter(real: String, imag: String) -> Bool {
        let real = real.trimmingCharacters(in:.whitespacesAndNewlines), imag = imag.trimmingCharacters(in:.whitespacesAndNewlines)
        let camera = mb_viewport_create()!; defer { mb_viewport_destroy(camera) }
        guard real.count <= 100_000, imag.count <= 100_000, mb_viewport_set(camera,real,imag,"3.5") == 1 else { return false }
        stopFlight(); remember(force:true)
        if fractalMode == .mandelbrot { mandelbrotReturn = snapshot }
        fractalMode = .julia; juliaReal = real; juliaImag = imag; isPickingJulia = false
        _ = mb_viewport_set(viewport,"0","0","3.5")
        iterations = 1200; selectedDestination = ""; updateReadouts(); render()
        return true
    }
    func visitJulia(_ destination: JuliaDestination) { _ = applyJuliaParameter(real:destination.real,imag:destination.imag) }
    func toggleJuliaPicker() {
        stopFlight()
        if fractalMode != .mandelbrot { switchMode(.mandelbrot) }
        isPickingJulia.toggle()
    }
    func pickJulia(at anchor: CGPoint) {
        guard isPickingJulia, fractalMode == .mandelbrot else { return }
        let camera = mb_viewport_clone(viewport)!; defer { mb_viewport_destroy(camera) }
        mb_viewport_pan(camera,Double(anchor.x),Double(anchor.y),Double(size.height/size.width))
        let parameter = Self.coordinates(camera)
        _ = applyJuliaParameter(real:parameter.real,imag:parameter.imag)
    }
    @discardableResult func loadCoordinates(real: String, imag: String, span: String) -> Bool {
        let next = mb_viewport_clone(viewport)!
        guard mb_viewport_set(next,real.trimmingCharacters(in:.whitespacesAndNewlines),imag.trimmingCharacters(in:.whitespacesAndNewlines),span.trimmingCharacters(in:.whitespacesAndNewlines)) != 0 else {
            mb_viewport_destroy(next); errorMessage = "Enter finite decimal coordinates and a positive width, such as 1e-40."; return false
        }
        stopFlight(); remember(force:true); mb_viewport_destroy(viewport); viewport = next
        selectedDestination = ""; updateReadouts(); render(); return true
    }
    private func updateReadouts() {
        precision = Int(mb_viewport_precision(viewport))
        let depth = mb_viewport_log_zoom(viewport)
        zoomLabel = depth < 5 && depth > -3 ? String(format:"%.1f×",pow(10,depth)) : String(format:"10^%.1f×",depth)
        if depth.isFinite { setFlightIterations(max(iterations,min(1_000_000,ceil(max(0,depth)*2)+256))) }
    }
    func toggleFlight() {
        if isFlying && !isAutopiloting { stopFlight(); return }
        if isFlying { stopFlight(refine:false) }
        startFlight(autopilot:false)
    }
    func toggleAutopilot() {
        if isAutopiloting { stopFlight(); return }
        if isFlying { stopFlight(refine:false) }
        startFlight(autopilot:true)
    }
    private func setFlightIterations(_ value: Double) {
        settingFlightIterations = true; iterations = value; settingFlightIterations = false
    }
    private var effectiveIterations: Int { Int(iterations.isFinite ? max(256,min(1_000_000,iterations)) : 900) }
    private func startFlight(autopilot: Bool) {
        remember(force:true); isPickingJulia = false
        pending?.cancel(); currentJob?.cancel(); generation += 1; colorGeneration += 1
        flightEpoch += 1; flightWatchdog?.cancel()
        flightUserIterations = nil
        isFlying = true; isAutopiloting = autopilot; flightTransition = nil
        flightPresentedState = nil; flightAnalysis = nil; autopilotTarget = nil
        flightFramesCompleted = 0; flightRecoveries = 0; flightUninterestingFrames = 0; flightTimeouts = 0
        flightPixels = min(320_000,quality.pixelBudget); flightEstimate = 0.10; flightPublishAfter = 0
        autopilotStatus = autopilot ? "Looking for intricate edges" : "Following the center"
        flightFPSLabel = "Preparing motion"
        renderFlightFrame(transition:nil)
    }
    func stopFlight(refine: Bool = true) {
        guard isFlying else { return }
        flightEpoch += 1; flightWatchdog?.cancel(); flightWatchdog = nil
        currentJob?.cancel(); pending?.cancel(); generation += 1; colorGeneration += 1
        isFlying = false; isAutopiloting = false; isRendering = false
        flightTransition = nil; autopilotTarget = nil; flightFPSLabel = ""
        // A look-ahead camera may not yet be visible. Stop at the last published view.
        restorePresentedFlightState()
        if let requested = flightUserIterations { iterations = requested }
        flightUserIterations = nil
        flightPresentedState = nil; flightAnalysis = nil
        updateReadouts(); persistLocation()
        if refine { render() }
    }
    private func restorePresentedFlightState(preserveIterations: Bool = false) {
        guard let state = flightPresentedState else { return }
        mb_viewport_destroy(viewport); viewport = mb_viewport_clone(state.camera.pointer)!
        fractalMode = state.mode; juliaReal = state.juliaReal; juliaImag = state.juliaImag
        if !preserveIterations { setFlightIterations(state.iterations) }
    }
    private func restartFlightRendering() {
        flightEpoch += 1; flightWatchdog?.cancel(); currentJob?.cancel()
        generation += 1; colorGeneration += 1
        restorePresentedFlightState(preserveIterations:true)
        flightTransition = nil; flightPublishAfter = 0
        renderFlightFrame(transition:nil)
    }
    private func advanceFlight() {
        guard isFlying, !isRendering else { return }
        let speed = flightSpeed.isFinite ? min(2,max(0.15,flightSpeed)) : 1
        let duration = min(0.5,max(0.16,flightEstimate*1.3))
        var factor = exp(-duration*0.65*speed)
        var anchor = CGPoint.zero
        if isAutopiloting {
            if let analysis = flightAnalysis, analysis.hasStructure, let target = analysis.target {
                flightUninterestingFrames = 0
                anchor = target; autopilotTarget = target
                autopilotStatus = analysis.escapedFraction < 0.98 ? "Following a detailed boundary" : "Following spirals and filaments"
            } else {
                flightUninterestingFrames += 1; flightRecoveries += 1; autopilotTarget = nil
                if flightAnalysis?.needsMoreIterations == true && flightUninterestingFrames == 1 && effectiveIterations < 250_000 {
                    setFlightIterations(Double(min(250_000,effectiveIterations*2)))
                    autopilotStatus = "Looking deeper into the boundary"
                    renderFlightFrame(transition:nil)
                    return
                }
                factor = 1.35
                autopilotStatus = "Widening the search for detail"
                if flightUninterestingFrames >= 6 {
                    chooseFreshTrail()
                    renderFlightFrame(transition:nil)
                    return
                }
            }
        }
        mb_viewport_zoom(viewport,factor,Double(anchor.x),Double(anchor.y),Double(size.height/size.width))
        selectedDestination = ""; updateReadouts()
        let transition = FlightTransition(id:flightFramesCompleted+1,factor:factor,anchor:anchor,duration:duration)
        renderFlightFrame(transition:transition)
    }
    private func chooseFreshTrail() {
        flightTrailIndex += 1; flightUninterestingFrames = 0; flightTimeouts = 0
        if fractalMode == .mandelbrot {
            let trails: [FractalDestination] = [.seahorse,.spiral,.elephant]
            let place = trails[(flightTrailIndex-1)%trails.count]
            let (r,i,s) = place.location
            _ = mb_viewport_set(viewport,r,i,s)
            setFlightIterations(place == .spiral ? 1500 : 900)
        } else {
            let place = JuliaDestination.allCases[(flightTrailIndex-1)%JuliaDestination.allCases.count]
            juliaReal = place.real; juliaImag = place.imag
            _ = mb_viewport_set(viewport,"0","0","3.5"); setFlightIterations(1200)
        }
        flightAnalysis = nil; autopilotTarget = nil; flightTransition = nil; selectedDestination = ""
        autopilotStatus = "Starting a fresh trail"; updateReadouts()
    }
    private func renderFlightFrame(transition: FlightTransition?) {
        guard isFlying else { return }
        let token = flightEpoch, publicationTime = flightPublishAfter
        let aspect = Double(size.height/size.width)
        let width = max(128,Int(ceil(96/aspect)),Int(sqrt(flightPixels/aspect)))
        let height = max(1,Int((Double(width)*aspect).rounded()))
        let limit = Int32(effectiveIterations), mode = fractalMode, real = juliaReal, imag = juliaImag
        let chosen = style, previousTarget = autopilotTarget, analyzing = isAutopiloting
        let previousMapping = transition == nil ? nil : fieldMapping
        flightRequestedLimit = Int(limit); flightSize = size; flightQuality = quality
        let job = RenderJob(viewport); currentJob = job; isRendering = true
        status = "Flight · \(width) × \(height) · Full detail on pause"
        let watchdog = DispatchWorkItem { [weak job] in job?.cancel() }
        flightWatchdog = watchdog
        DispatchQueue.global(qos:.userInitiated).asyncAfter(deadline:.now()+1.5,execute:watchdog)
        queue.async { [weak self] in
            let start = ProcessInfo.processInfo.systemUptime
            var samples = [Float](repeating:-1,count:width*height)
            let result = mode == .mandelbrot ? mb_render(job.camera.pointer,Int32(width),Int32(height),limit,&samples,job.control) : mb_render_julia(job.camera.pointer,real,imag,Int32(width),Int32(height),limit,&samples,job.control)
            watchdog.cancel()
            let estimate = result == 1 ? FractalColorizer.estimateMapping(samples:samples,width:width,height:height) : .fixed
            let mapping = previousMapping?.smoothed(toward:estimate,amount:0.25) ?? estimate
            let rendered = result == 1 ? chosen.image(samples,width,height,mapping:mapping) : nil
            let analysis = result == 1 && analyzing ? AutopilotPlanner.analyze(samples:samples,width:width,height:height,iterationLimit:Int(limit),previousTarget:previousTarget) : nil
            let elapsed = ProcessInfo.processInfo.systemUptime-start
            var stats = MBRenderStats(); mb_render_control_get_stats(job.control,&stats)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isFlying, self.flightEpoch == token else { return }
                guard result == 1, let rendered else {
                    self.isRendering = false
                    if result == 0 {
                        self.flightTimeouts += 1; self.flightRecoveries += 1
                        self.flightPixels = max(24_000,self.flightPixels*0.4)
                        self.autopilotStatus = "Adapting to a demanding region"
                        self.restorePresentedFlightState()
                        if self.isAutopiloting && self.flightTimeouts >= 3 { self.chooseFreshTrail() }
                        else if self.flightTimeouts >= 2 { self.setFlightIterations(Double(max(256,Int(limit)/2))) }
                        if !self.isAutopiloting && self.flightTimeouts >= 3 && limit <= 256 {
                            self.stopFlight(refine:false); self.status = "Flight paused at a demanding region"
                            return
                        }
                        self.renderFlightFrame(transition:nil)
                    } else {
                        self.stopFlight(refine:false); self.status = "Flight paused"; self.errorMessage = "This view exceeded available rendering resources. Try a lower detail setting."
                    }
                    return
                }
                self.flightTimeouts = 0
                self.flightEstimate = self.flightFramesCompleted == 0 ? elapsed : self.flightEstimate*0.65+elapsed*0.35
                // Target roughly 100 ms of compute; rendering is separate from display refresh.
                let adjustment = min(1.25,max(0.45,0.10/max(0.001,elapsed)))
                self.flightPixels = min(600_000,max(24_000,self.flightPixels*adjustment))
                let delay = max(0,publicationTime-ProcessInfo.processInfo.systemUptime)
                DispatchQueue.main.asyncAfter(deadline:.now()+delay) { [weak self] in
                    guard let self, self.isFlying, self.flightEpoch == token else { return }
                    self.flightTransition = transition
                    self.fieldGeneration += 1; self.fieldRenderGeneration = self.generation; self.field = samples; self.fieldWidth = width; self.fieldHeight = height; self.fieldMapping = mapping
                    self.colorGeneration += 1
                    // Always publish a geometric keyframe, even while palette animation is active.
                    self.image = rendered
                    if self.style != chosen { self.recolorCurrentField() }
                    self.flightPresentedState = NavigationSnapshot(camera:CameraSnapshot(job.camera.pointer),mode:mode,juliaReal:real,juliaImag:imag,iterations:Double(limit))
                    self.flightAnalysis = analysis; self.flightFramesCompleted += 1
                    self.flightRenderMilliseconds = elapsed*1000; self.flightPixelCount = width*height
                    self.precision = Int(stats.precision_bits)
                    self.elapsedLabel = String(format:"%.0f ms",elapsed*1000)
                    let cadence = max(transition?.duration ?? 0.16,elapsed)
                    self.flightFPSLabel = String(format:"%.1f new views/s",1/cadence)
                    self.status = "Flight · \(width) × \(height) · Full detail on pause"
                    self.flightPublishAfter = ProcessInfo.processInfo.systemUptime+(transition?.duration ?? 0)
                    self.isRendering = false
                    // Prefetch immediately while the canvas animates the published pair.
                    DispatchQueue.main.async { [weak self] in self?.advanceFlight() }
                }
            }
        }
    }
    func toggleColorCycle() {
        if isColorCycling { cycleTimer?.invalidate(); cycleTimer = nil; isColorCycling = false; persistLocation(); return }
        isColorCycling = true
        let timer = Timer(timeInterval:1.0/30,repeats:true) { [weak self] _ in
            guard let self else { return }
            self.colorPhase = (self.colorPhase + 0.0025).truncatingRemainder(dividingBy:1)
            self.recolorCurrentField()
        }
        cycleTimer = timer; RunLoop.main.add(timer,forMode:.common)
    }
    func stopAnimations() {
        stopFlight()
        cycleTimer?.invalidate(); cycleTimer = nil; isColorCycling = false; isPickingJulia = false
        persistLocation()
    }

    func render() {
        if isFlying {
            if flightRequestedLimit != effectiveIterations || flightSize != size || flightQuality != quality { restartFlightRendering() }
            return
        }
        pending?.cancel(); currentJob?.cancel(); colorGeneration += 1
        generation += 1
        let token = generation
        isRendering = true; status = "Resolving detail"
        let work = DispatchWorkItem { [weak self] in self?.beginRender(token:token) }
        pending = work; DispatchQueue.main.asyncAfter(deadline:.now()+0.035,execute:work)
    }
    private func beginRender(token: Int) {
        guard token == generation else { return }
        let scale = min(2,sqrt(quality.pixelBudget/Double(size.width*size.height)))
        let width = max(64,Int(size.width*scale)), height = max(64,Int(size.height*scale))
        let limit = Int32(iterations.isFinite ? max(256,min(1_000_000,iterations)) : 900)
        let activeStyle = style, mode = fractalMode, real = juliaReal, imag = juliaImag
        let coordinates = coordinateStrings
        let cacheKey = "\(mode.rawValue)|\(mode == .julia ? real : "")|\(mode == .julia ? imag : "")|\(coordinates.real)|\(coordinates.imag)|\(coordinates.span)|\(width)|\(height)|\(limit)"
        if let index = frames.firstIndex(where:{ $0.key == cacheKey }) {
            let frame = frames.remove(at:index); frames.append(frame)
            fieldGeneration += 1; fieldRenderGeneration = token; field = frame.samples; fieldWidth = frame.width; fieldHeight = frame.height; fieldMapping = frame.mapping; colorGeneration += 1
            if frame.style == style { image = frame.image } else { recolorCurrentField() }
            isRendering = false; elapsedLabel = "Cached"; precision = frame.precision
            status = frame.wideExponent ? "Extended range · \(width) × \(height)" : "\(width) × \(height) · Ready"
            persistLocation(); return
        }
        let job = RenderJob(viewport); currentJob = job
        let previewScale = min(1,420.0/Double(width))
        let passes = previewScale < 0.8 ? [(max(32,Int(Double(width)*previewScale)),max(32,Int(Double(height)*previewScale))),(width,height)] : [(width,height)]
        queue.async { [weak self] in
            let start = ProcessInfo.processInfo.systemUptime
            for (index,dimensions) in passes.enumerated() {
                let (w,h) = dimensions
                var samples = [Float](repeating:-1,count:w*h)
                let result = mode == .mandelbrot ? mb_render(job.camera.pointer,Int32(w),Int32(h),limit,&samples,job.control) : mb_render_julia(job.camera.pointer,real,imag,Int32(w),Int32(h),limit,&samples,job.control)
                guard result == 1 else {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == token else { return }
                        self.isRendering = false; self.stopFlight()
                        self.status = result == 0 ? "Render cancelled" : "Render could not complete"
                        if result < 0 { self.errorMessage = "This view exceeded the available rendering resources. Try a lower detail or quality setting." }
                    }
                    return
                }
                let mapping = FractalColorizer.estimateMapping(samples:samples,width:w,height:h)
                let rendered = activeStyle.image(samples,w,h,mapping:mapping), final = index == passes.count-1
                let elapsed = ProcessInfo.processInfo.systemUptime-start
                var stats = MBRenderStats(); mb_render_control_get_stats(job.control,&stats)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.fieldGeneration += 1; self.fieldRenderGeneration = token; self.field = samples; self.fieldWidth = w; self.fieldHeight = h; self.fieldMapping = mapping; self.colorGeneration += 1
                    if self.style == activeStyle { self.image = rendered } else { self.recolorCurrentField() }
                    self.isRendering = !final; self.elapsedLabel = String(format:"%.2f s",elapsed)
                    self.precision = Int(stats.precision_bits)
                    self.status = final ? (stats.wide_exponent != 0 ? "Extended range · \(w) × \(h)" : "\(w) × \(h) · Ready") : "Refining \(width) × \(height)"
                    if final {
                        self.frames.append(CachedFrame(key:cacheKey,samples:samples,width:w,height:h,image:rendered,style:activeStyle,mapping:mapping,precision:Int(stats.precision_bits),wideExponent:stats.wide_exponent != 0))
                        while self.frames.count > 3 || self.frames.reduce(0,{ $0+$1.byteCount }) > 64*1024*1024 { self.frames.removeFirst() }
                        self.persistLocation()
                    }
                }
            }
        }
    }

    func recolor() {
        preferences.set(palette.rawValue,forKey:"palette")
        recolorCurrentField(); persistLocation()
    }
    // At most one color pass runs at a time; animation coalesces to the latest style.
    private func recolorCurrentField() {
        guard !field.isEmpty else { return }
        colorGeneration += 1
        if coloring { colorAgain = true; return }
        coloring = true; colorAgain = false
        let token = colorGeneration, fieldToken = fieldGeneration, renderToken = generation
        let samples = field, width = fieldWidth, height = fieldHeight, chosen = style, mapping = fieldMapping
        colorQueue.async { [weak self] in
            let result = chosen.image(samples,width,height,mapping:mapping)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.coloring = false
                if self.colorGeneration == token || (self.isColorCycling && self.fieldGeneration == fieldToken && self.generation == renderToken) { self.image = result }
                if self.colorAgain { self.recolorCurrentField() }
            }
        }
    }
    static func makeImage(samples: [Float], width: Int, height: Int, palette: FractalPalette) -> CGImage? {
        FractalColorizer.image(samples:samples,width:width,height:height,palette:palette)
    }
    func exportPNG() {
        guard let image else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "Luma-\(palette.title).png"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try Self.pngData(image).write(to:url,options:.atomic) } catch { self?.errorMessage = error.localizedDescription }
        }
    }
    func export4K() {
        guard !isExporting else { return }
        stopAnimations()
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "Luma-4K.png"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.exportImage(to:url)
        }
    }
    func exportImage(to url: URL, longEdge: Int = 3840) {
        guard !isExporting, (64...8192).contains(longEdge) else { return }
        let scale = Double(longEdge)/max(size.width,size.height)
        let width = max(1,Int((size.width*scale).rounded())), height = max(1,Int((size.height*scale).rounded()))
        let job = RenderJob(viewport), activeStyle = style, mode = fractalMode, real = juliaReal, imag = juliaImag
        // Match the displayed exposure when it belongs to this camera. A new
        // pending camera instead derives exposure from its own export field.
        let exportMapping: FractalColorizer.Mapping? = !isRendering && fieldRenderGeneration == generation && !field.isEmpty ? fieldMapping : nil
        let limit = Int32(iterations.isFinite ? max(256,min(1_000_000,iterations)) : 900)
        exportGeneration += 1
        let token = exportGeneration
        exportJob = job; isExporting = true; exportProgress = 0
        let timer = Timer(timeInterval:0.2,repeats:true) { [weak self] _ in
            guard let self, self.exportGeneration == token else { return }
            self.exportProgress = 0.95*mb_render_control_progress(job.control)
        }
        exportTimer = timer; RunLoop.main.add(timer,forMode:.common)
        exportQueue.async { [weak self] in
            var samples = [Float](repeating:-1,count:width*height)
            let result = mode == .mandelbrot ? mb_render(job.camera.pointer,Int32(width),Int32(height),limit,&samples,job.control) : mb_render_julia(job.camera.pointer,real,imag,Int32(width),Int32(height),limit,&samples,job.control)
            let image = result == 1 ? activeStyle.image(samples,width,height,mapping:exportMapping) : nil
            let data = image.map { Self.pngData($0) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.exportGeneration == token else { return }
                self.exportTimer?.invalidate(); self.exportTimer = nil; self.exportJob = nil; self.isExporting = false
                guard result == 1, let data else { self.errorMessage = "Export could not complete. Try a lower iteration count."; return }
                do { try data.write(to:url,options:.atomic); self.exportProgress = 1; self.status = "Saved \(width) × \(height) PNG" }
                catch { self.errorMessage = error.localizedDescription }
            }
        }
    }
    func cancelExport() {
        exportGeneration += 1; exportJob?.cancel(); exportJob = nil
        exportTimer?.invalidate(); exportTimer = nil; isExporting = false; exportProgress = 0
    }
    static func pngData(_ image: CGImage) -> Data { NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])! }
    func copyCoordinates() {
        stopFlight()
        let c = coordinateStrings
        var text = "Mode: \(fractalMode.title)\nReal: \(c.real)\nImaginary: \(c.imag)\nWidth: \(c.span)\nIterations: \(Int(iterations.isFinite ? max(256,min(1_000_000,iterations)) : 900))"
        if fractalMode == .julia { text += "\nJulia c: \(juliaReal) + (\(juliaImag))i" }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType:.string); status = "Coordinates copied"
    }
}

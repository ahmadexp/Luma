import Foundation

enum FractalMode: String, CaseIterable, Identifiable, Codable {
    case mandelbrot, julia
    var id: String { rawValue }
    var title: String { self == .mandelbrot ? "Mandelbrot" : "Julia" }
}

enum JuliaDestination: String, CaseIterable, Identifiable {
    case dragon, dendrite, spiral, galaxy
    var id: String { rawValue }
    var title: String {
        switch self { case .dragon: return "Dragon islands"; case .dendrite: return "Electric dendrites"; case .spiral: return "Spiral nebula"; case .galaxy: return "Spinning galaxies" }
    }
    var subtitle: String {
        switch self { case .dragon: return "Interlocking curls and islands"; case .dendrite: return "Branching, crystalline filaments"; case .spiral: return "A universe of tiny spirals"; case .galaxy: return "Swirling arms and starbursts" }
    }
    var real: String {
        switch self { case .dragon: return "-0.8"; case .dendrite: return "-0.4"; case .spiral: return "0.285"; case .galaxy: return "-0.835" }
    }
    var imag: String {
        switch self { case .dragon: return "0.156"; case .dendrite: return "0.6"; case .spiral: return "0.01"; case .galaxy: return "-0.2321" }
    }
}

// Decimal strings preserve the entire arbitrary-precision camera through JSON.
struct SavedLocation: Codable {
    var version = 1
    var mode: FractalMode
    var real: String
    var imag: String
    var span: String
    var juliaReal: String
    var juliaImag: String
    var iterations: Double
    var palette: FractalPalette
    var quality: RenderQuality
    var colorPhase: Double
    var colorDensity: Double
    var relief: Double
    var zoom: String
    var cameraBits: Int? = nil
    var adaptiveColorRange: Bool? = nil
}

struct FractalBookmark: Codable, Identifiable {
    let id: UUID
    let name: String
    let location: SavedLocation
    var mode: FractalMode { location.mode }
    var zoom: String { location.zoom }
}

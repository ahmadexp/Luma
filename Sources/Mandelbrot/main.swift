import AppKit
import SwiftUI

struct LumaApp: App {
    @StateObject private var model = ExplorerModel()
    var body: some Scene {
        WindowGroup("Luma") {
            ContentView(model:model)
                .preferredColorScheme(.dark)
                .frame(minWidth:980,minHeight:650)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width:1280,height:820)
        .commands {
            CommandGroup(replacing:.newItem) { }
            CommandGroup(after:.saveItem) {
                Button("Render 4K PNG…") { model.export4K() }.disabled(model.isExporting)
                Button("Import Location…") { model.importLocation() }.keyboardShortcut("o",modifiers:.command)
                Button("Export Location…") { model.exportLocation() }
                Button("Save Bookmark…") { model.showBookmarkEditor = true }.keyboardShortcut("d",modifiers:.command)
                Button("Export PNG…") { model.exportPNG() }.keyboardShortcut("s",modifiers:[.command,.shift])
                Button("Copy Coordinates") { model.copyCoordinates() }.keyboardShortcut("c",modifiers:[.command,.shift])
            }
            CommandMenu("Explore") {
                Button("Zoom In") { model.zoom(factor:0.5) }.keyboardShortcut("=",modifiers:.command)
                Button("Zoom Out") { model.zoom(factor:2) }.keyboardShortcut("-",modifiers:.command)
                Button("Previous View") { model.goBack() }.keyboardShortcut("[",modifiers:.command).disabled(!model.canGoBack)
                Button("Reset View") { model.reset() }.keyboardShortcut("0",modifiers:.command)
                Divider()
                Button("Go to Coordinates…") { model.showCoordinateEditor = true }.keyboardShortcut("l",modifiers:.command)
                Button(model.isAutopiloting ? "Stop Autopilot" : "Start Autopilot") { model.toggleAutopilot() }.keyboardShortcut("a",modifiers:[.command,.shift])
                Button(model.isFlying && !model.isAutopiloting ? "Stop Center Flight" : "Start Center Flight") { model.toggleFlight() }.keyboardShortcut("f",modifiers:[.command,.shift])
                Button("Pick a Julia Set") { model.toggleJuliaPicker() }.keyboardShortcut("j",modifiers:.command)
                Button(model.isColorCycling ? "Stop Color Cycle" : "Animate Colors") { model.toggleColorCycle() }
                Button("Stop Animations") { model.stopAnimations() }
                Divider()
                ForEach(FractalDestination.allCases) { destination in Button(destination.title) { model.visit(destination) } }
            }
        }
    }
}

if CommandLine.arguments.contains("--pipeline-check") {
    runPipelineChecks()
} else if CommandLine.arguments.contains("--render-check") {
    runRenderChecks()
} else {
    NSApplication.shared.setActivationPolicy(.regular)
    DispatchQueue.main.async { NSApplication.shared.activate(ignoringOtherApps:true) }
    LumaApp.main()
}

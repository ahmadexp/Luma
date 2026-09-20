import SwiftUI

private enum LumaStyle {
    static let background = Color(red: 0.035, green: 0.044, blue: 0.066)
    static let panel = Color(red: 0.066, green: 0.077, blue: 0.103)
    static let muted = Color(red: 0.51, green: 0.56, blue: 0.65)
    static let accent = Color(red: 0.40, green: 0.87, blue: 0.87)
    static let line = Color.white.opacity(0.075)
}

private enum InspectorTab: String, CaseIterable, Identifiable {
    case explore, studio, library
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .explore: return "safari"
        case .studio: return "slider.horizontal.3"
        case .library: return "books.vertical"
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: ExplorerModel
    @State private var inspectorTab: InspectorTab = .explore

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(LumaStyle.line).frame(height: 1)
            HStack(spacing: 0) {
                canvas
                Rectangle().fill(LumaStyle.line).frame(width: 1)
                inspector.frame(width: 264)
            }
        }
        .frame(minWidth: 980, minHeight: 650)
        .background(LumaStyle.background)
        .preferredColorScheme(.dark)
        .tint(LumaStyle.accent)
        .onExitCommand { model.stopAnimations() }
        .onChange(of: model.palette) { model.recolor() }
        .onChange(of: model.colorPhase) { if !model.isColorCycling { model.recolor() } }
        .onChange(of: model.colorDensity) { model.recolor() }
        .onChange(of: model.adaptiveColorRange) { model.recolor() }
        .onChange(of: model.relief) { model.recolor() }
        .onChange(of: model.iterations) { model.render() }
        .onChange(of: model.quality) { model.render() }
        .sheet(isPresented: $model.showCoordinateEditor) {
            CoordinateEditor(model: model)
        }
        .sheet(isPresented: $model.showBookmarkEditor) {
            BookmarkEditor(model: model)
        }
        .alert("Unable to complete the request", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(
                    LinearGradient(colors: [LumaStyle.accent.opacity(0.22), Color.purple.opacity(0.16)], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                Image(systemName: "sparkle").font(.system(size: 21, weight: .medium)).foregroundStyle(LumaStyle.accent)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("LUMA").font(.system(size: 15, weight: .semibold, design: .rounded)).tracking(3.5)
                Text("THE FRACTAL EXPLORER").font(.system(size: 8, weight: .medium)).tracking(1.6).foregroundStyle(LumaStyle.muted)
            }
            Spacer()
            HStack(spacing: 6) {
                if model.isExporting {
                    ProgressView(value: model.exportProgress).frame(width: 45).controlSize(.small)
                    Text("4K export").font(.system(size: 10)).foregroundStyle(LumaStyle.muted)
                    Button { model.cancelExport() } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(LumaStyle.muted)
                    }
                    .buttonStyle(.plain).help("Cancel 4K export").accessibilityLabel("Cancel 4K export")
                } else {
                    Circle().fill(model.isRendering && !model.isFlying ? Color.orange : LumaStyle.accent).frame(width: 5, height: 5)
                    Text(model.isFlying ? (model.isAutopiloting ? "Autopilot exploring" : "Flying") : (model.isRendering ? "Rendering detail" : "Ready to explore"))
                        .font(.system(size: 11)).foregroundStyle(LumaStyle.muted)
                }
            }
            .padding(.trailing, 14)
            Button { model.showCoordinateEditor = true } label: {
                Label("Coordinates", systemImage: "scope").font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(HeaderButtonStyle())
            .help("Enter or copy an exact location")
            Button {
                inspectorTab = .studio
                model.toggleAutopilot()
            } label: {
                Label(model.isAutopiloting ? "Stop autopilot" : "Autopilot",
                      systemImage: model.isAutopiloting ? "stop.fill" : "location.north.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LumaStyle.accent)
            }
            .buttonStyle(HeaderButtonStyle())
            .help(model.isAutopiloting ? "Stop automatic exploration (Escape)" : "Automatically steer toward detailed fractal boundaries")
            Button {
                inspectorTab = .library
                model.showBookmarkEditor = true
            } label: {
                Image(systemName: "bookmark").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(HeaderButtonStyle())
            .help("Save this view to your library")
            .accessibilityLabel("Save bookmark")
            Menu {
                Button("Save current image…") { model.exportPNG() }
                Button("Render 4K image…") { model.export4K() }
                    .disabled(model.isExporting)
            } label: {
                Label("Export image", systemImage: "square.and.arrow.up")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.06), lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(model.image == nil)
            .help("Save the current image or render a detailed 4K image")
        }
        .padding(.horizontal, 22)
        .frame(height: 70)
    }

    private var canvas: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ZStack {
                    FractalCanvas(model: model)
                        .onAppear { model.resize(to: geometry.size) }
                        .onChange(of: geometry.size) { _, size in model.resize(to: size) }
                    if model.image == nil {
                        VStack(spacing: 12) {
                            ProgressView().controlSize(.small)
                            Text("Finding the edge of infinity").font(.system(size: 12)).foregroundStyle(LumaStyle.muted)
                        }
                        .allowsHitTesting(false)
                    }
                    if model.isAutopiloting, let target = model.autopilotTarget,
                       target.x.isFinite, target.y.isFinite {
                        Image(systemName: "scope")
                            .font(.system(size: 30, weight: .ultraLight))
                            .foregroundStyle(LumaStyle.accent.opacity(0.65))
                            .shadow(color: .black.opacity(0.6), radius: 3)
                            .position(x: (min(0.5, max(-0.5, target.x)) + 0.5) * geometry.size.width,
                                      y: (0.5 - min(0.5, max(-0.5, target.y))) * geometry.size.height)
                            .animation(.easeInOut(duration: 0.45), value: target)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    VStack {
                        HStack(alignment: .top) {
                            navigationControls
                            Spacer()
                            HStack(spacing: 9) {
                                Text(model.fractalMode.title.uppercased())
                                    .font(.system(size: 8, weight: .semibold)).tracking(1.2)
                                Text(model.fractalMode == .julia ? "zₙ₊₁ = zₙ² + c  ·  c fixed" : "zₙ₊₁ = zₙ² + c")
                                    .font(.system(size: 12, weight: .regular, design: .serif))
                            }
                            .foregroundStyle(.white.opacity(0.55))
                            .padding(.horizontal, 13).padding(.vertical, 9)
                            .background(.black.opacity(0.25), in: Capsule())
                        }
                        Spacer()
                        HStack(alignment: .bottom) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("MAGNIFICATION").font(.system(size: 8, weight: .semibold)).tracking(1.8).foregroundStyle(.white.opacity(0.48))
                                Text(model.zoomLabel).font(.system(size: 29, weight: .light, design: .monospaced)).contentTransition(.numericText())
                            }
                            .padding(.horizontal, 16).padding(.vertical, 13)
                            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                            Spacer()
                            if model.isRendering && !model.isFlying {
                                HStack(spacing: 7) {
                                    ProgressView().controlSize(.mini)
                                    Text("Resolving detail").font(.system(size: 10))
                                }
                                .foregroundStyle(.white.opacity(0.75))
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .background(.black.opacity(0.4), in: Capsule())
                            }
                        }
                    }
                    .padding(22)
                    if model.isPickingJulia {
                        VStack(spacing: 12) {
                            Image(systemName: "scope")
                                .font(.system(size: 40, weight: .ultraLight))
                                .foregroundStyle(LumaStyle.accent)
                            VStack(spacing: 6) {
                                Text("Choose a Julia world").font(.system(size: 16, weight: .medium, design: .serif))
                                Text("Click a point on the Mandelbrot set.\nIts coordinate becomes the Julia parameter.")
                                    .font(.system(size: 11)).lineSpacing(3).multilineTextAlignment(.center)
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                            .padding(16)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottom) { canvasActivity.padding(.bottom, 112) }
                .clipped()
            }
            canvasFooter
        }
    }

    @ViewBuilder private var canvasActivity: some View {
        if model.isPickingJulia {
            Button { model.toggleJuliaPicker() } label: {
                Label("Cancel selection", systemImage: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 15).padding(.vertical, 10)
                    .background(.black.opacity(0.65), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Cancel Julia selection (Escape)")
        } else if model.isFlying && !model.isAutopiloting {
            HStack(spacing: 12) {
                Image(systemName: "location.north.fill")
                    .foregroundStyle(LumaStyle.accent)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 9) {
                        Text("Center flight")
                            .font(.system(size: 11, weight: .medium))
                        if !model.flightFPSLabel.isEmpty {
                            Text(model.flightFPSLabel).font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(LumaStyle.accent.opacity(0.8))
                                .help("Flight update rate")
                        }
                    }
                    Text("Flying into the center")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    Text("\(String(format: "%.1f", model.flightSpeed))× speed  ·  Escape to stop")
                        .font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
                }
                .frame(maxWidth: 260, alignment: .leading)
                Button { model.stopFlight() } label: {
                    Label("Stop", systemImage: "stop.fill").font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Stop the zoom flight")
            }
            .padding(.horizontal, 15).padding(.vertical, 11)
            .background(.black.opacity(0.65), in: Capsule())
            .overlay(Capsule().stroke(LumaStyle.accent.opacity(0.2), lineWidth: 1))
        }
    }

    private var navigationControls: some View {
        HStack(spacing: 3) {
            canvasButton("arrow.uturn.backward", label: "Go back", enabled: model.canGoBack) { model.goBack() }
            canvasButton("house", label: "Reset view") { model.reset() }
            Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 17).padding(.horizontal, 5)
            canvasButton("minus", label: "Zoom out") { model.zoom(factor: 2) }
            canvasButton("plus", label: "Zoom in") { model.zoom(factor: 0.5) }
        }
        .padding(5)
        .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(0.1), lineWidth: 1))
    }

    private func canvasButton(_ symbol: String, label: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .frame(width: 29, height: 27).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(enabled ? 0.85 : 0.25))
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }

    private var canvasFooter: some View {
        HStack(spacing: 7) {
            Image(systemName: "hand.draw").font(.system(size: 11))
            Text(model.isPickingJulia ? "Click to choose a Julia parameter  ·  Escape to cancel" : "Drag to move  ·  Scroll or pinch to zoom  ·  Double-click to dive in")
                .font(.system(size: 10))
            Spacer(minLength: 8)
            Text(model.elapsedLabel).font(.system(size: 10, design: .monospaced))
        }
        .foregroundStyle(LumaStyle.muted)
        .padding(.horizontal, 18)
        .frame(height: 35)
        .background(LumaStyle.background)
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(InspectorTab.allCases) { tab in
                    Button { inspectorTab = tab } label: {
                        VStack(spacing: 7) {
                            HStack(spacing: 5) {
                                Image(systemName: tab.symbol).font(.system(size: 10))
                                Text(tab.title).font(.system(size: 10, weight: .medium))
                            }
                            .foregroundStyle(inspectorTab == tab ? LumaStyle.accent : LumaStyle.muted)
                            .frame(maxWidth: .infinity)
                            Capsule().fill(inspectorTab == tab ? LumaStyle.accent : .clear).frame(height: 2)
                        }
                        .padding(.top, 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.title + " controls")
                    .accessibilityAddTraits(inspectorTab == tab ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch inspectorTab {
                    case .explore: exploreControls
                    case .studio: studioControls
                    case .library: libraryControls
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22).padding(.vertical, 22)
            }
            .scrollIndicators(.hidden)
            divider
            precisionSection.padding(.horizontal, 22).padding(.vertical, 17)
        }
        .background(LumaStyle.panel)
    }

    private var exploreControls: some View {
        Group {
            VStack(alignment: .leading, spacing: 12) {
                Text("A world within").font(.system(size: 22, weight: .medium, design: .serif))
                Picker("Fractal", selection: Binding(get: { model.fractalMode }, set: { model.switchMode($0) })) {
                    ForEach(FractalMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                Text(model.fractalMode == .mandelbrot ? "Follow a boundary, or choose a point to discover its Julia set." : "One fixed parameter creates an entirely different world.")
                    .font(.system(size: 10)).lineSpacing(3).foregroundStyle(LumaStyle.muted)
            }
            if model.fractalMode == .mandelbrot {
                Button { model.toggleJuliaPicker() } label: {
                    Label(model.isPickingJulia ? "Cancel Julia selection" : "Pick a Julia set", systemImage: "scope")
                        .font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).controlSize(.regular)
                .help("Choose a point on the Mandelbrot canvas to explore its Julia set")
                destinationsSection
            } else {
                juliaDestinationsSection
                JuliaParameterEditor(model: model)
            }
            divider
            detailSection
        }
    }

    private var studioControls: some View {
        Group {
            VStack(alignment: .leading, spacing: 6) {
                Text("Make it yours").font(.system(size: 22, weight: .medium, design: .serif))
                Text("Shape the light. Set your own pace.")
                    .font(.system(size: 10)).foregroundStyle(LumaStyle.muted)
            }
            flightSection
            divider
            paletteSection
            VStack(spacing: 15) {
                studioSlider("Color phase", value: $model.colorPhase, range: 0...1,
                             display: "\(Int(model.colorPhase * 100))%", help: "Shift the palette along the fractal bands")
                studioSlider("Color density", value: $model.colorDensity, range: 0.2...3,
                             display: String(format: "%.2f×", model.colorDensity), help: "Change how tightly colors repeat")
                Toggle("Adaptive color range", isOn: $model.adaptiveColorRange)
                    .font(.system(size: 11)).toggleStyle(.switch).controlSize(.mini)
                    .help("Keep colors spread across visible detail when a deep zoom narrows the range of escape values. Turn off for the original palette mapping.")
                studioSlider("Relief", value: $model.relief, range: 0...1,
                             display: "\(Int(model.relief * 100))%", help: "Add shaded contours to bring out surface detail")
            }
            Toggle(isOn: Binding(get: { model.isColorCycling }, set: { enabled in
                if enabled != model.isColorCycling { model.toggleColorCycle() }
            })) {
                Label("Animate colors", systemImage: "paintpalette").font(.system(size: 11))
            }
            .toggleStyle(.switch).controlSize(.mini)
            .help("Continuously shift the color palette")
        }
    }

    private func studioSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, display: String, help: String) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(title).font(.system(size: 11))
                Spacer()
                Text(display).font(.system(size: 10, design: .monospaced)).foregroundStyle(LumaStyle.accent)
            }
            Slider(value: value, in: range).controlSize(.small)
                .accessibilityLabel(title).help(help)
        }
    }

    private var flightSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            sectionLabel("AUTOMATIC EXPLORATION")
            Text("Autopilot finds detailed edges and steers toward them as you zoom.")
                .font(.system(size: 10)).lineSpacing(3).foregroundStyle(LumaStyle.muted)
            Button { model.toggleAutopilot() } label: {
                Label(model.isAutopiloting ? "Stop autopilot" : "Start autopilot",
                      systemImage: model.isAutopiloting ? "stop.fill" : "location.north.circle.fill")
                    .font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.regular)
            .help(model.isAutopiloting ? "Stop automatic exploration (Escape)" : "Let Luma choose and follow interesting boundaries")
            if model.isAutopiloting {
                Text(model.autopilotStatus).font(.system(size: 10)).lineSpacing(3)
                    .foregroundStyle(LumaStyle.accent.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            studioSlider("Flight speed", value: $model.flightSpeed, range: 0.15...2,
                         display: String(format: "%.1f×", model.flightSpeed), help: "Adjust zoom speed for autopilot or center flight")
            Button {
                if model.isFlying && !model.isAutopiloting { model.stopFlight() }
                else { model.toggleFlight() }
            } label: {
                Label(model.isAutopiloting ? "Switch to center flight" : (model.isFlying ? "Stop center flight" : "Start center flight"),
                      systemImage: model.isFlying && !model.isAutopiloting ? "stop.fill" : "location.north.fill")
                    .font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).controlSize(.regular)
            .help(model.isFlying && !model.isAutopiloting ? "Stop zooming (Escape)" : "Zoom straight into the center without automatic steering")
            Text("Center flight follows the point you place in the middle.")
                .font(.system(size: 9)).foregroundStyle(LumaStyle.muted)
        }
    }

    private var libraryControls: some View {
        Group {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your discoveries").font(.system(size: 22, weight: .medium, design: .serif))
                Text("Keep the places worth coming back to.")
                    .font(.system(size: 10)).foregroundStyle(LumaStyle.muted)
            }
            Button { model.showBookmarkEditor = true } label: {
                Label("Save this view", systemImage: "bookmark.fill")
                    .font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.regular)
            if model.bookmarks.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "books.vertical").font(.system(size: 25, weight: .light)).foregroundStyle(LumaStyle.accent.opacity(0.7))
                    Text("A collection starts here").font(.system(size: 11, weight: .medium))
                    Text("Save an exact location, including its colors and detail settings.")
                        .font(.system(size: 10)).lineSpacing(3).foregroundStyle(LumaStyle.muted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 20).padding(.horizontal, 12)
                .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    sectionLabel("SAVED VIEWS · \(model.bookmarks.count)")
                    ForEach(model.bookmarks) { bookmark in
                        HStack(spacing: 5) {
                            Button { model.restoreBookmark(bookmark) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(bookmark.name).font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.9)).lineLimit(2)
                                    Text("\(bookmark.mode.title)  ·  \(bookmark.zoom)")
                                        .font(.system(size: 9)).foregroundStyle(LumaStyle.muted).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 11).padding(.leading, 11)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).help("Restore \(bookmark.name)")
                            Button { model.deleteBookmark(bookmark) } label: {
                                Image(systemName: "trash").font(.system(size: 10)).foregroundStyle(LumaStyle.muted)
                                    .frame(width: 28, height: 32)
                            }
                            .buttonStyle(.plain).help("Delete \(bookmark.name)")
                            .accessibilityLabel("Delete bookmark \(bookmark.name)")
                        }
                        .padding(.trailing, 3)
                        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            divider
            VStack(alignment: .leading, spacing: 12) {
                sectionLabel("LOCATION FILES")
                Text("Take a discovery with you, or open a shared location.")
                    .font(.system(size: 10)).lineSpacing(3).foregroundStyle(LumaStyle.muted)
                HStack(spacing: 8) {
                    Button { model.importLocation() } label: {
                        Label("Import", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                    }
                    Button { model.exportLocation() } label: {
                        Label("Export", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                }
                .font(.system(size: 10)).buttonStyle(.bordered).controlSize(.regular)
            }
            exportSection
        }
    }

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            divider
            sectionLabel("HIGH RESOLUTION IMAGE")
            if model.isExporting {
                HStack {
                    Text("Rendering 4K").font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text(model.exportProgress.formatted(.percent.precision(.fractionLength(0))))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(LumaStyle.accent)
                }
                ProgressView(value: model.exportProgress).tint(LumaStyle.accent)
                Button("Cancel export") { model.cancelExport() }
                    .font(.system(size: 10)).buttonStyle(.bordered).controlSize(.small)
            } else {
                Text("Render fresh detail for a 4K PNG.")
                    .font(.system(size: 10)).foregroundStyle(LumaStyle.muted)
                Button { model.export4K() } label: {
                    Label("Render 4K image", systemImage: "photo.badge.arrow.down")
                        .font(.system(size: 11)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).controlSize(.regular).disabled(model.image == nil)
            }
        }
    }

    private var paletteSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            sectionLabel("COLOR PALETTE")
            HStack(spacing: 7) {
                ForEach(FractalPalette.allCases) { palette in
                    Button { model.palette = palette } label: {
                        Circle().fill(LinearGradient(colors: palette.colors, startPoint: .bottomLeading, endPoint: .topTrailing))
                            .frame(width: 31, height: 31)
                            .padding(3)
                            .overlay(Circle().stroke(model.palette == palette ? LumaStyle.accent : .clear, lineWidth: 1.5))
                            .overlay {
                                if model.palette == palette {
                                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white).shadow(color: .black, radius: 2)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(palette.title)
                    .accessibilityLabel(palette.title + " palette")
                }
            }
            HStack {
                Text(model.palette.title).font(.system(size: 11, weight: .medium))
                Spacer()
                Text("SMOOTH COLOR").font(.system(size: 7, weight: .medium)).tracking(1).foregroundStyle(LumaStyle.muted)
            }
        }
    }

    private var detailSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionLabel("DETAIL")
                Spacer()
                TextField("Iterations", value: Binding(get: { model.iterations }, set: { value in
                    if value.isFinite { model.iterations = value }
                }), format: .number.precision(.fractionLength(0)))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(LumaStyle.accent)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.plain)
                    .frame(width: 78)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(LumaStyle.accent.opacity(0.065), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(LumaStyle.accent.opacity(0.12), lineWidth: 1))
                    .onSubmit {
                        model.iterations = model.iterations.isFinite ? max(256, min(1_000_000, model.iterations)) : 900
                    }
                    .help("Type an iteration budget from 256 to 1,000,000 for demanding deep views")
                    .accessibilityLabel("Iteration budget")
            }
            Picker("Image quality", selection: $model.quality) {
                ForEach(RenderQuality.allCases) { quality in
                    Text(quality.title).tag(quality)
                }
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            Slider(value: Binding(get: { min(12_000, max(256, model.iterations)) }, set: { model.iterations = $0 }), in: 256...12_000, step: 64)
                .controlSize(.small)
                .accessibilityLabel("Maximum iterations")
            HStack {
                Text("Faster")
                Spacer()
                Text("More detail")
            }.font(.system(size: 9)).foregroundStyle(LumaStyle.muted)
            Text("Raise the iteration limit to reveal dark edges.")
                .font(.system(size: 10)).lineSpacing(3).foregroundStyle(LumaStyle.muted)
        }
    }

    private var destinationsSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionLabel("PLACES TO EXPLORE")
            VStack(spacing: 3) {
                ForEach(FractalDestination.allCases) { destination in
                    Button { model.visit(destination) } label: {
                        HStack(spacing: 11) {
                            destinationGlyph(destination)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(destination.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.87))
                                Text(destination.subtitle).font(.system(size: 9)).foregroundStyle(LumaStyle.muted)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .medium)).foregroundStyle(LumaStyle.muted.opacity(0.7))
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(model.selectedDestination == destination.rawValue ? LumaStyle.accent.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(DestinationButtonStyle())
                }
            }
            .padding(.horizontal, -8)
        }
    }

    private var juliaDestinationsSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionLabel("JULIA WORLDS")
            VStack(spacing: 4) {
                ForEach(JuliaDestination.allCases) { destination in
                    Button { model.visitJulia(destination) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "sparkle")
                                .font(.system(size: 16, weight: .light))
                                .foregroundStyle(LumaStyle.accent)
                                .frame(width: 31, height: 31)
                                .background(LumaStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(destination.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.87))
                                Text(destination.subtitle).font(.system(size: 9)).foregroundStyle(LumaStyle.muted).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(LumaStyle.muted)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(DestinationButtonStyle())
                }
            }
            .padding(.horizontal, -8)
        }
    }

    private func destinationGlyph(_ destination: FractalDestination) -> some View {
        let symbol: String
        let color: Color
        switch destination {
        case .overview: symbol = "circle.lefthalf.filled"; color = LumaStyle.accent
        case .seahorse: symbol = "hurricane"; color = Color(red: 0.61, green: 0.54, blue: 0.95)
        case .spiral: symbol = "circle.dotted"; color = Color(red: 0.99, green: 0.63, blue: 0.39)
        case .elephant: symbol = "waveform.path"; color = Color(red: 0.49, green: 0.76, blue: 0.99)
        case .deepTest: symbol = "sparkles"; color = Color(red: 0.90, green: 0.49, blue: 0.72)
        }
        return Image(systemName: symbol).font(.system(size: 15, weight: .light))
            .foregroundStyle(color).frame(width: 31, height: 31)
            .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
    }

    private var precisionSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "cpu").font(.system(size: 10))
                Text("ADAPTIVE PRECISION").font(.system(size: 8, weight: .semibold)).tracking(1.1)
                Spacer()
                Text("\(model.precision) bits").font(.system(size: 9, design: .monospaced))
            }
            .foregroundStyle(LumaStyle.accent.opacity(0.9))
            Text(model.status).font(.system(size: 10)).lineSpacing(3).foregroundStyle(LumaStyle.muted).lineLimit(3)
                .help(model.status)
            Button { model.copyCoordinates() } label: {
                Label("Copy this location", systemImage: "doc.on.doc").font(.system(size: 10))
            }
            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.65)).padding(.top, 3)
        }
    }

    private var divider: some View { Rectangle().fill(LumaStyle.line).frame(height: 1) }

    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 8, weight: .semibold)).tracking(1.6).foregroundStyle(LumaStyle.muted)
    }
}

private struct HeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.95 : 0.72))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.white.opacity(configuration.isPressed ? 0.1 : 0.045), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.06), lineWidth: 1))
    }
}

private struct DestinationButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(.white.opacity(configuration.isPressed ? 0.08 : 0.015), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct JuliaParameterEditor: View {
    @ObservedObject var model: ExplorerModel
    @State private var real = ""
    @State private var imaginary = ""
    @State private var invalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("FIXED PARAMETER · c").font(.system(size: 8, weight: .semibold)).tracking(1.4).foregroundStyle(LumaStyle.muted)
            parameterField("Real", text: $real)
            parameterField("Imaginary", text: $imaginary)
            if invalid {
                Text("Enter valid decimal values for both parts.")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }
            Button("Apply parameter", action: apply)
                .font(.system(size: 10, weight: .medium))
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(real.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || imaginary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Rebuild the Julia set using this complex parameter")
        }
        .onAppear { synchronize() }
        .onChange(of: model.juliaReal) { synchronize() }
        .onChange(of: model.juliaImag) { synchronize() }
    }

    private func parameterField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 9)).foregroundStyle(LumaStyle.muted)
            TextField(title, text: text)
                .font(.system(size: 10, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .onSubmit(apply)
                .accessibilityLabel("Julia parameter " + title.lowercased())
        }
    }

    private func apply() {
        invalid = !model.applyJuliaParameter(real: real.trimmingCharacters(in: .whitespacesAndNewlines),
                                            imag: imaginary.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func synchronize() {
        real = model.juliaReal
        imaginary = model.juliaImag
        invalid = false
    }
}

private struct BookmarkEditor: View {
    @ObservedObject var model: ExplorerModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "bookmark.fill").foregroundStyle(LumaStyle.accent)
                Text("Keep this discovery").font(.system(size: 22, weight: .medium, design: .serif))
            }
            Text("Save this exact view and its appearance to your library.")
                .font(.system(size: 12)).foregroundStyle(LumaStyle.muted)
            TextField("Name this view", text: $name)
                .textFieldStyle(.roundedBorder).font(.system(size: 13))
                .focused($nameFocused)
                .accessibilityLabel("Bookmark name")
            HStack {
                Label(model.fractalMode.title, systemImage: "sparkle")
                Spacer()
                Text(model.zoomLabel).font(.system(size: 11, design: .monospaced))
            }
            .font(.system(size: 11)).foregroundStyle(LumaStyle.muted)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save view") {
                    model.saveBookmark(name: trimmedName)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty)
            }
            .controlSize(.regular)
        }
        .padding(28).frame(width: 400)
        .background(LumaStyle.panel)
        .onAppear {
            name = "\(model.fractalMode.title) at \(model.zoomLabel)"
            nameFocused = true
        }
    }
}

private struct CoordinateEditor: View {
    @ObservedObject var model: ExplorerModel
    @Environment(\.dismiss) private var dismiss
    @State private var real = ""
    @State private var imaginary = ""
    @State private var span = ""
    @State private var invalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: "scope").foregroundStyle(LumaStyle.accent)
                Text("Travel to a coordinate").font(.system(size: 20, weight: .medium, design: .serif))
            }
            Text("Paste the full decimal coordinates to preserve every digit. The view width sets how far you zoom in.")
                .font(.system(size: 12)).foregroundStyle(LumaStyle.muted).lineSpacing(3)
            coordinateField("REAL AXIS", text: $real)
            coordinateField("IMAGINARY AXIS", text: $imaginary)
            coordinateField("VIEW WIDTH", text: $span)
            if invalid {
                Text("Enter valid decimal coordinates and a positive view width.").font(.system(size: 11)).foregroundStyle(.orange)
            }
            HStack {
                Button("Copy current location") { model.copyCoordinates() }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Explore") {
                    if model.loadCoordinates(real: real, imag: imaginary, span: span) { dismiss() } else { invalid = true }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.regular)
        }
        .padding(28).frame(width: 530)
        .background(LumaStyle.panel)
        .onAppear {
            let coordinates = model.coordinateStrings
            real = coordinates.real
            imaginary = coordinates.imag
            span = coordinates.span
        }
    }

    private func coordinateField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(LumaStyle.muted)
            TextField("", text: text).font(.system(size: 12, design: .monospaced)).textFieldStyle(.roundedBorder)
        }
    }
}

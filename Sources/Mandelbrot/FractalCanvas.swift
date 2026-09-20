import AppKit
import QuartzCore
import SwiftUI

struct FractalCanvas: NSViewRepresentable {
    @ObservedObject var model: ExplorerModel

    func makeNSView(context: Context) -> FractalSurface {
        let view = FractalSurface()
        view.model = model
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        view.setAccessibilityHelp("Drag to pan. Scroll, pinch, or double-click to zoom. Space starts flight. A toggles autopilot.")
        return view
    }

    func updateNSView(_ nsView: FractalSurface, context: Context) {
        nsView.model = model
        nsView.setImage(model.image, transition: model.flightTransition, isFlying: model.isFlying)
        nsView.setInteractionMode(title: model.fractalMode.title, isPickingJulia: model.isPickingJulia)
    }
}

private final class FlightDisplayLinkTarget: NSObject {
    weak var surface: FractalSurface?
    init(_ surface: FractalSurface) { self.surface = surface }
    @objc func tick(_ displayLink: CADisplayLink) {
        surface?.advanceFlightPresentation(at: displayLink.targetTimestamp)
    }
}

final class FractalSurface: NSView {
    private struct FlightPresentation {
        let transition: FlightTransition
        let outgoingImage: CGImage
        let outgoingPreview: CGAffineTransform
        let startTime: CFTimeInterval
    }

    weak var model: ExplorerModel?
    private var fractalImage: CGImage?
    private var preview = CGAffineTransform.identity
    private var lastDragPoint: CGPoint?
    private var flightPresentation: FlightPresentation?
    private var flightDisplayLink: CADisplayLink?
    private var escapeMonitor: Any?
    private lazy var displayLinkTarget = FlightDisplayLinkTarget(self)
    private var consumedTransitionID: Int?
    private var accessibilityMode: String?
    private var pickingJulia = false

    // Read-only diagnostics do not publish SwiftUI updates at display frequency.
    private(set) var flightPresentationProgress = 1.0
    private(set) var flightPresentationFrameCount: UInt64 = 0
    var isPresentingFlight: Bool { flightPresentation != nil }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    deinit {
        flightDisplayLink?.invalidate()
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
    }

    func setInteractionMode(title: String, isPickingJulia: Bool) {
        if accessibilityMode != title {
            accessibilityMode = title
            setAccessibilityLabel("Interactive \(title) canvas")
        }
        if pickingJulia != isPickingJulia {
            pickingJulia = isPickingJulia
            window?.invalidateCursorRects(for: self)
        }
    }

    func setImage(_ image: CGImage?, transition: FlightTransition?, isFlying: Bool) {
        if transition == nil {
            // An unanimated base frame starts a new flight or a recovery. IDs
            // may start over, so do not carry a consumed ID into that sequence.
            finishFlightPresentation()
            consumedTransitionID = nil
        } else if !isFlying {
            finishFlightPresentation()
            consumedTransitionID = transition?.id
        }
        // Metadata is published immediately before its image. Wait for the
        // changed image before consuming a new transition ID.
        guard fractalImage !== image else { return }

        if isFlying, let presentation = flightPresentation,
           transition?.id == presentation.transition.id {
            // Recoloring replaces the destination image while retaining the
            // same clock and camera transform; it must not restart the flight.
            fractalImage = image
            if image == nil { finishFlightPresentation() }
            needsDisplay = true
            return
        }

        finishFlightPresentation()
        let outgoing = fractalImage
        let outgoingPreview = preview
        fractalImage = image
        preview = .identity

        if isFlying, let transition, transition.isValid,
           transition.id != consumedTransitionID, let outgoing, image != nil,
           window != nil, !isHiddenOrHasHiddenAncestor,
           bounds.width > 0, bounds.height > 0 {
            flightPresentation = FlightPresentation(transition: transition,
                                                    outgoingImage: outgoing,
                                                    outgoingPreview: outgoingPreview,
                                                    startTime: CACurrentMediaTime())
            flightPresentationProgress = 0
            startDisplayLink()
        }
        if let transition { consumedTransitionID = transition.id }
        needsDisplay = true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            finishFlightPresentation()
            removeEscapeMonitor()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { removeEscapeMonitor(); return }
        guard escapeMonitor == nil else { return }
        // Escape should stop motion even when a Studio control owns keyboard
        // focus. Limit interception to this canvas's window and active motion;
        // sheets and ordinary text editing retain their normal Escape behavior.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, let owningWindow = self.window,
                  event.window === owningWindow, let model = self.model,
                  model.isFlying || model.isColorCycling || model.isPickingJulia else { return event }
            self.finishFlightPresentation()
            model.stopAnimations()
            return nil
        }
    }

    private func removeEscapeMonitor() {
        guard let escapeMonitor else { return }
        NSEvent.removeMonitor(escapeMonitor)
        self.escapeMonitor = nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size {
            finishFlightPresentation()
            preview = .identity
        }
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    private func startDisplayLink() {
        guard flightDisplayLink == nil else { return }
        let link = displayLink(target: displayLinkTarget, selector: #selector(FlightDisplayLinkTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        flightDisplayLink = link
    }

    fileprivate func advanceFlightPresentation(at timestamp: CFTimeInterval) {
        guard let presentation = flightPresentation else {
            flightDisplayLink?.invalidate()
            flightDisplayLink = nil
            return
        }
        flightPresentationFrameCount &+= 1
        flightPresentationProgress = min(1, max(0, (timestamp - presentation.startTime) / presentation.transition.duration))
        if flightPresentationProgress >= 1 { finishFlightPresentation() }
        else { needsDisplay = true }
    }

    private func finishFlightPresentation() {
        guard flightPresentation != nil || flightDisplayLink != nil else { return }
        flightDisplayLink?.invalidate()
        flightDisplayLink = nil
        flightPresentation = nil
        flightPresentationProgress = 1
        preview = .identity
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(NSColor(red: 0.025, green: 0.032, blue: 0.061, alpha: 1).cgColor)
        context.fill(bounds)
        guard let image = fractalImage else { return }

        if let presentation = flightPresentation {
            let transition = presentation.transition
            let progress = flightPresentationProgress
            context.saveGState()
            context.interpolationQuality = .medium
            context.concatenate(transition.outgoingTransform(progress: progress, in: bounds))
            context.concatenate(presentation.outgoingPreview)
            context.draw(presentation.outgoingImage, in: bounds)
            context.restoreGState()

            context.saveGState()
            context.interpolationQuality = .medium
            context.setAlpha(transition.incomingOpacity(progress: progress))
            context.concatenate(transition.incomingTransform(progress: progress, in: bounds))
            context.draw(image, in: bounds)
            context.restoreGState()
        } else {
            context.saveGState()
            context.interpolationQuality = .high
            context.concatenate(preview)
            context.draw(image, in: bounds)
            context.restoreGState()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: model?.isPickingJulia == true ? .crosshair : .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if model?.isPickingJulia == true, bounds.width > 0, bounds.height > 0 {
            finishFlightPresentation()
            model?.pickJulia(at: CGPoint(x: point.x / bounds.width - 0.5, y: point.y / bounds.height - 0.5))
            lastDragPoint = nil
        } else if event.clickCount == 2 {
            applyZoom(event.modifierFlags.contains(.option) ? 0.5 : 2, at: point)
            lastDragPoint = nil
        } else {
            lastDragPoint = point
            NSCursor.closedHand.set()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let previous = lastDragPoint, bounds.width > 0, bounds.height > 0 else { return }
        finishFlightPresentation()
        let dx = point.x - previous.x
        let dy = point.y - previous.y
        preview.tx += dx
        preview.ty += dy
        needsDisplay = true
        lastDragPoint = point
        model?.pan(dx: dx / bounds.width, dy: dy / bounds.height)
    }

    override func mouseUp(with event: NSEvent) {
        lastDragPoint = nil
        NSCursor.openHand.set()
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 6
        guard abs(delta) > 0.001 else { return }
        let point = convert(event.locationInWindow, from: nil)
        applyZoom(exp(max(-0.7, min(0.7, delta * 0.012))), at: point)
    }

    override func magnify(with event: NSEvent) {
        applyZoom(exp(event.magnification * 2), at: convert(event.locationInWindow, from: nil))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finishFlightPresentation(); model?.stopAnimations(); return }
        switch event.charactersIgnoringModifiers {
        case " ": finishFlightPresentation(); model?.toggleFlight()
        case "a", "A": finishFlightPresentation(); model?.toggleAutopilot()
        case "j", "J": finishFlightPresentation(); model?.toggleJuliaPicker()
        case "+", "=": applyZoom(2, at: CGPoint(x: bounds.midX, y: bounds.midY))
        case "-", "_": applyZoom(0.5, at: CGPoint(x: bounds.midX, y: bounds.midY))
        case "0": finishFlightPresentation(); model?.reset()
        default: super.keyDown(with: event)
        }
    }

    private func applyZoom(_ factor: Double, at point: CGPoint) {
        guard bounds.width > 0, bounds.height > 0, factor.isFinite, factor > 0 else { return }
        finishFlightPresentation()
        preview.a *= factor
        preview.d *= factor
        preview.tx = preview.tx * factor + point.x * (1 - factor)
        preview.ty = preview.ty * factor + point.y * (1 - factor)
        needsDisplay = true
        let anchor = CGPoint(x: point.x / bounds.width - 0.5, y: point.y / bounds.height - 0.5)
        model?.zoom(factor: 1 / factor, anchor: anchor)
    }
}

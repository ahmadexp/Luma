import CoreGraphics
import Foundation

@main
struct FlightTransitionTests {
    static func close(_ a: CGFloat, _ b: CGFloat) -> Bool {
        abs(a - b) <= 1e-8 * max(1, abs(a), abs(b))
    }
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data("Flight transition failure: \(message)\n".utf8))
            exit(1)
        }
    }
    static func main() {
        var comparisons = 0
        let boundsCases = [CGRect(x: 0, y: 0, width: 900, height: 680),
                           CGRect(x: 13, y: 21, width: 1100, height: 720)]
        for bounds in boundsCases {
            for factor in [0.5, 0.83, 1.0, 1.35, 2.0] {
                for anchor in [CGPoint.zero, CGPoint(x: -0.5, y: 0.5), CGPoint(x: 0.33, y: -0.27)] {
                    let transition = FlightTransition(id: 7, factor: factor, anchor: anchor, duration: 0.3)
                    check(transition.isValid, "Valid camera transition rejected")
                    check(transition.outgoingTransform(progress: 0, in: bounds).isIdentity,
                          "Outgoing image moved before the transition began")
                    check(transition.incomingTransform(progress: 1, in: bounds).isIdentity,
                          "Incoming image did not finish at its exact camera")
                    check(transition.outgoingTransform(progress: -1, in: bounds).isIdentity,
                          "Negative progress was not clamped")
                    check(transition.incomingTransform(progress: 2, in: bounds).isIdentity,
                          "Progress beyond the endpoint was not clamped")
                    check(transition.incomingOpacity(progress: 0) == 0 && transition.incomingOpacity(progress: 1) == 1,
                          "Crossfade does not have exact opacity endpoints")
                    let middleScale = transition.outgoingTransform(progress: 0.5, in: bounds).a
                    check(close(middleScale * middleScale, 1 / factor),
                          "Camera motion is not linear in log scale")
                    let pivot = CGPoint(x: bounds.minX + (anchor.x + 0.5) * bounds.width,
                                        y: bounds.minY + (anchor.y + 0.5) * bounds.height)
                    var lastOpacity: CGFloat = 0
                    for step in 0...60 {
                        let progress = Double(step) / 60
                        let outgoing = transition.outgoingTransform(progress: progress, in: bounds)
                        let incoming = transition.incomingTransform(progress: progress, in: bounds)
                        for transform in [outgoing, incoming] {
                            let anchored = pivot.applying(transform)
                            check(close(anchored.x, pivot.x) && close(anchored.y, pivot.y),
                                  "The selected zoom anchor drifted")
                        }
                        let opacity = transition.incomingOpacity(progress: progress)
                        check(opacity >= lastOpacity && opacity >= 0 && opacity <= 1,
                              "Crossfade opacity is not monotonic and bounded")
                        lastOpacity = opacity
                        for old in [CGPoint(x: 47, y: 33), CGPoint(x: 700, y: 300), CGPoint(x: 1100, y: 730)] {
                            // Exact zoom-around-anchor camera relation. Matching
                            // features must coincide throughout the dissolve.
                            let new = CGPoint(x: pivot.x + (old.x - pivot.x) / factor,
                                              y: pivot.y + (old.y - pivot.y) / factor)
                            let oldPresented = old.applying(outgoing), newPresented = new.applying(incoming)
                            check(close(oldPresented.x, newPresented.x) && close(oldPresented.y, newPresented.y),
                                  "Old and new camera images are misregistered while crossfading")
                            comparisons += 1
                        }
                    }
                }
            }
        }
        for factor in [0, -1, Double.infinity, Double.nan, Double.leastNonzeroMagnitude] {
            let invalid = FlightTransition(id: 1, factor: factor, anchor: .zero, duration: 1)
            check(!invalid.isValid, "Invalid camera factor accepted")
            check(invalid.incomingTransform(progress: 0.5, in: boundsCases[0]).isIdentity,
                  "Invalid transition produced a drawing transform")
        }
        for duration in [0, -1, Double.infinity, Double.nan] {
            check(!FlightTransition(id: 1, factor: 0.8, anchor: .zero, duration: duration).isValid,
                  "Invalid duration accepted")
        }
        for anchor in [CGPoint(x: 0.6, y: 0), CGPoint(x: 0, y: -0.6), CGPoint(x: Double.nan, y: 0)] {
            check(!FlightTransition(id: 1, factor: 0.8, anchor: anchor, duration: 0.3).isValid,
                  "Invalid normalized anchor accepted")
        }
        print("Flight geometry: \(comparisons) registered point comparisons; anchors, endpoints, log velocity, opacity, and invalid input passed.")
    }
}

import CoreGraphics
import Foundation

/// Maps the previous camera image into the newly rendered camera image.
/// `factor` is new horizontal span / previous horizontal span; the anchor is
/// centered, with positive imaginary coordinates pointing upward.
struct FlightTransition: Equatable {
    let id: Int
    let factor: Double
    let anchor: CGPoint
    let duration: Double

    var isValid: Bool {
        factor.isFinite && factor > 0 && (1 / factor).isFinite
            && anchor.x.isFinite && anchor.y.isFinite
            && abs(anchor.x) <= 0.5 && abs(anchor.y) <= 0.5
            && duration.isFinite && duration > 0
    }

    func outgoingTransform(progress: Double, in bounds: CGRect) -> CGAffineTransform {
        transform(scale: exp(-log(factor) * normalized(progress)), in: bounds)
    }

    func incomingTransform(progress: Double, in bounds: CGRect) -> CGAffineTransform {
        transform(scale: exp(log(factor) * (1 - normalized(progress))), in: bounds)
    }

    func incomingOpacity(progress: Double) -> CGFloat {
        let t = normalized(progress)
        // Constant logarithmic motion keeps velocity continuous between frames;
        // only the dissolve eases at its endpoints.
        return CGFloat(t * t * (3 - 2 * t))
    }

    private func normalized(_ progress: Double) -> Double {
        progress.isFinite ? min(1, max(0, progress)) : 1
    }

    private func transform(scale: Double, in bounds: CGRect) -> CGAffineTransform {
        guard isValid else { return .identity }
        let scale = CGFloat(scale)
        let point = CGPoint(x: bounds.minX + (anchor.x + 0.5) * bounds.width,
                            y: bounds.minY + (anchor.y + 0.5) * bounds.height)
        let tx = point.x * (1 - scale), ty = point.y * (1 - scale)
        guard scale.isFinite, tx.isFinite, ty.isFinite else { return .identity }
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: tx, ty: ty)
    }
}

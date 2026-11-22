import CoreGraphics
import Foundation
import SwiftUI

/// The Loocal loop: the cursive three-loop stroke and the timing of the spiral loader that
/// writes it. Shared by the app and the Live Activity.
enum LoopGeometry {
    struct Frame { var offset: CGFloat; var start: CGFloat; var end: CGFloat }

    static func frame(at time: TimeInterval) -> Frame {
        // 4 × 0.5 s fast + 2 × 1 s slow = 4 s cycle.
        let cycle = time.truncatingRemainder(dividingBy: 4)
        let fast = cycle < 2
        let p = fast ? cycle.truncatingRemainder(dividingBy: 0.5) / 0.5 : (cycle - 2).truncatingRemainder(dividingBy: 1)
        let startEase = fast ? Bezier(0.32, 0.154, 0.826, 0.579) : Bezier(0.32, 0.313, 0.826, 0.143)
        let endEase = fast ? Bezier(0.341, 0.488, 0.269, 0.75) : Bezier(0.341, 0.992, 0.269, 0.491)
        let offset = 12 - 8 * Bezier(0.167, 0.167, 0.833, 0.833).value(p)
        return Frame(offset: offset, start: 0.23 + 0.34 * startEase.value(p), end: 0.44 + 0.33 * endEase.value(p))
    }

    /// Cursive loop stroke in Lottie's vertex / in-tangent / out-tangent form, centred on the origin.
    static let path: CGPath = {
        let v: [(CGFloat, CGFloat)] = [(-12, 6), (-4.975, -1.012), (-8, -6), (-11.025, -1.012), (-4, 6), (3.025, -1.012), (0, -6), (-3.025, -1.012), (4, 6), (11.025, -1.012), (8, -6), (4.98, -1.012), (12, 6)]
        let i: [(CGFloat, CGFloat)] = [(0, 0), (-0.289, 3.296), (2.218, 0), (-0.23, -2.627), (-4.452, 0), (-0.289, 3.296), (2.218, 0), (-0.23, -2.627), (-4.452, 0), (-0.289, 3.296), (2.218, 0), (-0.232, -2.627), (-4.443, 0)]
        let o: [(CGFloat, CGFloat)] = [(4.452, 0), (0.23, -2.627), (-2.218, 0), (0.289, 3.296), (4.452, 0), (0.23, -2.627), (-2.218, 0), (0.289, 3.296), (4.452, 0), (0.23, -2.627), (-2.218, 0), (0.292, 3.296), (0, 0)]
        let path = CGMutablePath()
        path.move(to: CGPoint(x: v[0].0, y: v[0].1))
        for k in 1..<v.count {
            path.addCurve(to: CGPoint(x: v[k].0, y: v[k].1),
                          control1: CGPoint(x: v[k - 1].0 + o[k - 1].0, y: v[k - 1].1 + o[k - 1].1),
                          control2: CGPoint(x: v[k].0 + i[k].0, y: v[k].1 + i[k].1))
        }
        return path
    }()
}

/// CSS-style cubic-bezier timing curve.
struct Bezier {
    let x1, y1, x2, y2: Double
    init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) { (self.x1, self.y1, self.x2, self.y2) = (x1, y1, x2, y2) }

    func value(_ x: Double) -> Double {
        var t = x
        for _ in 0..<8 { // Newton–Raphson on x(t)
            let dx = sample(t, x1, x2) - x
            let d = slope(t, x1, x2)
            if abs(dx) < 1e-5 || abs(d) < 1e-6 { break }
            t -= dx / d
        }
        return sample(min(max(t, 0), 1), y1, y2)
    }
    private func sample(_ t: Double, _ a: Double, _ b: Double) -> Double { ((1 - 3 * b + 3 * a) * t + (3 * b - 6 * a)) * t * t + 3 * a * t }
    private func slope(_ t: Double, _ a: Double, _ b: Double) -> Double { 3 * (1 - 3 * b + 3 * a) * t * t + 2 * (3 * b - 6 * a) * t + 3 * a }
}


/// The spiral loader as an animatable shape: `time` in seconds drives the same frames as
/// the in-app loader, so the Live Activity can animate it between updates.
struct SpiralShape: Shape {
    var time: Double
    var animatableData: Double {
        get { time }
        set { time = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let frame = LoopGeometry.frame(at: time)
        let scale = rect.width / 16
        var transform = CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale).translatedBy(x: frame.offset, y: 8)
        guard let moved = LoopGeometry.path.copy(using: &transform) else { return Path() }
        return Path(moved).trimmedPath(from: frame.start, to: frame.end)
    }
}

/// The whole loop, as the Loocal mark. Drawn in a 2:1 box.
struct LoopMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = rect.width / 26
        var transform = CGAffineTransform(translationX: rect.midX, y: rect.midY).scaledBy(x: scale, y: scale)
        return LoopGeometry.path.copy(using: &transform).map { Path($0) } ?? Path()
    }
}

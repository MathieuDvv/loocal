import SwiftUI

/// A tilted ink pebble, the body of the errand bot. Drawn in a unit square.
struct PebbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        var path = Path()
        // Wider than tall, sitting a little lower on the left: a river stone at rest.
        path.move(to: p(0.03, 0.59))
        path.addCurve(to: p(0.45, 0.14), control1: p(0.01, 0.33), control2: p(0.21, 0.15))
        path.addCurve(to: p(0.97, 0.44), control1: p(0.71, 0.13), control2: p(0.97, 0.23))
        path.addCurve(to: p(0.55, 0.87), control1: p(0.97, 0.67), control2: p(0.79, 0.87))
        path.addCurve(to: p(0.03, 0.59), control1: p(0.29, 0.87), control2: p(0.05, 0.82))
        path.closeSubpath()
        return path
    }
}

/// The errand bot asleep: closed eyes and a little "z". Used by the island when a reply is
/// waiting for you to come back. Drawn in one colour so it sits on the black island.
struct SleepingPebble: View {
    var color: Color = .white
    /// 0…2: how far the "z"s have drifted, bumped by the activity's beat while it can.
    var drift: Int = 0

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            ZStack(alignment: .topTrailing) {
                ZStack {
                    PebbleShape().fill(color)
                    HStack(spacing: w * 0.13) {
                        SleepyLid().stroke(.black, style: StrokeStyle(lineWidth: max(1.2, w * 0.055), lineCap: .round))
                            .frame(width: w * 0.15, height: w * 0.07)
                        SleepyLid().stroke(.black, style: StrokeStyle(lineWidth: max(1.2, w * 0.055), lineCap: .round))
                            .frame(width: w * 0.15, height: w * 0.07)
                    }
                    .offset(y: w * 0.05)
                }
                .frame(width: w * 0.8, height: w * 0.8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                Text("z")
                    .font(.system(size: w * 0.3, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                    .offset(x: CGFloat(drift % 3) * w * 0.02, y: -CGFloat(drift % 3) * w * 0.05)
                    .opacity(drift % 3 == 2 ? 0.55 : 1)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Waiting for you")
    }
}

/// A closed, sleeping eye: ‿
private struct SleepyLid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.midX, y: rect.maxY * 1.6))
        return path
    }
}

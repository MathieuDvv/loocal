import ActivityKit
import SwiftUI
import WidgetKit

@main
struct IslandWidgets: WidgetBundle {
    var body: some Widget { InferenceActivityWidget() }
}

/// A small island: the Loocal loop on the left, the spiral writing on the right. Nothing
/// else, so it stays compact. Long-press shows the phase underneath.
struct InferenceActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: InferenceAttributes.self) { context in
            HStack(spacing: 12) {
                LoopMarkShape()
                    .stroke(.white, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    .frame(width: 30, height: 15)
                Text(title(context.state))
                    .font(.subheadline.weight(.medium)).foregroundStyle(.white)
                Spacer()
                loader(context.state, size: 22)
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(.white)
            .widgetURL(URL(string: "islandai://chat"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    logo.frame(width: 28, height: 14).padding(.leading, 6).padding(.top, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    loader(context.state, size: 20).padding(.trailing, 6).padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(title(context.state))
                        .font(.footnote).foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 6)
                }
            } compactLeading: {
                logo.frame(width: 22, height: 11).padding(.leading, 2)
            } compactTrailing: {
                loader(context.state, size: 16)
            } minimal: {
                loader(context.state, size: 15)
            }
            .keylineTint(.white)
            .widgetURL(URL(string: "islandai://chat"))
        }
    }

    private func title(_ state: InferenceAttributes.ContentState) -> String {
        if !state.isRunning { return "Reply ready" }
        return state.phase == "Paused" ? "Waiting for you · open Loocal to finish" : state.phase
    }

    private var logo: some View {
        LoopMarkShape()
            .stroke(.white, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            .accessibilityLabel("Loocal")
    }

    /// The same spiral as in the app. Each beat moves it two seconds on, and the update
    /// animates over those two seconds, so it keeps writing between updates.
    @ViewBuilder private func loader(_ state: InferenceAttributes.ContentState, size: CGFloat) -> some View {
        if state.isRunning && state.phase == "Paused" {
            // You left mid-reply: the bot dozes until you're back to finish it.
            SleepingPebble(drift: state.tick)
                .frame(width: size * 1.15, height: size * 1.15)
                .animation(.smooth(duration: 1.6), value: state.tick)
                .transition(.scale.combined(with: .opacity))
        } else if state.isRunning {
            SpiralShape(time: Double(state.tick) * 2)
                .stroke(.white, style: StrokeStyle(lineWidth: 1.4 * size / 16, lineCap: .round, lineJoin: .round))
                .frame(width: size, height: size)
                .clipped()
                .animation(.linear(duration: 2), value: state.tick)
                .accessibilityLabel("Working")
        } else {
            Image(systemName: "checkmark").font(.system(size: size * 0.7, weight: .semibold)).foregroundStyle(.white)
        }
    }
}

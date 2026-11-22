import ActivityKit
import SwiftUI
import WidgetKit

@main
struct IslandWidgets: WidgetBundle {
    var body: some Widget { InferenceActivityWidget() }
}

struct InferenceActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: InferenceAttributes.self) { context in
            HStack(spacing: 14) {
                indicator(context.state.isRunning)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Loocal · \(context.state.phase)").font(.headline)
                    Text(context.state.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(context.attributes.startedAt, style: .timer).font(.caption.monospacedDigit())
            }
            .padding(18)
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(.white)
            .widgetURL(URL(string: "islandai://chat"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Loocal", systemImage: "scribble").foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.startedAt, style: .timer).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.center) { indicator(context.state.isRunning) }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(context.state.phase).font(.headline)
                        Text(context.state.detail).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: "scribble").foregroundStyle(.white)
            } compactTrailing: {
                indicator(context.state.isRunning)
            } minimal: {
                indicator(context.state.isRunning)
            }
            .keylineTint(.white)
            .widgetURL(URL(string: "islandai://chat"))
        }
    }

    @ViewBuilder private func indicator(_ running: Bool) -> some View {
        if running {
            ProgressView().tint(.white).accessibilityLabel("Model working")
        } else {
            Image(systemName: "checkmark").foregroundStyle(.white)
        }
    }
}

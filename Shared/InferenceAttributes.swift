import ActivityKit
import Foundation

struct InferenceAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: String
        var detail: String
        var generatedPieces: Int
        var isRunning: Bool
        /// Bumped every couple of seconds while running, so the island's loader keeps moving:
        /// each bump animates the spiral two seconds further along.
        var tick: Int = 0
    }
    var modelName: String
    var startedAt: Date
}

import ActivityKit
import Foundation

struct InferenceAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: String
        var detail: String
        var generatedPieces: Int
        var isRunning: Bool
    }
    var modelName: String
    var startedAt: Date
}

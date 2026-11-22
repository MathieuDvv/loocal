import AppIntents
import Foundation
import UIKit

// MARK: - Shortcuts app

/// A routine, as Shortcuts sees it: pick one to run.
struct RoutineEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Loocal Routine")
    static let defaultQuery = RoutineQuery()
    let id: UUID
    let title: String
    let schedule: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)", subtitle: "\(schedule)") }
}

struct RoutineQuery: EntityQuery {
    @MainActor func entities(for identifiers: [UUID]) async throws -> [RoutineEntity] {
        all().filter { identifiers.contains($0.id) }
    }

    @MainActor func suggestedEntities() async throws -> [RoutineEntity] { all() }

    @MainActor private func all() -> [RoutineEntity] {
        (AppRuntime.store?.desk.errands ?? []).map { RoutineEntity(id: $0.id, title: $0.title, schedule: $0.schedule) }
    }
}

/// Opens Loocal and hands it an errand, as if typed on the Errands page.
struct RunErrandIntent: AppIntent {
    static let title: LocalizedStringResource = "Run an Errand"
    static let description = IntentDescription("Opens Loocal and sends its bot on an errand. Errands run on this iPhone; reminders and calendar events are added straight away.")
    static let openAppWhenRun = true

    @Parameter(title: "Errand", requestValueDialog: "What should Loocal do?")
    var errand: String

    static var parameterSummary: some ParameterSummary { Summary("Run errand \(\.$errand)") }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let store = AppRuntime.store else { throw ShortcutError.notReady }
        let text = errand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ShortcutError.empty }
        store.requestedTab = .errand
        store.runErrand(title: Errand.title(for: text), instructions: text, sources: ErrandVoiceView.sources(for: text))
        if let error = store.error { store.error = nil; return .result(dialog: "\(error)") }
        return .result(dialog: "On it.")
    }
}

/// Runs one routine now, whatever its schedule.
struct RunRoutineIntent: AppIntent {
    static let title: LocalizedStringResource = "Run a Routine"
    static let description = IntentDescription("Opens Loocal and runs one of your routines now.")
    static let openAppWhenRun = true

    @Parameter(title: "Routine") var routine: RoutineEntity

    static var parameterSummary: some ParameterSummary { Summary("Run \(\.$routine)") }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let store = AppRuntime.store, let errand = store.desk.errands.first(where: { $0.id == routine.id }) else { throw ShortcutError.notReady }
        store.requestedTab = .errand
        store.runErrand(title: errand.title, instructions: errand.instructions, sources: errand.sources, errandID: errand.id)
        return .result(dialog: "Running \(errand.title).")
    }
}

/// For a Shortcuts automation (say, every morning at 7): runs whichever routines are due.
/// Loocal opens only when there is something to do.
struct RunDueRoutinesIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Due Routines"
    static let description = IntentDescription("Runs the Loocal routines whose time has come. Use it in a Shortcuts automation so routines run on time, even when Loocal is closed.")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Int> {
        guard let store = AppRuntime.store else { throw ShortcutError.notReady }
        let due = store.desk.errands.filter(\.isDue).count
        guard due > 0 else { return .result(value: 0, dialog: "Nothing’s due right now.") }
        store.requestedTab = .errand
        store.runDueErrands()
        return .result(value: due, dialog: due == 1 ? "Running one routine." : "Running \(due) routines.")
    }
}

/// Opens Loocal on a chat, or on the Errands page.
struct OpenLoocalIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Loocal"
    static let description = IntentDescription("Opens Loocal on a new chat or on Errands.")
    static let openAppWhenRun = true

    @Parameter(title: "Page", default: .chat) var page: LoocalPage

    @MainActor func perform() async throws -> some IntentResult {
        AppRuntime.store?.requestedTab = page == .errands ? .errand : .chat
        if page == .chat { AppRuntime.store?.newConversation() }
        return .result()
    }
}

enum LoocalPage: String, AppEnum {
    case chat, errands
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Loocal Page")
    static let caseDisplayRepresentations: [LoocalPage: DisplayRepresentation] = [.chat: "New chat", .errands: "Errands"]
}

enum ShortcutError: Error, CustomLocalizedStringResourceConvertible {
    case notReady, empty
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady: "Loocal isn’t ready yet. Open it once, then try again."
        case .empty: "Tell Loocal what to do."
        }
    }
}

struct LoocalShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RunErrandIntent(), phrases: ["Run an errand with \(.applicationName)", "Send \(.applicationName) on an errand"], shortTitle: "Run an Errand", systemImageName: "figure.walk")
        AppShortcut(intent: RunRoutineIntent(), phrases: ["Run \(\.$routine) in \(.applicationName)", "Run a \(.applicationName) routine"], shortTitle: "Run a Routine", systemImageName: "clock")
        AppShortcut(intent: RunDueRoutinesIntent(), phrases: ["Run my \(.applicationName) routines"], shortTitle: "Run Due Routines", systemImageName: "clock.badge.checkmark")
        AppShortcut(intent: OpenLoocalIntent(), phrases: ["Open \(.applicationName)", "New \(.applicationName) chat"], shortTitle: "Open Loocal", systemImageName: "bubble")
    }
}

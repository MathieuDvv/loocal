import EventKit
import Foundation
import UIKit

// MARK: - Memory

/// Something Loocal keeps in mind about you across chats. Saved on this iPhone only, and
/// editable in Settings.
struct Memory: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var text: String
    var createdAt = Date()

    private static let key = "memories"
    static let limit = 40

    static func load() -> [Memory] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Memory].self, from: data)) ?? []
    }

    static func save(_ list: [Memory]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(Array(list.prefix(limit))), forKey: key)
    }

    /// What's added to the system prompt. The phone's context is small, so the newest
    /// memories go first and the block stops at a few hundred characters.
    static func prompt(_ list: [Memory]) -> String {
        guard !list.isEmpty else { return "" }
        var lines: [String] = []
        var used = 0
        for memory in list.sorted(by: { $0.createdAt > $1.createdAt }) {
            guard used + memory.text.count < 600 else { break }
            lines.append("- " + memory.text)
            used += memory.text.count
        }
        return "What you know about the user (they asked you to remember it; use it when it helps, don't recite it):\n" + lines.joined(separator: "\n")
    }
}

// MARK: - Actions

/// Something the user asked Loocal to do, not just answer: add a reminder, put an event in
/// the calendar, remember or forget a fact. Spotted in their own words, so it works with
/// small models that rarely call tools, and done right away with an Undo.
struct ToolAction: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case reminder, event, remember, forget, shortcut, newShortcut }
    var kind: Kind
    var title: String
    var date: Date?
    /// The date came with a time of day (else it's a whole-day reminder or event).
    var timed = false
    /// The created EventKit item or memory, so Undo can remove it.
    var itemID: String?
    /// For `forget`: the memory that was removed, so Undo can put it back.
    var removed: Memory?
    /// For `shortcut`: text handed to the shortcut as its input.
    var input: String?

    /// Shortcuts can't be taken back once run.
    var undoable: Bool { kind != .shortcut && kind != .newShortcut }

    /// "Tomorrow 09:00", "Fri 21 Nov".
    var when: String? {
        guard let date else { return nil }
        let day = Calendar.current.isDateInToday(date) ? "Today" : Calendar.current.isDateInTomorrow(date) ? "Tomorrow" : date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return timed ? day + " " + date.formatted(.dateTime.hour().minute()) : day
    }

    /// The box shown in the reply.
    var box: ToolUse {
        let detail = [title, when].compactMap { $0 }.joined(separator: " · ")
        switch kind {
        case .reminder: return ToolUse(kind: "reminder", icon: "checklist", running: "Adding a reminder", done: "Added to Reminders", detail: detail, action: self)
        case .event: return ToolUse(kind: "event", icon: "calendar.badge.plus", running: "Adding to your calendar", done: "Added to Calendar", detail: detail, action: self)
        case .remember: return ToolUse(kind: "memory", icon: "brain", running: "Remembering", done: "Saved to memory", detail: title, action: self)
        case .forget: return ToolUse(kind: "memory", icon: "brain", running: "Forgetting", done: "Forgotten", detail: title, action: self)
        case .shortcut: return ToolUse(kind: "shortcut", icon: "square.2.layers.3d", running: "Running your shortcut", done: "Ran it in Shortcuts", detail: [title, input].compactMap { $0 }.joined(separator: " · "), action: self)
        case .newShortcut: return ToolUse(kind: "shortcut", icon: "square.2.layers.3d", running: "Opening Shortcuts", done: "Opened a new shortcut", detail: title, action: self)
        }
    }

    /// One line for the model, so its reply confirms what happened instead of telling the
    /// user to do it themselves.
    func note(ok: Bool, error: String?) -> String {
        let what: String = switch kind {
        case .reminder: "added a reminder “\(title)”" + (when.map { " for \($0)" } ?? "") + " to the user's Reminders"
        case .event: "added “\(title)”" + (when.map { " on \($0)" } ?? "") + " to the user's calendar"
        case .remember: "saved to memory: “\(title)”"
        case .forget: "removed from memory: “\(title)”"
        case .shortcut: "ran the user's shortcut “\(title)” in the Shortcuts app"
        case .newShortcut: "opened a new, empty shortcut in the Shortcuts app (iOS doesn't let apps build or read shortcuts themselves)"
        }
        if ok && kind == .newShortcut {
            return "You (Loocal) just \(what). In a few short steps, tell them which actions to add to make this shortcut: \(title)."
        }
        return ok
            ? "You (Loocal) just \(what). It's done. Confirm it in one short, warm sentence. Don't tell them to do it themselves."
            : "You tried but couldn't do this: \(what). Reason: \(error ?? "unknown"). Say so in one sentence."
    }

    // MARK: Spotting

    private static let reminderTriggers = ["remind me to ", "remind me ", "set a reminder to ", "set a reminder for ", "add a reminder to ", "add a reminder for ", "add a reminder ", "rappelle-moi de ", "rappelle-moi d'", "rappelle moi de ", "rappelle-moi ", "fais-moi penser à ", "ajoute un rappel pour ", "ajoute un rappel "]
    private static let eventTriggers = ["add to my calendar ", "put in my calendar ", "create an event ", "schedule a ", "schedule an ", "schedule ", "book a ", "ajoute à mon agenda ", "ajoute dans mon agenda ", "ajoute à mon calendrier ", "crée un événement ", "planifie "]
    private static let rememberTriggers = ["remember that ", "remember: ", "please remember ", "keep in mind that ", "note that ", "souviens-toi que ", "souviens toi que ", "retiens que ", "n'oublie pas que ", "n’oublie pas que "]
    private static let forgetTriggers = ["forget that ", "forget about ", "oublie que ", "oublie "]

    /// Reads an action out of a message, if it asks for one.
    static func detect(_ message: String) -> ToolAction? {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.hasPrefix("do you remember") || lower.hasPrefix("tu te souviens") { return nil }
        if let rest = after(rememberTriggers, in: text, lower) ?? (lower.hasPrefix("remember ") ? String(text.dropFirst(9)) : nil) {
            let fact = clean(rest)
            return fact.count > 2 ? ToolAction(kind: .remember, title: fact) : nil
        }
        if let rest = after(forgetTriggers, in: text, lower), lower.hasPrefix("forget") || lower.hasPrefix("oublie") {
            let fact = clean(rest)
            return fact.count > 2 ? ToolAction(kind: .forget, title: fact) : nil
        }
        // "Run my Morning shortcut", "Run the shortcut Focus with work"
        if let match = text.firstMatch(of: /(?i)^(?:please )?(?:run|launch|start|open|lance|exécute|ouvre)\s+(?:my |the |le |mon |la )?(?:shortcut|raccourci)\s+["“]?(.+?)["”]?(?:\s+(?:with|avec)\s+(.+))?[.!]?$/) {
            return ToolAction(kind: .shortcut, title: String(match.1), input: match.2.map(String.init))
        }
        if let match = text.firstMatch(of: /(?i)^(?:please )?(?:run|launch|start|lance|exécute)\s+(?:my |the |le |mon |la )?["“]?(.+?)["”]?\s+(?:shortcut|raccourci)[.!]?$/) {
            return ToolAction(kind: .shortcut, title: String(match.1))
        }
        if let match = text.firstMatch(of: /(?i)^(?:please )?(?:create|make|build|crée|fais)\s+(?:me )?(?:a |an |un )?(?:new |nouveau )?(?:shortcut|raccourci)\s*(?:to |that |for |pour |qui )?(.*)$/) {
            let goal = clean(String(match.1))
            return ToolAction(kind: .newShortcut, title: goal.isEmpty ? "A new shortcut" : goal)
        }
        if let rest = after(reminderTriggers, in: text, lower) {
            let (title, date, timed) = split(rest)
            return title.isEmpty ? nil : ToolAction(kind: .reminder, title: title, date: date, timed: timed)
        }
        // "Add milk to my reminders / to-do list"
        if let match = text.range(of: #"(?i)^add (.+?) to my (reminders|to-?do( list)?|list)"#, options: .regularExpression) {
            let inner = text[match].replacingOccurrences(of: #"(?i)^add | to my (reminders|to-?do( list)?|list)$"#, with: "", options: .regularExpression)
            let (title, date, timed) = split(inner)
            return title.isEmpty ? nil : ToolAction(kind: .reminder, title: title, date: date, timed: timed)
        }
        if let rest = after(eventTriggers, in: text, lower) {
            let (title, date, timed) = split(rest)
            guard let date else { return nil } // an event needs a when
            return ToolAction(kind: .event, title: title.isEmpty ? "Event" : title, date: date, timed: timed)
        }
        return nil
    }

    /// The text after the first trigger phrase found anywhere in the message.
    private static func after(_ triggers: [String], in text: String, _ lower: String) -> String? {
        for trigger in triggers {
            if let range = lower.range(of: trigger) {
                let start = text.index(text.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: range.upperBound))
                return String(text[start...])
            }
        }
        return nil
    }

    /// Splits "call mum tomorrow at 9" into ("Call mum", tomorrow 09:00, timed).
    private static func split(_ text: String) -> (String, Date?, Bool) {
        var title = text
        var date: Date?
        var timed = false
        // "in 20 minutes", "in 2 hours", "dans 10 minutes"
        if let range = text.range(of: #"(?i)\b(in|dans) (\d{1,3}|an|a|une|un) ?(minutes?|mins?|hours?|hrs?|heures?|h)\b"#, options: .regularExpression) {
            let phrase = text[range].lowercased()
            let number = phrase.split(separator: " ").dropFirst().first.map(String.init) ?? "1"
            let amount = Double(number) ?? 1
            let hours = phrase.contains("h")
            date = Date.now.addingTimeInterval(amount * (hours ? 3600 : 60))
            title.removeSubrange(range)
            return (clean(title), date, true)
        }
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range, in: text) {
            date = match.date
            let phrase = String(text[range]).lowercased()
            timed = phrase.range(of: #"\d{1,2}\s*(:|h|am|pm|a\.m|p\.m)|\b(at|à) \d{1,2}\b|noon|midnight|midi|minuit|morning|afternoon|evening|tonight|matin|après-midi|soir"#, options: .regularExpression) != nil
            title.removeSubrange(range)
            // Leftover joiners around the date: "at", "on", "for", "le", "à"…
            title = title.replacingOccurrences(of: #"(?i)\s+(at|on|by|for|in|à|le|la|pour|avant)\s*$"#, with: "", options: .regularExpression)
        }
        if let date, !timed {
            // A day without a time: keep it to that day.
            return (clean(title), Calendar.current.startOfDay(for: date), false)
        }
        return (clean(title), date, timed)
    }

    private static func clean(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        for lead in ["to ", "that ", "de ", "d'", "d’", "que ", "qu'", "qu’"] where value.lowercased().hasPrefix(lead) {
            value = String(value.dropFirst(lead.count))
        }
        value = value.replacingOccurrences(of: #"(?i)^my "#, with: "your ", options: .regularExpression)
        value = value.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return value.prefix(1).uppercased() + value.dropFirst()
    }
}

/// Carries actions out with EventKit (and the memory list), and undoes them.
@MainActor
enum ActionRunner {
    static var store: EKEventStore { ConnectorHub.store }

    /// Does it. Returns the action with what Undo needs, or an error to show.
    static func perform(_ action: ToolAction, memories: inout [Memory]) async -> (ToolAction, String?) {
        var action = action
        switch action.kind {
        case .remember:
            let memory = Memory(text: action.title)
            memories.insert(memory, at: 0)
            action.itemID = memory.id.uuidString
            return (action, nil)
        case .forget:
            let words = Set(action.title.lowercased().split(separator: " ").map(String.init).filter { $0.count > 2 })
            guard let index = memories.firstIndex(where: { memory in
                let have = Set(memory.text.lowercased().split(separator: " ").map(String.init))
                return words.isSubset(of: have) || memory.text.localizedCaseInsensitiveContains(action.title)
            }) else { return (action, "Nothing like that is in memory.") }
            action.removed = memories.remove(at: index)
            action.title = action.removed?.text ?? action.title
            return (action, nil)
        case .reminder:
            guard (try? await store.requestFullAccessToReminders()) == true else { return (action, "Loocal isn't allowed to use Reminders. You can allow it in Settings.") }
            let reminder = EKReminder(eventStore: store)
            reminder.title = action.title
            reminder.calendar = store.defaultCalendarForNewReminders()
            if let date = action.date {
                let parts: Set<Calendar.Component> = action.timed ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
                reminder.dueDateComponents = Calendar.current.dateComponents(parts, from: date)
                if action.timed { reminder.addAlarm(EKAlarm(absoluteDate: date)) }
            }
            do { try store.save(reminder, commit: true) } catch { return (action, error.localizedDescription) }
            action.itemID = reminder.calendarItemIdentifier
            return (action, nil)
        case .event:
            guard (try? await store.requestFullAccessToEvents()) == true else { return (action, "Loocal isn't allowed to use Calendar. You can allow it in Settings.") }
            guard let date = action.date else { return (action, "No date was given.") }
            let event = EKEvent(eventStore: store)
            event.title = action.title
            event.calendar = store.defaultCalendarForNewEvents
            event.startDate = date
            event.isAllDay = !action.timed
            event.endDate = action.timed ? date.addingTimeInterval(3600) : date
            do { try store.save(event, span: .thisEvent, commit: true) } catch { return (action, error.localizedDescription) }
            action.itemID = event.eventIdentifier
            return (action, nil)
        case .shortcut:
            var components = URLComponents(string: "shortcuts://x-callback-url/run-shortcut")!
            components.queryItems = [.init(name: "name", value: action.title), .init(name: "x-success", value: "islandai://shortcut-done"), .init(name: "x-cancel", value: "islandai://shortcut-done")]
                + (action.input.map { [.init(name: "input", value: "text"), .init(name: "text", value: $0)] } ?? [])
            guard let url = components.url, await UIApplication.shared.open(url) else { return (action, "The Shortcuts app didn't open.") }
            return (action, nil)
        case .newShortcut:
            guard let url = URL(string: "shortcuts://create-shortcut"), await UIApplication.shared.open(url) else { return (action, "The Shortcuts app didn't open.") }
            return (action, nil)
        }
    }

    static func undo(_ action: ToolAction, memories: inout [Memory]) -> Bool {
        switch action.kind {
        case .remember:
            memories.removeAll { $0.id.uuidString == action.itemID }
            return true
        case .forget:
            if let removed = action.removed { memories.insert(removed, at: 0) }
            return true
        case .reminder:
            guard let id = action.itemID, let item = store.calendarItem(withIdentifier: id) as? EKReminder else { return false }
            return (try? store.remove(item, commit: true)) != nil
        case .event:
            guard let id = action.itemID, let event = store.event(withIdentifier: id) else { return false }
            return (try? store.remove(event, span: .thisEvent, commit: true)) != nil
        case .shortcut, .newShortcut:
            return false
        }
    }
}

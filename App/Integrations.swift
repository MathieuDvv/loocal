import Contacts
import Foundation
import HealthKit
import Photos
import UIKit

// MARK: - Catalog

/// An app Loocal can work with: something on the phone (Health, Photos, Contacts), a service
/// behind an API (GitHub, Notion, App Store), another assistant (ChatGPT, Claude), or an app
/// Loocal writes for (Messages, Mail). Once connected it joins the + tray with its own logo,
/// and goes into the prompt as its own island.
struct Integration: Identifiable, Hashable, Sendable {
    enum Key: Sendable { case none, optional, required }

    let id: String
    let name: String
    /// One line under the name.
    let tagline: String
    /// What it lets Loocal do, shown on its page.
    let abilities: [String]
    /// The island's glyph and the tool step's icon.
    let glyph: String
    let tint: IslandTint
    /// URL schemes that tell whether the app is on this iPhone (listed in Info.plist).
    let schemes: [String]
    let key: Key
    var keyLabel = "API key"
    var keyHelp = ""
    var keyURL: URL? = nil
    let privacy: String
    /// Read before the reply (context), or drafted from the reply (Messages, Mail).
    var drafts = false
    /// Built into iOS: never proposed as "you have this app".
    var system = false

    var connectorID: String { Integration.prefix + id }
    var connector: Connector { Connector(id: connectorID, name: name, icon: glyph, detail: tagline) }

    static let prefix = "int."
    static func with(connectorID id: String) -> Integration? {
        guard id.hasPrefix(prefix) else { return nil }
        return all.first { $0.connectorID == id }
    }
    static func with(id: String) -> Integration? { all.first { $0.id == id } }

    static let github = Integration(
        id: "github", name: "GitHub", tagline: "Issues, pull requests and repos",
        abilities: ["Reads your notifications and the issues assigned to you", "Looks up any repository: “what’s open on apple/swift?”", "Finds repositories by topic"],
        glyph: "chevron.left.forwardslash.chevron.right", tint: .github, schemes: ["github"], key: .optional,
        keyLabel: "Personal access token", keyHelp: "Without a token Loocal can search public repositories. A fine-grained token with read access adds your notifications and issues.",
        keyURL: URL(string: "https://github.com/settings/personal-access-tokens/new"),
        privacy: "Only the repository or search terms from your message go to api.github.com.")
    static let chatgpt = Integration(
        id: "chatgpt", name: "ChatGPT", tagline: "A second opinion from OpenAI",
        abilities: ["Hands the hard question to ChatGPT", "Loocal answers with what it said, on device"],
        glyph: "circle.hexagongrid.fill", tint: .chatgpt, schemes: ["chatgpt"], key: .required,
        keyHelp: "Uses your OpenAI API key, billed to your account.", keyURL: URL(string: "https://platform.openai.com/api-keys"),
        privacy: "The message you place ChatGPT in is sent to OpenAI. Nothing else is.")
    static let claude = Integration(
        id: "claude", name: "Claude", tagline: "Bring in Claude for the hard parts",
        abilities: ["Asks Claude Opus 5.5 when a question needs more than a phone", "Loocal answers with what Claude said, on device"],
        glyph: "sparkle", tint: .claude, schemes: ["claude"], key: .required,
        keyHelp: "Uses your Anthropic API key, billed to your account.", keyURL: URL(string: "https://platform.claude.com/settings/keys"),
        privacy: "The message you place Claude in is sent to Anthropic. Nothing else is.")
    static let notion = Integration(
        id: "notion", name: "Notion", tagline: "Pages from your workspace",
        abilities: ["Finds pages by what your message is about", "Links straight to them"],
        glyph: "doc.richtext.fill", tint: .notion, schemes: ["notion"], key: .required,
        keyLabel: "Integration secret", keyHelp: "Create an internal integration, then share the pages you want with it.",
        keyURL: URL(string: "https://www.notion.so/profile/integrations"),
        privacy: "Only search terms from your message go to Notion.")
    static let messages = Integration(
        id: "messages", name: "Messages", tagline: "Drafts texts, ready to send",
        abilities: ["Writes the text you asked for", "Opens Messages with it, addressed when the person is in your contacts"],
        glyph: "message.fill", tint: .messages, schemes: ["sms"], key: .none,
        privacy: "Nothing is sent until you tap send in Messages.", drafts: true, system: true)
    static let mail = Integration(
        id: "mail", name: "Mail", tagline: "Drafts emails with a subject",
        abilities: ["Writes the email you asked for, with a subject", "Opens it in Mail, ready to send"],
        glyph: "envelope.fill", tint: .mail, schemes: ["message", "mailto"], key: .none,
        privacy: "Nothing is sent until you tap send in Mail.", drafts: true, system: true)
    static let appStore = Integration(
        id: "appstore", name: "App Store", tagline: "Finds apps, prices and ratings",
        abilities: ["Searches the App Store for apps that do what you describe", "Compares ratings and prices, with links"],
        glyph: "bag.fill", tint: .appStore, schemes: ["itms-apps"], key: .none,
        privacy: "Search terms from your message go to Apple’s public search.", system: true)
    static let gallery = Integration(
        id: "gallery", name: "Gallery", tagline: "What you’ve photographed lately",
        abilities: ["Knows what you shot and when: “how many photos this week?”", "Spots favourites, videos and screenshots"],
        glyph: "photo.stack.fill", tint: .gallery, schemes: ["photos-redirect"], key: .none,
        privacy: "Reads dates and kinds of photos on your iPhone. Pictures never leave it.", system: true)
    static let health = Integration(
        id: "health", name: "Health", tagline: "Steps, sleep, heart and workouts",
        abilities: ["Steps, distance and energy for today and the week", "Last night’s sleep and resting heart rate", "Your recent workouts"],
        glyph: "heart.fill", tint: .health, schemes: ["x-apple-health"], key: .none,
        privacy: "Read on your iPhone, never sent anywhere.", system: true)
    static let googleHealth = Integration(
        id: "googlehealth", name: "Google Health", tagline: "Fitbit and Google Fit data",
        abilities: ["Reads what Fitbit and Google Fit sync into Apple Health", "Steps, sleep, heart and workouts from those devices"],
        glyph: "heart.text.square.fill", tint: .googleHealth, schemes: ["fitbit", "googlefit", "googlehealth"], key: .none,
        privacy: "Read from Apple Health on your iPhone, never sent anywhere.")
    static let contacts = Integration(
        id: "contacts", name: "Contacts", tagline: "Numbers, emails and birthdays",
        abilities: ["Looks up the people you name", "Addresses Messages and Mail drafts for you"],
        glyph: "person.crop.circle.fill", tint: .contacts, schemes: [], key: .none,
        privacy: "Only the people you name are read, on your iPhone.", system: true)

    static let all = [messages, mail, appStore, chatgpt, claude, gallery, github, googleHealth, health, contacts, notion]
}

// MARK: - Connected integrations, detection and suggestions

@MainActor @Observable
final class IntegrationCenter {
    /// Connected, in the order they were added.
    private(set) var installed: [String] { didSet { UserDefaults.standard.set(installed, forKey: Keys.installed) } }
    /// Found on this iPhone.
    private(set) var detected: Set<String> = []
    /// The one being proposed right now, if any.
    private(set) var suggestion: Integration?
    private var snoozed: [String: Date] { didSet { UserDefaults.standard.set(snoozed, forKey: Keys.snoozed) } }
    private var lastSuggested: Date? { didSet { UserDefaults.standard.set(lastSuggested, forKey: Keys.last) } }
    /// Bumped when a key changes, so views showing "needs a key" refresh.
    private(set) var keysVersion = 0

    private enum Keys {
        static let installed = "integrations.installed", snoozed = "integrations.snoozed", last = "integrations.suggested"
    }

    /// At most one proposal this often.
    nonisolated static let pause: TimeInterval = 36 * 3600
    /// A dismissed proposal comes back after this long.
    nonisolated static let snooze: TimeInterval = 30 * 24 * 3600

    init() {
        installed = (UserDefaults.standard.stringArray(forKey: Keys.installed) ?? []).filter { Integration.with(id: $0) != nil }
        snoozed = UserDefaults.standard.dictionary(forKey: Keys.snoozed) as? [String: Date] ?? [:]
        lastSuggested = UserDefaults.standard.object(forKey: Keys.last) as? Date
    }

    var connected: [Integration] { installed.compactMap(Integration.with(id:)) }
    var connectors: [Connector] { connected.map(\.connector) }
    func isInstalled(_ integration: Integration) -> Bool { installed.contains(integration.id) }

    /// Which catalog apps are on this iPhone. iOS only answers for schemes the app declares
    /// (LSApplicationQueriesSchemes), so this is a fixed list, never the whole phone.
    func scan(demo: Bool = false) {
        detected = Set(Integration.all.filter { integration in
            demo || integration.id == Integration.contacts.id || integration.schemes.contains { scheme in
                URL(string: scheme + "://").map(UIApplication.shared.canOpenURL) ?? false
            }
        }.map(\.id))
    }

    /// Picks something to propose, now and then: an app on the phone that isn't connected.
    func considerSuggesting(now: Date = .now) {
        guard suggestion == nil else { return }
        let id = Self.nextSuggestion(detected: detected, installed: Set(installed), snoozed: snoozed, lastShown: lastSuggested, now: now)
        suggestion = id.flatMap(Integration.with(id:))
    }

    /// Pure rule, for tests: nothing within `pause` of the last one; skip connected and
    /// recently dismissed apps; apps the person installed themselves come before iOS's own.
    nonisolated static func nextSuggestion(detected: Set<String>, installed: Set<String>, snoozed: [String: Date], lastShown: Date?, now: Date) -> String? {
        if let lastShown, now.timeIntervalSince(lastShown) < pause { return nil }
        let candidates = Integration.all.filter { integration in
            detected.contains(integration.id) && !installed.contains(integration.id)
                && (snoozed[integration.id].map { now.timeIntervalSince($0) > snooze } ?? true)
        }
        return (candidates.first { !$0.system } ?? candidates.first)?.id
    }

    /// The proposal reached the screen: it counts, whatever the person does with it.
    func suggestionShown(now: Date = .now) { lastSuggested = now }

    func dismissSuggestion(now: Date = .now) {
        if let suggestion { snoozed[suggestion.id] = now }
        lastSuggested = now
        suggestion = nil
    }

    // MARK: Connecting

    func key(_ integration: Integration) -> String? {
        _ = keysVersion
        return Keychain.get("integration." + integration.id).flatMap { $0.isEmpty ? nil : $0 }
    }

    func setKey(_ value: String, for integration: Integration) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.set(trimmed.isEmpty ? nil : trimmed, for: "integration." + integration.id)
        keysVersion += 1
    }

    func needsKey(_ integration: Integration) -> Bool { integration.key == .required && key(integration) == nil }

    /// Asks for what it needs (Health, Photos, Contacts access) and adds it to the tray.
    /// Returns a reason when it can't connect.
    func connect(_ integration: Integration) async -> String? {
        if needsKey(integration) { return "Add your \(integration.keyLabel) to connect \(integration.name)." }
        guard await IntegrationHub.requestAccess(integration) else {
            return "Allow Loocal to read \(integration.name == "Gallery" ? "your photos" : integration.name) in the Settings app to connect it."
        }
        if !installed.contains(integration.id) { installed.append(integration.id) }
        if suggestion?.id == integration.id { suggestion = nil; lastSuggested = .now }
        return nil
    }

    func disconnect(_ integration: Integration) {
        installed.removeAll { $0 == integration.id }
        Keychain.set(nil, for: "integration." + integration.id)
        keysVersion += 1
    }

    func move(from source: IndexSet, to destination: Int) { installed.move(fromOffsets: source, toOffset: destination) }
}

// MARK: - Running them

/// What an integration found for one message.
struct IntegrationFinding: Sendable {
    var text: String?
    var links: [ToolUse.Link] = []
    var detail = ""
    var failed = false
    /// Messages and Mail: who it's for, when Contacts knows them.
    var recipient: String? = nil
}

@MainActor
enum IntegrationHub {
    static let health = HKHealthStore()
    /// Each finding's share of the prompt; the whole context is 2,048 tokens.
    static let budget = 650

    static func requestAccess(_ integration: Integration) async -> Bool {
        switch integration.id {
        case Integration.health.id, Integration.googleHealth.id:
            guard HKHealthStore.isHealthDataAvailable() else { return false }
            do { try await health.requestAuthorization(toShare: [], read: HealthReader.types); return true } catch { return false }
        case Integration.gallery.id:
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            return status == .authorized || status == .limited
        case Integration.contacts.id:
            return (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
        default: return true
        }
    }

    /// The step shown in the reply while it works.
    static func step(_ integration: Integration) -> ToolUse {
        let (running, done): (String, String) = switch integration.id {
        case Integration.github.id: ("Checking GitHub", "Checked GitHub")
        case Integration.chatgpt.id: ("Asking ChatGPT", "Asked ChatGPT")
        case Integration.claude.id: ("Asking Claude", "Asked Claude")
        case Integration.notion.id: ("Searching Notion", "Searched Notion")
        case Integration.messages.id: ("Drafting a text", "Drafted a text")
        case Integration.mail.id: ("Drafting an email", "Drafted an email")
        case Integration.appStore.id: ("Searching the App Store", "Searched the App Store")
        case Integration.gallery.id: ("Looking through your photos", "Looked through your photos")
        case Integration.health.id: ("Reading Health", "Read Health")
        case Integration.googleHealth.id: ("Reading Google Health", "Read Google Health")
        case Integration.contacts.id: ("Looking up contacts", "Looked up contacts")
        default: ("Using \(integration.name)", "Used \(integration.name)")
        }
        return ToolUse(kind: integration.connectorID, icon: integration.glyph, running: running, done: done)
    }

    static func read(_ integration: Integration, question: String, key: String?) async -> IntegrationFinding {
        var found: IntegrationFinding
        switch integration.id {
        case Integration.github.id: found = await GitHubReader.read(question, token: key)
        case Integration.chatgpt.id: found = await Assistants.chatGPT(question, key: key)
        case Integration.claude.id: found = await Assistants.claude(question, key: key)
        case Integration.notion.id: found = await NotionReader.read(question, key: key)
        case Integration.appStore.id: found = await AppStoreReader.read(question)
        case Integration.gallery.id: found = GalleryReader.read()
        case Integration.health.id: found = await HealthReader.read(onlyGoogle: false)
        case Integration.googleHealth.id: found = await HealthReader.read(onlyGoogle: true)
        case Integration.contacts.id: found = ContactsReader.read(question)
        case Integration.messages.id:
            let to = ContactsReader.recipient(in: question, email: false)
            found = IntegrationFinding(text: "Loocal will open Messages with your reply as the text\(to.map { " to \($0.name)" } ?? ""). Reply with only the message itself, ready to send: no preamble, no quotes, no notes after it.",
                                       detail: to.map { "To \($0.name)" } ?? "", recipient: to?.address)
        case Integration.mail.id:
            let to = ContactsReader.recipient(in: question, email: true)
            found = IntegrationFinding(text: "Loocal will open Mail with your reply as the email\(to.map { " to \($0.name)" } ?? ""). Reply with the subject on the first line as “Subject: …”, then a blank line, then only the email body, ready to send.",
                                       detail: to.map { "To \($0.name)" } ?? "", recipient: to?.address)
        default: found = IntegrationFinding(failed: true)
        }
        if let text = found.text, text.count > budget { found.text = String(text.prefix(budget)) + "…" }
        return found
    }

    /// Messages and Mail, once the reply is written: a link that opens the draft.
    static func draftLink(_ integration: Integration, reply: String, recipient: String?) -> ToolUse.Link? {
        let text = ToolCall.visible(reply).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#"))
        func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        if integration.id == Integration.messages.id {
            let to = (recipient ?? "").filter { $0.isNumber || $0 == "+" }
            return URL(string: "sms:\(to)&body=\(encode(text))").map { ToolUse.Link(title: "Open in Messages", url: $0) }
        }
        let (subject, body) = MailDraft.split(text)
        let to = encode(recipient ?? "")
        return URL(string: "mailto:\(to)?subject=\(encode(subject))&body=\(encode(body))").map { ToolUse.Link(title: "Open in Mail", url: $0) }
    }
}

enum MailDraft {
    /// "Subject: Lunch\n\nHi…" → ("Lunch", "Hi…"). Without a subject line, the body is all.
    static func split(_ text: String) -> (subject: String, body: String) {
        let lines = text.components(separatedBy: .newlines)
        guard let first = lines.first, let colon = first.firstIndex(of: ":"),
              ["subject", "objet", "sujet"].contains(first[..<colon].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "*", with: "").lowercased()) else {
            return ("", text)
        }
        let subject = first[first.index(after: colon)...].replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
        return (subject, lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - Services on the network

private enum HTTP {
    static func json(_ request: URLRequest) async throws -> Any {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]).flatMap { body in
                (body["error"] as? [String: Any])?["message"] as? String ?? body["message"] as? String
            }
            throw IslandError.message(message ?? "HTTP \(status)")
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    static func request(_ url: URL, headers: [String: String] = [:], body: [String: Any]? = nil, timeout: TimeInterval = 10) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return request
    }
}

enum GitHubReader {
    /// "apple/swift" or a github.com link in the message.
    static func repository(in text: String) -> String? {
        let pattern = #"(?:github\.com/)?\b([A-Za-z0-9][A-Za-z0-9-]{0,38})/([A-Za-z0-9._-]{1,100})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let owner = Range(match.range(at: 1), in: text), let name = Range(match.range(at: 2), in: text) else { return nil }
        let repo = String(text[name]).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return "\(text[owner])/\(repo)"
    }

    static func read(_ question: String, token: String?) async -> IntegrationFinding {
        var headers = ["Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"]
        if let token { headers["Authorization"] = "Bearer " + token }
        func get(_ path: String) async throws -> Any {
            try await HTTP.json(HTTP.request(URL(string: "https://api.github.com" + path)!, headers: headers))
        }
        do {
            if let repo = repository(in: question) {
                let info = try await get("/repos/\(repo)") as? [String: Any] ?? [:]
                let issues = try await get("/repos/\(repo)/issues?state=open&per_page=5") as? [[String: Any]] ?? []
                var lines = ["GitHub — \(repo): \(info["description"] as? String ?? "")",
                             "★ \(info["stargazers_count"] as? Int ?? 0) · \(info["open_issues_count"] as? Int ?? 0) open issues and pull requests · \(info["language"] as? String ?? "") · last push \(day(info["pushed_at"]))"]
                lines += issues.map { "#\($0["number"] as? Int ?? 0) \($0["pull_request"] == nil ? "" : "[PR] ")\($0["title"] as? String ?? "")" }
                let url = (info["html_url"] as? String).flatMap(URL.init(string:))
                return IntegrationFinding(text: lines.joined(separator: "\n"), links: url.map { [ToolUse.Link(title: repo, url: $0)] } ?? [], detail: repo)
            }
            if token != nil {
                let notes = try await get("/notifications?per_page=6") as? [[String: Any]] ?? []
                let assigned = try await get("/issues?filter=assigned&state=open&per_page=6") as? [[String: Any]] ?? []
                var lines = ["GitHub — unread notifications (\(notes.count)):"]
                lines += notes.map { note in
                    let subject = note["subject"] as? [String: Any] ?? [:]
                    let repo = (note["repository"] as? [String: Any])?["full_name"] as? String ?? ""
                    return "- \(repo): \(subject["title"] as? String ?? "") (\(subject["type"] as? String ?? ""), \(note["reason"] as? String ?? ""))"
                }
                lines.append("Open issues and pull requests assigned to the user (\(assigned.count)):")
                lines += assigned.map { "- \(($0["repository"] as? [String: Any])?["full_name"] as? String ?? "") #\($0["number"] as? Int ?? 0): \($0["title"] as? String ?? "")" }
                let links = assigned.prefix(4).compactMap { issue in
                    (issue["html_url"] as? String).flatMap(URL.init(string:)).map { ToolUse.Link(title: issue["title"] as? String ?? "Issue", url: $0) }
                }
                return IntegrationFinding(text: lines.joined(separator: "\n"), links: links, detail: "\(notes.count) notifications · \(assigned.count) assigned")
            }
            let terms = Wikipedia.keywords(question).prefix(4).joined(separator: " ")
            guard !terms.isEmpty, let q = terms.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                return IntegrationFinding(text: "GitHub is connected without a token, so Loocal can only search public repositories. Ask about a repository by name (owner/repo).", failed: true)
            }
            let result = try await get("/search/repositories?q=\(q)&sort=stars&per_page=5") as? [String: Any] ?? [:]
            let repos = result["items"] as? [[String: Any]] ?? []
            let lines = ["GitHub repositories for “\(terms)”:"] + repos.map { "- \($0["full_name"] as? String ?? "") ★\($0["stargazers_count"] as? Int ?? 0): \(($0["description"] as? String ?? "").prefix(90))" }
            let links = repos.prefix(4).compactMap { repo in
                (repo["html_url"] as? String).flatMap(URL.init(string:)).map { ToolUse.Link(title: repo["full_name"] as? String ?? "", url: $0) }
            }
            return IntegrationFinding(text: lines.joined(separator: "\n"), links: links, detail: "“\(terms)”", failed: repos.isEmpty)
        } catch {
            return IntegrationFinding(text: "GitHub couldn't be reached (\(error.localizedDescription)). Say so; don't guess.", detail: error.localizedDescription, failed: true)
        }
    }

    private static func day(_ value: Any?) -> String {
        guard let text = value as? String, let date = ISO8601DateFormatter().date(from: text) else { return "?" }
        return date.formatted(.relative(presentation: .named))
    }
}

enum AppStoreReader {
    static func read(_ question: String) async -> IntegrationFinding {
        let terms = Wikipedia.keywords(question).prefix(5).joined(separator: " ")
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [.init(name: "term", value: terms.isEmpty ? question : terms), .init(name: "entity", value: "software"),
                                 .init(name: "limit", value: "5"), .init(name: "country", value: Locale.current.region?.identifier ?? "US")]
        do {
            let body = try await HTTP.json(HTTP.request(components.url!)) as? [String: Any] ?? [:]
            let apps = body["results"] as? [[String: Any]] ?? []
            guard !apps.isEmpty else { return IntegrationFinding(text: "The App Store found no apps for “\(terms)”.", detail: "“\(terms)”", failed: true) }
            let lines = ["App Store results for “\(terms)”:"] + apps.map { app in
                let rating = (app["averageUserRating"] as? Double).map { String(format: "%.1f★", $0) } ?? "no rating"
                return "- \(app["trackName"] as? String ?? "") by \(app["sellerName"] as? String ?? ""), \(app["formattedPrice"] as? String ?? ""), \(rating) (\(app["userRatingCount"] as? Int ?? 0) ratings): \((app["description"] as? String ?? "").replacingOccurrences(of: "\n", with: " ").prefix(80))"
            }
            let links = apps.prefix(4).compactMap { app in
                (app["trackViewUrl"] as? String).flatMap(URL.init(string:)).map { ToolUse.Link(title: app["trackName"] as? String ?? "App", url: $0) }
            }
            return IntegrationFinding(text: lines.joined(separator: "\n"), links: links, detail: "“\(terms)”")
        } catch {
            return IntegrationFinding(text: "The App Store couldn't be reached. Say so.", detail: error.localizedDescription, failed: true)
        }
    }
}

enum NotionReader {
    static func read(_ question: String, key: String?) async -> IntegrationFinding {
        guard let key else { return IntegrationFinding(text: "Notion has no integration secret yet. Say it needs one in Settings › Integrations.", failed: true) }
        let terms = Wikipedia.keywords(question).prefix(4).joined(separator: " ")
        let request = HTTP.request(URL(string: "https://api.notion.com/v1/search")!, headers: ["Authorization": "Bearer " + key, "Notion-Version": "2022-06-28"],
                                   body: ["query": terms, "page_size": 6, "sort": ["direction": "descending", "timestamp": "last_edited_time"]])
        do {
            let body = try await HTTP.json(request) as? [String: Any] ?? [:]
            let results = (body["results"] as? [[String: Any]] ?? []).map { item -> (String, URL?, String) in
                let properties = item["properties"] as? [String: [String: Any]] ?? [:]
                let titled = properties.values.first { $0["type"] as? String == "title" }?["title"] as? [[String: Any]]
                    ?? item["title"] as? [[String: Any]] ?? []
                let title = titled.compactMap { $0["plain_text"] as? String }.joined()
                return (title.isEmpty ? "Untitled" : title, (item["url"] as? String).flatMap(URL.init(string:)), String((item["last_edited_time"] as? String ?? "").prefix(10)))
            }
            guard !results.isEmpty else { return IntegrationFinding(text: "Notion found no pages for “\(terms)” among the pages shared with Loocal.", detail: "“\(terms)”", failed: true) }
            let lines = ["Notion pages for “\(terms)”:"] + results.map { "- \($0.0) (edited \($0.2))" }
            return IntegrationFinding(text: lines.joined(separator: "\n"), links: results.prefix(4).compactMap { r in r.1.map { ToolUse.Link(title: r.0, url: $0) } }, detail: "“\(terms)”")
        } catch {
            return IntegrationFinding(text: "Notion couldn't be reached. Say so.", detail: error.localizedDescription, failed: true)
        }
    }
}

/// Another assistant answers first; the local model relays it.
enum Assistants {
    static let relay = "Use this answer to reply, in your own words and briefly. Say where it came from."
    /// ChatGPT's model, changeable in Settings › Integrations › ChatGPT.
    static var openAIModel: String {
        get { UserDefaults.standard.string(forKey: "integration.chatgpt.model") ?? "gpt-5-mini" }
        set { UserDefaults.standard.set(newValue, forKey: "integration.chatgpt.model") }
    }

    static func chatGPT(_ question: String, key: String?) async -> IntegrationFinding {
        guard let key else { return IntegrationFinding(text: "ChatGPT has no API key yet.", failed: true) }
        let request = HTTP.request(URL(string: "https://api.openai.com/v1/chat/completions")!, headers: ["Authorization": "Bearer " + key],
                                   body: ["model": openAIModel, "messages": [["role": "system", "content": "Answer concisely, in under 150 words."], ["role": "user", "content": question]]],
                                   timeout: 60)
        do {
            let body = try await HTTP.json(request) as? [String: Any] ?? [:]
            let text = (((body["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return IntegrationFinding(text: "ChatGPT returned nothing.", failed: true) }
            return IntegrationFinding(text: "ChatGPT's answer:\n\(text)\n\n\(relay)", detail: openAIModel)
        } catch {
            return IntegrationFinding(text: "ChatGPT couldn't be reached (\(error.localizedDescription)). Say so, then answer yourself.", detail: error.localizedDescription, failed: true)
        }
    }

    /// Claude Opus 5.5 over the Messages API. Low effort keeps it quick for a chat turn; a
    /// refusal falls back server-side to a model that can answer.
    static func claude(_ question: String, key: String?) async -> IntegrationFinding {
        guard let key else { return IntegrationFinding(text: "Claude has no API key yet.", failed: true) }
        let request = HTTP.request(URL(string: "https://api.anthropic.com/v1/messages")!,
                                   headers: ["x-api-key": key, "anthropic-version": "2026-10-21", "anthropic-beta": "server-side-fallback-2026-07-01"],
                                   body: ["model": "claude-opus-5-5", "max_tokens": 16000, "output_config": ["effort": "low"], "fallbacks": "default",
                                          "system": "A small assistant on the user's phone will relay your answer. Answer concisely, in under 150 words.",
                                          "messages": [["role": "user", "content": question]]],
                                   timeout: 90)
        do {
            let body = try await HTTP.json(request) as? [String: Any] ?? [:]
            if body["stop_reason"] as? String == "refusal" {
                return IntegrationFinding(text: "Claude declined to answer this. Say so.", detail: "Declined", failed: true)
            }
            let text = (body["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return IntegrationFinding(text: "Claude returned nothing.", failed: true) }
            return IntegrationFinding(text: "Claude's answer:\n\(text)\n\n\(relay)", detail: body["model"] as? String ?? "Claude Opus 5.5")
        } catch {
            return IntegrationFinding(text: "Claude couldn't be reached (\(error.localizedDescription)). Say so, then answer yourself.", detail: error.localizedDescription, failed: true)
        }
    }
}

// MARK: - On the phone

@MainActor
enum GalleryReader {
    static func read(now: Date = .now) -> IntegrationFinding {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            return IntegrationFinding(text: "Loocal isn't allowed to see the user's photos. Say so.", failed: true)
        }
        let calendar = Calendar.current
        func count(since days: Int, _ extra: String = "") -> Int {
            let options = PHFetchOptions()
            let start = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now))!
            options.predicate = NSPredicate(format: "creationDate >= %@" + extra, start as NSDate)
            return PHAsset.fetchAssets(with: options).count
        }
        let today = count(since: 0), week = count(since: 7), month = count(since: 30)
        let favourites = count(since: 30, " AND favorite == YES")
        let screenshots = count(since: 30, " AND (mediaSubtypes & %d) != 0".replacingOccurrences(of: "%d", with: "\(PHAssetMediaSubtype.photoScreenshot.rawValue)"))
        let videos = count(since: 30, " AND mediaType == \(PHAssetMediaType.video.rawValue)")
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 6
        let recent = PHAsset.fetchAssets(with: options)
        var lines = ["Photos (\(status == .limited ? "only the photos the user shared with Loocal" : "whole library")): \(today) today, \(week) in the last 7 days, \(month) in the last 30 days (\(videos) videos, \(screenshots) screenshots, \(favourites) favourites).", "Most recent:"]
        recent.enumerateObjects { asset, _, _ in
            let kind = asset.mediaType == .video ? "video \(Int(asset.duration))s" : asset.mediaSubtypes.contains(.photoScreenshot) ? "screenshot" : asset.mediaSubtypes.contains(.photoLive) ? "live photo" : "photo"
            lines.append("- \(kind), \(asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "unknown date")\(asset.location == nil ? "" : ", with a location")\(asset.isFavorite ? ", favourite" : "")")
        }
        return IntegrationFinding(text: lines.joined(separator: "\n"), detail: "\(week) this week")
    }
}

@MainActor
enum ContactsReader {
    static let keys: [CNKeyDescriptor] = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
                                          CNContactBirthdayKey, CNContactOrganizationNameKey].map { $0 as CNKeyDescriptor }

    static var allowed: Bool { CNContactStore.authorizationStatus(for: .contacts) == .authorized || CNContactStore.authorizationStatus(for: .contacts) == .limited }

    /// People named in the message (capitalised words that match a contact).
    static func people(in text: String, limit: Int = 3) -> [CNContact] {
        guard allowed else { return [] }
        let store = CNContactStore()
        let names = Wikipedia.keywords(text).filter { $0.first?.isUppercase == true && $0.count > 1 }
        var found: [CNContact] = []
        for name in names where found.count < limit {
            let matches = (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys)) ?? []
            for contact in matches where !found.contains(where: { $0.identifier == contact.identifier }) { found.append(contact) }
        }
        return Array(found.prefix(limit))
    }

    static func read(_ question: String) -> IntegrationFinding {
        guard allowed else { return IntegrationFinding(text: "Loocal isn't allowed to read the user's contacts. Say so.", failed: true) }
        let people = people(in: question)
        guard !people.isEmpty else { return IntegrationFinding(text: "No contact matches the names in this message.", detail: "No match") }
        let lines = people.map { contact in
            var parts = ["\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)]
            if !contact.organizationName.isEmpty { parts.append(contact.organizationName) }
            if let phone = contact.phoneNumbers.first?.value.stringValue { parts.append("phone \(phone)") }
            if let email = contact.emailAddresses.first?.value as String? { parts.append("email \(email)") }
            if let birthday = contact.birthday?.date { parts.append("birthday \(birthday.formatted(.dateTime.month(.wide).day()))") }
            return "- " + parts.joined(separator: ", ")
        }
        return IntegrationFinding(text: "Contacts:\n" + lines.joined(separator: "\n"), detail: people.map(\.givenName).joined(separator: ", "))
    }

    /// Who a draft is for: the first named contact with a number (or email).
    static func recipient(in text: String, email: Bool) -> (name: String, address: String)? {
        for contact in people(in: text) {
            let address = email ? contact.emailAddresses.first.map { $0.value as String } : contact.phoneNumbers.first?.value.stringValue
            if let address { return (contact.givenName, address) }
        }
        return nil
    }
}

enum HealthReader {
    static let quantities: [HKQuantityTypeIdentifier] = [.stepCount, .distanceWalkingRunning, .activeEnergyBurned, .restingHeartRate]
    static var types: Set<HKObjectType> {
        Set(quantities.map { HKQuantityType($0) as HKObjectType } + [HKCategoryType(.sleepAnalysis), HKObjectType.workoutType()])
    }

    @MainActor
    static func read(onlyGoogle: Bool, now: Date = .now) async -> IntegrationFinding {
        let store = IntegrationHub.health
        guard HKHealthStore.isHealthDataAvailable() else { return IntegrationFinding(text: "Health data isn't available on this device. Say so.", failed: true) }
        var from: NSPredicate? = nil
        if onlyGoogle {
            let sources = await googleSources(store)
            guard !sources.isEmpty else {
                return IntegrationFinding(text: "Apple Health has no data from Fitbit or Google Fit yet. Say so, and that syncing to Apple Health can be turned on in the Fitbit or Google Fit app.", detail: "No Fitbit or Google Fit data", failed: true)
            }
            from = HKQuery.predicateForObjects(from: sources)
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let weekStart = calendar.date(byAdding: .day, value: -6, to: today)!
        func within(_ start: Date, _ end: Date = now) -> NSPredicate {
            let time = HKQuery.predicateForSamples(withStart: start, end: end)
            return from.map { NSCompoundPredicate(andPredicateWithSubpredicates: [time, $0]) } ?? time
        }
        func sum(_ id: HKQuantityTypeIdentifier, _ start: Date, _ unit: HKUnit) async -> Double? {
            let descriptor = HKStatisticsQueryDescriptor(predicate: .quantitySample(type: HKQuantityType(id), predicate: within(start)), options: .cumulativeSum)
            return (try? await descriptor.result(for: store))?.sumQuantity()?.doubleValue(for: unit)
        }
        let steps = await sum(.stepCount, today, .count()), weekSteps = await sum(.stepCount, weekStart, .count())
        let distance = await sum(.distanceWalkingRunning, today, .meterUnit(with: .kilo))
        let energy = await sum(.activeEnergyBurned, today, .kilocalorie())
        let resting = try? await HKSampleQueryDescriptor(predicates: [.quantitySample(type: HKQuantityType(.restingHeartRate), predicate: from)],
                                                         sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)], limit: 1).result(for: store).first
        // Last night: from 6 pm yesterday.
        let evening = calendar.date(byAdding: .hour, value: -6, to: today)!
        let sleep = (try? await HKSampleQueryDescriptor(predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: within(evening))],
                                                         sortDescriptors: [], limit: 200).result(for: store)) ?? []
        let asleep = sleep.filter { HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue).contains($0.value) }
            .reduce(0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
        let workouts = (try? await HKSampleQueryDescriptor(predicates: [.workout(within(calendar.date(byAdding: .day, value: -7, to: now)!))],
                                                            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)], limit: 4).result(for: store)) ?? []
        var lines = [onlyGoogle ? "Google Health (Fitbit and Google Fit data in Apple Health):" : "Health:"]
        if let steps { lines.append("Today: \(Int(steps)) steps" + (distance.map { String(format: ", %.1f km", $0) } ?? "") + (energy.map { ", \(Int($0)) kcal active" } ?? "")) }
        if let weekSteps { lines.append("Last 7 days: \(Int(weekSteps / 7)) steps a day on average") }
        if asleep > 0 { lines.append("Last night: \(Int(asleep / 3600)) h \(Int(asleep.truncatingRemainder(dividingBy: 3600) / 60)) min asleep") }
        if let resting { lines.append("Resting heart rate: \(Int(resting.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())))) bpm (\(resting.endDate.formatted(.relative(presentation: .named))))") }
        for workout in workouts {
            lines.append("Workout: \(workout.workoutActivityType.label), \(Int(workout.duration / 60)) min, \(workout.startDate.formatted(.relative(presentation: .named)))")
        }
        guard lines.count > 1 else {
            return IntegrationFinding(text: "Health returned nothing: either there's no data yet or Loocal isn't allowed to read it (Settings › Health › Data Access). Say so.", detail: "Nothing to read", failed: true)
        }
        return IntegrationFinding(text: lines.joined(separator: "\n"), detail: steps.map { "\(Int($0)) steps today" } ?? "")
    }

    /// Fitbit and Google Fit as sources in Apple Health.
    private static func googleSources(_ store: HKHealthStore) async -> Set<HKSource> {
        await withCheckedContinuation { continuation in
            let query = HKSourceQuery(sampleType: HKQuantityType(.stepCount), samplePredicate: nil) { _, sources, _ in
                let google = (sources ?? []).filter { source in
                    let id = source.bundleIdentifier.lowercased()
                    return id.contains("google") || id.contains("fitbit")
                }
                continuation.resume(returning: google)
            }
            store.execute(query)
        }
    }
}

private extension HKWorkoutActivityType {
    var label: String {
        switch self {
        case .running: "run"
        case .walking: "walk"
        case .cycling: "ride"
        case .swimming: "swim"
        case .hiking: "hike"
        case .yoga: "yoga"
        case .traditionalStrengthTraining, .functionalStrengthTraining: "strength training"
        case .highIntensityIntervalTraining: "HIIT"
        case .tennis: "tennis"
        case .soccer: "football"
        default: "workout"
        }
    }
}

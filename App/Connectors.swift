import EventKit
import Foundation
import Security
import UIKit

/// A source of context the model can read. Built-ins are fetched on device right before a
/// reply and added to the system prompt; MCP servers expose tools the model can call.
struct Connector: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String
    let detail: String

    static let calendar = Connector(id: "calendar", name: "Calendar", icon: "calendar", detail: "Your next 7 days")
    static let reminders = Connector(id: "reminders", name: "Reminders", icon: "checklist", detail: "Open reminders")
    static let clipboard = Connector(id: "clipboard", name: "Clipboard", icon: "doc.on.clipboard", detail: "What you last copied")
    static let wikipedia = Connector(id: "wikipedia", name: "Wikipedia", icon: "globe", detail: "Looks your question up online")
    static let builtIn = [calendar, reminders, clipboard, wikipedia]

    static func mcp(_ server: MCPServer) -> Connector {
        Connector(id: server.connectorID, name: server.name, icon: "server.rack", detail: "\(server.tools.count) tools · \(server.url.host() ?? "")")
    }
}

// MARK: - Built-in context

@MainActor
enum ConnectorHub {
    static let store = EKEventStore()
    /// Each connector's share of the prompt; the whole context window is only 2,048 tokens.
    private static let budget = 700

    /// Ask for the permission a connector needs when it's switched on.
    static func requestAccess(for id: String) async -> Bool {
        switch id {
        case Connector.calendar.id: return (try? await store.requestFullAccessToEvents()) ?? false
        case Connector.reminders.id: return (try? await store.requestFullAccessToReminders()) ?? false
        default: return true
        }
    }

    static func context(for active: Set<String>, prompt: String) async -> String {
        var parts: [String] = []
        if active.contains(Connector.calendar.id), let text = calendar() { parts.append(text) }
        if active.contains(Connector.reminders.id), let text = await reminders() { parts.append(text) }
        if active.contains(Connector.clipboard.id), let text = UIPasteboard.general.string, !text.isEmpty {
            parts.append("Clipboard:\n" + String(text.prefix(budget)))
        }
        if active.contains(Connector.wikipedia.id), let text = await Wikipedia.summary(for: prompt) { parts.append(text) }
        guard !parts.isEmpty else { return "" }
        return "Context from the user's connected sources (use it when relevant):\n\n" + parts.joined(separator: "\n\n")
    }

    private static func calendar() -> String? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let start = Date.now, end = Calendar.current.date(byAdding: .day, value: 7, to: start)!
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil)).prefix(14)
        guard !events.isEmpty else { return "Calendar: nothing scheduled in the next 7 days." }
        let lines = events.map { event in
            let when = event.isAllDay ? event.startDate.formatted(.dateTime.weekday().day().month()) + " (all day)" : event.startDate.formatted(.dateTime.weekday().day().month().hour().minute())
            return "- \(when): \(event.title ?? "Untitled")" + (event.location.map { " @ \($0)" } ?? "")
        }
        return String(("Calendar (next 7 days):\n" + lines.joined(separator: "\n")).prefix(budget))
    }

    private static func reminders() async -> String? {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return nil }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let titles: [String] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let items = (reminders ?? []).prefix(14).map { reminder in
                    let due = reminder.dueDateComponents?.date.map { " (due \($0.formatted(.dateTime.day().month())))" } ?? ""
                    return "- \(reminder.title ?? "Untitled")\(due)"
                }
                continuation.resume(returning: Array(items))
            }
        }
        guard !titles.isEmpty else { return "Reminders: none open." }
        return String(("Open reminders:\n" + titles.joined(separator: "\n")).prefix(budget))
    }
}

/// Wikipedia search + summary in the device language. Sends only the question text.
enum Wikipedia {
    static func summary(for question: String) async -> String? {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        var search = URLComponents(string: "https://\(language).wikipedia.org/w/api.php")!
        let terms = keywords(question)
        guard !terms.isEmpty else { return nil }
        search.queryItems = [.init(name: "action", value: "query"), .init(name: "list", value: "search"), .init(name: "srsearch", value: terms.joined(separator: " ")), .init(name: "srlimit", value: "5"), .init(name: "format", value: "json")]
        guard let url = search.url,
              let data = try? await fetch(url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hits = ((root["query"] as? [String: Any])?["search"] as? [[String: Any]])?.compactMap({ $0["title"] as? String }),
              // Prefer the result whose title shares the most words with the question.
              let title = hits.enumerated().max(by: { overlap($0.element, terms) - Double($0.offset) * 0.01 < overlap($1.element, terms) - Double($1.offset) * 0.01 })?.element,
              let page = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let summaryURL = URL(string: "https://\(language).wikipedia.org/api/rest_v1/page/summary/\(page)"),
              let summaryData = try? await fetch(summaryURL),
              let summary = try? JSONSerialization.jsonObject(with: summaryData) as? [String: Any],
              let extract = summary["extract"] as? String else { return nil }
        return "Wikipedia — \(title):\n" + String(extract.prefix(700))
    }

    private static let stopwords: Set<String> = ["a", "an", "the", "is", "are", "was", "were", "be", "of", "in", "on", "at", "to", "for", "and", "or", "what", "who", "whom", "which", "when", "where", "why", "how", "tall", "big", "old", "much", "many", "does", "do", "did", "can", "could", "tell", "me", "about", "i", "you", "it", "its", "le", "la", "les", "un", "une", "des", "de", "du", "est", "qui", "que", "quoi", "quel", "quelle", "comment", "pourquoi", "où", "et", "en"]

    /// Search terms: proper nouns if the question has any, otherwise its content words.
    static func keywords(_ question: String) -> [String] {
        let words = question.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'-")).inverted).filter { !$0.isEmpty }
        let proper = words.dropFirst().filter { $0.first?.isUppercase == true }
        if !proper.isEmpty { return Array(proper) }
        return words.filter { !stopwords.contains($0.lowercased()) }
    }

    private static func overlap(_ title: String, _ terms: [String]) -> Double {
        let words = Set(title.lowercased().split(separator: " ").map(String.init))
        return Double(terms.filter { words.contains($0.lowercased()) }.count)
    }

    private static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.setValue("Loocal/1.0 (iOS app)", forHTTPHeaderField: "User-Agent")
        return try await URLSession.shared.data(for: request).0
    }
}

// MARK: - MCP

struct MCPTool: Codable, Hashable, Sendable {
    var name: String
    var description: String
    /// The tool's JSON input schema, stored as text.
    var schema: String
}

struct MCPServer: Codable, Identifiable, Hashable {
    var id = UUID()
    var url: URL
    var name: String
    var tools: [MCPTool]
    var connectorID: String { "mcp:" + id.uuidString }

    static func load() -> [MCPServer] {
        guard let data = UserDefaults.standard.data(forKey: "mcp.servers") else { return [] }
        return (try? JSONDecoder().decode([MCPServer].self, from: data)) ?? []
    }

    static func save(_ servers: [MCPServer]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(servers), forKey: "mcp.servers")
    }
}

/// One MCP tool as the model sees it, with what's needed to call it.
struct ToolDefinition: Sendable {
    let url: URL
    let token: String?
    let tool: MCPTool
}

/// Minimal MCP client over the Streamable HTTP transport: JSON-RPC requests whose replies
/// arrive as JSON or as a short server-sent-event stream.
actor MCPClient {
    private let url: URL
    private let token: String?
    private var sessionID: String?
    private var nextID = 1

    init(url: URL, token: String?) {
        self.url = url
        self.token = token
    }

    /// Handshake, then list tools. Returns the server's name and its tools.
    func discover() async throws -> (name: String, tools: [MCPTool]) {
        let info = try await handshake()
        let listed = try await call("tools/list", params: [:])
        let tools = (listed["tools"] as? [[String: Any]] ?? []).compactMap { tool -> MCPTool? in
            guard let name = tool["name"] as? String else { return nil }
            let schema = (tool["inputSchema"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return MCPTool(name: name, description: tool["description"] as? String ?? "", schema: schema)
        }
        return (info, tools)
    }

    /// Run one tool and return its text output.
    func run(_ tool: String, argumentsJSON: String) async throws -> String {
        _ = try await handshake()
        let arguments = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) ?? [String: Any]()
        let result = try await call("tools/call", params: ["name": tool, "arguments": arguments])
        let text = (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        if result["isError"] as? Bool == true { return "Tool error: " + text }
        return text.isEmpty ? "(no output)" : text
    }

    private func handshake() async throws -> String {
        let result = try await call("initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "Loocal", "version": "1.0"],
        ])
        try await notify("notifications/initialized")
        return (result["serverInfo"] as? [String: Any])?["name"] as? String ?? url.host() ?? "MCP server"
    }

    private func notify(_ method: String) async throws {
        _ = try await send(["jsonrpc": "2.0", "method": method])
    }

    private func call(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        let messages = try await send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        guard let reply = messages.first(where: { ($0["id"] as? Int) == id }) ?? messages.first else {
            throw IslandError.message("The MCP server didn’t answer \(method).")
        }
        if let error = reply["error"] as? [String: Any] {
            throw IslandError.message("MCP: \(error["message"] as? String ?? "request failed")")
        }
        return reply["result"] as? [String: Any] ?? [:]
    }

    private func send(_ body: [String: Any]) async throws -> [[String: Any]] {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw IslandError.message("MCP: no response.") }
        if let session = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = session }
        guard (200..<300).contains(http.statusCode) else {
            throw IslandError.message(http.statusCode == 401 ? "MCP: the server needs a valid token." : "MCP: server returned \(http.statusCode).")
        }
        if data.isEmpty { return [] }
        if http.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true {
            return String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline) // handles \r\n, a single Character in Swift
                .filter { $0.hasPrefix("data:") }
                .compactMap { line in try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any] }
        }
        let object = try JSONSerialization.jsonObject(with: data)
        return (object as? [[String: Any]]) ?? [(object as? [String: Any]) ?? [:]]
    }
}

/// MCP bearer tokens live in the Keychain, never in UserDefaults.
enum Keychain {
    private static let service = "local.islandai.mcp"

    static func set(_ value: String?, for account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Tool calls in model output

/// Parses a Hermes-style `<tool_call>{"name": …, "arguments": {…}}</tool_call>` block.
enum ToolCall {
    static let open = "<tool_call>"

    static func parse(_ text: String) -> (name: String, argumentsJSON: String)? {
        guard let start = text.range(of: open) else { return nil }
        var body = text[start.upperBound...]
        if let end = body.range(of: "</tool_call>") { body = body[..<end.lowerBound] }
        guard let data = body.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["name"] as? String else { return nil }
        let arguments = object["arguments"].flatMap { try? JSONSerialization.data(withJSONObject: $0) }.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return (name, arguments)
    }

    /// The part of the text that should be shown: everything before a tool call starts.
    static func visible(_ text: String) -> String {
        text.components(separatedBy: open).first ?? text
    }
}

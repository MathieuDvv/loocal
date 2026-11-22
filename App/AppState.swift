import Foundation
import Observation
import PDFKit
import UIKit

@MainActor @Observable
final class AppState {
    let files: LocalFiles
    /// One download per model, keyed by `ModelChoice.id`.
    let downloads: [String: ModelDownload]
    /// Open-source Kokoro voices for speech output.
    let neuralVoices: NeuralVoiceStore
    /// Errands: one-off and scheduled jobs the model carries out on device.
    let desk: ErrandDesk
    /// Every background download session, for routing iOS completion events.
    var allDownloads: [ModelDownload] { Array(downloads.values) + [neuralVoices.engine] }
    var selectedModelID: String { didSet { UserDefaults.standard.set(selectedModelID, forKey: "model") } }
    var personas: [Persona] { didSet { Persona.save(personas); BotShape.sync(personas) } }
    var personaID: UUID? { didSet { UserDefaults.standard.set(personaID?.uuidString, forKey: "persona") } }
    var conversations: [Conversation]
    var selectedID: UUID
    var draft = ""
    var attachmentName: String?
    /// Files attached to the next message; their text goes to the model with it.
    var attachedFiles: [AttachedFile] = []
    var activeConnectors: Set<String> { didSet { UserDefaults.standard.set(Array(activeConnectors), forKey: "connectors.active") } }
    var mcpServers: [MCPServer] { didSet { MCPServer.save(mcpServers) } }
    var connectors: [Connector] { Connector.builtIn + mcpServers.map(Connector.mcp) }
    var isBusy = false
    var phase = "Ready"
    var tokens = 0
    var performance = ""
    var notice: String?
    var error: String?
    @ObservationIgnored private let engine = InferenceEngine()
    @ObservationIgnored private let continued = ContinuedInference()
    @ObservationIgnored private let activity = ActivityController()
    @ObservationIgnored private var generation: Task<Void, Never>?
    @ObservationIgnored private var lastSaved = Date.distantPast
    @ObservationIgnored private var stopReason: String?
    private(set) var isDemo = false
    /// The prompt box shows once the model is installed (the simulator demo pretends it is).
    var composerReady: Bool { download.isReady || isDemo }
    /// Short UIKit grace period, used only when iOS declined the continued-processing task.
    @ObservationIgnored private var graceTask: UIBackgroundTaskIdentifier = .invalid

    var model: ModelChoice { ModelChoice.with(id: selectedModelID) }
    var download: ModelDownload { downloads[model.id]! }
    var persona: Persona? { personas.first { $0.id == personaID } }
    var systemPrompt: String {
        let custom = persona?.prompt.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? InferenceEngine.defaultSystemPrompt : custom
    }

    var current: Conversation { conversations.first(where: { $0.id == selectedID }) ?? Conversation() }
    var canSend: Bool { download.isReady && !isBusy && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachmentName != nil || !attachedFiles.isEmpty) }

    init() throws {
        let files = try LocalFiles()
        self.files = files
        desk = ErrandDesk(directory: files.root)
        var downloads: [String: ModelDownload] = [:]
        for choice in ModelChoice.all {
            let directory = choice.folder.map { files.models.appendingPathComponent($0, isDirectory: true) } ?? files.models
            downloads[choice.id] = ModelDownload(spec: try .bundled(choice.manifest), directory: directory, sessionID: choice.sessionID, chunked: choice.parallelDownload)
        }
        self.downloads = downloads
        neuralVoices = NeuralVoiceStore(models: files.models)
        VoiceLibrary.preload()
        selectedModelID = ModelChoice.with(id: UserDefaults.standard.string(forKey: "model") ?? "").id
        let savedPersonas = Persona.load()
        personas = savedPersonas
        BotShape.sync(savedPersonas)
        personaID = UserDefaults.standard.string(forKey: "persona").flatMap(UUID.init(uuidString:))
        var connectorsOn = Set(UserDefaults.standard.stringArray(forKey: "connectors.active") ?? [])
        // Web search starts switched on, once; after that it stays however you leave it.
        if !UserDefaults.standard.bool(forKey: "connectors.webDefault") {
            connectorsOn.insert(Connector.web.id)
            UserDefaults.standard.set(true, forKey: "connectors.webDefault")
            UserDefaults.standard.set(Array(connectorsOn), forKey: "connectors.active")
        }
        activeConnectors = connectorsOn
        mcpServers = MCPServer.load()
        let first = Conversation()
        conversations = [first]
        selectedID = first.id
        do {
            if let archive = try files.load(), !archive.conversations.isEmpty {
                conversations = archive.conversations
                selectedID = conversations.contains(where: { $0.id == archive.selectedID }) ? archive.selectedID : conversations[0].id
            }
        } catch {
            let backup = files.root.appendingPathComponent("conversations-recovery-" + UUID().uuidString + ".json")
            do {
                try FileManager.default.copyItem(at: files.archive, to: backup)
                self.error = "Saved chats couldn’t be read. A recovery copy is preserved on this device. \(error.localizedDescription)"
            } catch {
                // Never overwrite unreadable history if its recovery copy cannot be made.
                throw IslandError.message("Saved chats couldn’t be recovered: \(error.localizedDescription)")
            }
        }
        if self.error == nil {
            files.sweep(keeping: Set(conversations.flatMap { $0.messages.compactMap(\.imageName) }))
        }
    }

    /// Conversations worth listing in History (blank drafts are hidden).
    var history: [Conversation] { conversations.filter { !$0.messages.isEmpty && !$0.isTemporary } }
    var isTemporary: Bool { current.isTemporary }

    /// Flip a fresh, empty chat between normal and temporary.
    func toggleTemporary() {
        guard !isBusy, let index = conversations.firstIndex(where: { $0.id == selectedID }), conversations[index].messages.isEmpty else { return }
        conversations[index].temporary = conversations[index].isTemporary ? nil : true
    }

    /// Temporary chats vanish as soon as you move on from them.
    private func discardTemporary(keeping id: UUID? = nil) {
        for conversation in conversations where conversation.isTemporary && conversation.id != id && !conversation.messages.isEmpty {
            for name in conversation.messages.compactMap(\.imageName) { try? FileManager.default.removeItem(at: files.images.appendingPathComponent(name)) }
            conversations.removeAll { $0.id == conversation.id }
        }
    }

    func newConversation() {
        guard !isBusy else { return }
        discardTemporary()
        if let index = conversations.firstIndex(where: { $0.messages.isEmpty }) {
            conversations[index].temporary = nil
            selectedID = conversations[index].id // Reuse an untouched chat rather than stacking empty ones.
        } else {
            let conversation = Conversation()
            conversations.insert(conversation, at: 0)
            selectedID = conversation.id
        }
        draft = ""
        discardAttachment()
        performance = ""
        save()
    }

    func select(_ conversation: Conversation) {
        guard !isBusy else { return }
        discardTemporary(keeping: conversation.id)
        selectedID = conversation.id
        draft = ""
        discardAttachment()
        performance = ""
        save()
    }

    #if DEBUG && targetEnvironment(simulator)
    /// Simulator-only sample transcript for UI review (`-uiDemo` launch argument). Never saved.
    func loadDemo() {
        let day: TimeInterval = 86_400
        let thinking = Conversation(createdAt: .now, messages: [
            ChatMessage(role: .user, text: "What’s a good way to start journaling again after a long break?"),
            ChatMessage(role: .assistant, text: "Start smaller than feels useful. **Two lines a night** is enough: one thing that happened, one thing you noticed about it.\n\nIf a blank page stalls you, keep a single prompt for a week — *what took more energy than expected today?* — and let the habit come before the depth."),
            ChatMessage(role: .user, text: "And if I miss a few days?"),
            ChatMessage(role: .assistant, text: "", status: .generating),
        ])
        conversations = [
            thinking,
            Conversation(createdAt: .now.addingTimeInterval(-3_600), messages: [ChatMessage(role: .user, text: "Explain what’s happening in this photo.", imageName: demoPhoto()), ChatMessage(role: .assistant, text: "A heron standing in shallow water at dusk, mid-strike.")]),
            Conversation(createdAt: .now.addingTimeInterval(-day), messages: [ChatMessage(role: .user, text: "Draft a short, warm note to my landlord"), ChatMessage(role: .assistant, text: "Hi Sam — thanks for sorting the boiler so quickly.")]),
            Conversation(createdAt: .now.addingTimeInterval(-4 * day), messages: [ChatMessage(role: .user, text: "Help me think through an idea: a tiny weekly newsletter"), ChatMessage(role: .assistant, text: "Begin with who it’s for, then the one thing they’d miss.")]),
            Conversation(createdAt: .now.addingTimeInterval(-20 * day), messages: [ChatMessage(role: .user, text: "Compare two ways to brew cold coffee"), ChatMessage(role: .assistant, text: "Immersion is forgiving; drip is brighter.")]),
        ]
        selectedID = thinking.id
        phase = "Loading model"
        isDemo = true
        let brief = Errand(title: "Morning brief", instructions: ErrandIdea.all[0].instructions, cadence: .daily, hour: 7, minute: 30, weekday: 2, sources: [Connector.calendar.id, Connector.reminders.id], lastRun: .now)
        let week = Errand(title: "Plan my week", instructions: ErrandIdea.all[1].instructions, cadence: .weekly, hour: 8, minute: 0, weekday: 2, sources: [Connector.calendar.id], lastRun: .now)
        desk.loadSamples([brief, week], runs: [
            ErrandRun(errandID: brief.id, title: "Morning brief", instructions: brief.instructions, sources: brief.sources, startedAt: .now.addingTimeInterval(-5_400),
                      text: "**Tuesday, gently.**\n\nTwo things on the calendar: *design review at 10:00* and *dinner with Léa at 19:30*.\n\nDue today: renew the bike insurance. Start there, it takes ten minutes.", status: .done),
            ErrandRun(title: "Sort my reminders", instructions: ErrandIdea.all[2].instructions, sources: [Connector.reminders.id], startedAt: .now.addingTimeInterval(-day - 2_000),
                      text: "**Reminders, sorted.**\n\n**Today** · call the dentist, renew insurance\n**This week** · return the parcel, book train\n**Someday** · learn to fix the bike\n\nDrop: “check that thing”, it has no next step.", status: .done),
            ErrandRun(errandID: week.id, title: "Plan my week", instructions: week.instructions, sources: week.sources, startedAt: .now.addingTimeInterval(-3 * day),
                      text: "**Your week.**\n\nMonday is light. Wednesday is tight: three meetings back to back, so prepare the review notes on Tuesday.", status: .done),
        ])
        streamDemo(conversationID: thinking.id, replyID: thinking.messages[3].id)
        if personas.isEmpty {
            personas = [
                Persona(name: "Editor", icon: "pencil.line", prompt: "You are a sharp, kind editor. Tighten prose, keep the author's voice, and explain each change in one line."),
                Persona(name: "Coach", icon: "flame", prompt: "You are a direct coach. Ask one clarifying question, then give a concrete next step."),
            ]
        }
    }

    /// A portrait gradient standing in for a photo, to check how attached images sit.
    private func demoPhoto() -> String {
        let name = "demo-photo.jpg"
        let size = CGSize(width: 900, height: 1200)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor(red: 0.95, green: 0.62, blue: 0.42, alpha: 1).cgColor, UIColor(red: 0.28, green: 0.32, blue: 0.55, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        }
        try? image.jpegData(compressionQuality: 0.8)?.write(to: files.images.appendingPathComponent(name))
        return name
    }

    /// Loops a fake streamed reply so the handwriting effect can be seen without a model.
    private func streamDemo(conversationID: UUID, replyID: UUID) {
        let reply = "Then nothing is lost. Pick it back up with **tonight’s two lines**: no catching up, no apology.\n\nThe habit is the return, not the streak."
        Task { @MainActor [weak self] in
            while let self {
                self.setDemoReply(conversationID, replyID, text: "", status: .generating)
                self.setDemoTools(conversationID, replyID, [])
                self.phase = "Loading model"
                try? await Task.sleep(for: .seconds(1.8))
                self.phase = "Thinking"
                try? await Task.sleep(for: .seconds(1.2))
                var search = ToolUse(kind: Connector.web.id, icon: "magnifyingglass", running: "Searching the web", done: "Searched the web", detail: "restarting a journaling habit")
                self.setDemoTools(conversationID, replyID, [search])
                try? await Task.sleep(for: .seconds(2.2))
                search.status = .done
                search.links = [
                    ToolUse.Link(title: "How to get back into journaling", url: URL(string: "https://www.nytimes.com/journaling")!),
                    ToolUse.Link(title: "The two-minute rule for habits", url: URL(string: "https://jamesclear.com/two-minute-rule")!),
                    ToolUse.Link(title: "Journaling — Wikipedia", url: URL(string: "https://en.wikipedia.org/wiki/Diary")!),
                ]
                self.setDemoTools(conversationID, replyID, [search])
                try? await Task.sleep(for: .seconds(0.8))
                self.phase = "Generating"
                var text = ""
                var rest = Substring(reply)
                while !rest.isEmpty {
                    let chunk = rest.prefix(Int.random(in: 2...7))
                    rest = rest.dropFirst(chunk.count)
                    text += chunk
                    self.setDemoReply(conversationID, replyID, text: text, status: .generating)
                    self.tokens += 1
                    try? await Task.sleep(for: .milliseconds(Int.random(in: 60...110)))
                }
                self.setDemoReply(conversationID, replyID, text: text, status: .complete)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// A scripted errand run, so the Errands pages can be reviewed without a model.
    private func demoErrand(_ run: ErrandRun) {
        let replies = [
            "**Done.**\n\nHere’s what I found, laid out so you can act on it in a minute.\n\n- The most urgent item is first.\n- Everything else can wait until tomorrow.",
            "**Sorted.**\n\nThree things matter today. The rest is noise, so I left it out.",
            "**All set.**\n\nShort version: you’re free after 16:00, and nothing clashes this week.",
        ]
        let reply = replies[abs(run.id.hashValue) % replies.count]
        isBusy = true
        desk.begin(run.id)
        let gathered = errandContexts[run.id]
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await gathered?.value
            self.desk.setStage(run.id, "Thinking")
            try? await Task.sleep(for: .seconds(1))
            self.desk.setStage(run.id, "Writing")
            var text = "", rest = Substring(reply), count = 0
            while !rest.isEmpty {
                guard self.desk.runs.first(where: { $0.id == run.id })?.status == .running else { break }
                let chunk = rest.prefix(Int.random(in: 2...6))
                rest = rest.dropFirst(chunk.count)
                text += chunk
                count += 1
                self.desk.update(run.id, text: text, tokens: count * 4)
                try? await Task.sleep(for: .milliseconds(Int.random(in: 60...110)))
            }
            if self.desk.runs.first(where: { $0.id == run.id })?.status == .running { self.desk.finish(run.id, status: .done) }
            self.errandContexts[run.id] = nil
            self.isBusy = false
            self.phase = "Complete"
            self.pumpErrands()
        }
    }

    private func setDemoReply(_ conversationID: UUID, _ replyID: UUID, text: String, status: ChatMessage.Status) {
        guard let ci = conversations.firstIndex(where: { $0.id == conversationID }), let mi = conversations[ci].messages.firstIndex(where: { $0.id == replyID }) else { return }
        conversations[ci].messages[mi].text = text
        conversations[ci].messages[mi].status = status
    }

    private func setDemoTools(_ conversationID: UUID, _ replyID: UUID, _ tools: [ToolUse]) {
        guard let ci = conversations.firstIndex(where: { $0.id == conversationID }), let mi = conversations[ci].messages.firstIndex(where: { $0.id == replyID }) else { return }
        conversations[ci].messages[mi].tools = tools.isEmpty ? nil : tools
    }
    #endif

    // MARK: Message actions

    /// Put a sent prompt back in the composer and rewind the chat to just before it.
    func edit(_ message: ChatMessage) {
        guard !isBusy, let ci = conversations.firstIndex(where: { $0.id == selectedID }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == message.id }) else { return }
        draft = message.text
        for name in conversations[ci].messages[mi...].compactMap(\.imageName) {
            try? FileManager.default.removeItem(at: files.images.appendingPathComponent(name))
        }
        conversations[ci].messages.removeSubrange(mi...)
        performance = ""
        save()
    }

    /// Replace the last reply with a fresh one.
    func regenerate() {
        guard !isBusy, download.isReady, let ci = conversations.firstIndex(where: { $0.id == selectedID }),
              conversations[ci].messages.last?.role == .assistant else { return }
        conversations[ci].messages.removeLast()
        guard conversations[ci].messages.last?.role == .user else { save(); return }
        beginReply(in: ci)
    }

    func canRegenerate(_ message: ChatMessage) -> Bool {
        !isBusy && download.isReady && current.messages.last?.id == message.id && message.role == .assistant
    }

    // MARK: Attachments and connectors

    /// Read a picked file as text (PDFs via PDFKit), trimmed to fit the phone context.
    func attachFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var text: String?
        if url.pathExtension.lowercased() == "pdf" {
            text = PDFDocument(url: url)?.string
        } else if let data = try? Data(contentsOf: url) {
            text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            if let candidate = text, candidate.contains("\u{0}") { text = nil } // binary
        }
        guard let body = text?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty else {
            error = "“\(url.lastPathComponent)” has no readable text. Text, Markdown, code, CSV, JSON and PDF files work."
            return
        }
        let limit = 4_000
        let clipped = body.count > limit ? String(body.prefix(limit)) + "\n[…file truncated to fit the phone context]" : body
        attachedFiles.append(AttachedFile(name: url.lastPathComponent, text: clipped))
    }

    func toggleConnector(_ connector: Connector) async {
        if activeConnectors.contains(connector.id) { activeConnectors.remove(connector.id); return }
        guard await ConnectorHub.requestAccess(for: connector.id) else {
            error = "Allow Loocal to access \(connector.name) in Settings to use it."
            return
        }
        activeConnectors.insert(connector.id)
    }

    /// Connect to an MCP server, list its tools and keep it (token in the Keychain).
    func addMCPServer(_ address: String, token: String) async {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed.contains("://") ? trimmed : "https://" + trimmed), url.scheme == "https" || url.host() == "localhost" else {
            error = "Enter the server’s https URL."
            return
        }
        do {
            let found = try await MCPClient(url: url, token: token.isEmpty ? nil : token).discover()
            let server = MCPServer(url: url, name: found.name, tools: found.tools)
            Keychain.set(token, for: server.id.uuidString)
            mcpServers.append(server)
            activeConnectors.insert(server.connectorID)
            notice = "Connected to \(found.name) · \(found.tools.count) tools."
        } catch {
            self.error = "Couldn’t connect to the MCP server. \(error.localizedDescription)"
        }
    }

    func removeMCPServer(_ server: MCPServer) {
        Keychain.set(nil, for: server.id.uuidString)
        mcpServers.removeAll { $0.id == server.id }
        activeConnectors.remove(server.connectorID)
    }

    // MARK: Voice mode

    /// A reply from the selected local model, for voice mode when Apple Intelligence is off.
    func localReply(_ messages: [ChatMessage], system: String, update: @escaping @Sendable (String) async -> Void) async throws -> String {
        guard download.isReady else { throw IslandError.message("Download a model first, or turn on Apple Intelligence.") }
        guard !isBusy else { throw IslandError.message("Loocal is already answering in the chat.") }
        var system = system
        let question = messages.last(where: { $0.role == .user })?.text ?? ""
        if (activeConnectors.contains(Connector.web.id) && WebSearch.wantsSearch(question)) || WebSearch.explicitlyAsked(question) {
            let query = WebSearch.searchQuery(from: question)
            system += "\n\n" + (await Self.call(WebSearch.definition, arguments: WebSearch.arguments(for: query))).output + "\nAnswer in a few spoken sentences."
        }
        let result = try await engine.respond(model: model, directory: try download.loadingDirectory(), system: system, messages: messages, imagesDirectory: files.images, update: { text, _ in await update(text) }, phase: { _ in })
        return result.text
    }

    /// Voice turns are kept in the current chat, like typed ones.
    func recordVoiceTurn(user: String, reply: String) {
        guard !isBusy, !isDemo, let index = conversations.firstIndex(where: { $0.id == selectedID }) else { return }
        conversations[index].messages.append(ChatMessage(role: .user, text: user))
        conversations[index].messages.append(ChatMessage(role: .assistant, text: reply))
        save()
    }

    func endVoice() {
        if !isBusy { Task { await engine.unload() } }
        Task { await KokoroEngine.shared.unload() }
    }

    func savePersona(_ persona: Persona) {
        if let index = personas.firstIndex(where: { $0.id == persona.id }) { personas[index] = persona }
        else if personas.count < Persona.limit { personas.append(persona) }
    }

    func deletePersona(_ persona: Persona) {
        personas.removeAll { $0.id == persona.id }
        if personaID == persona.id { personaID = nil }
    }

    func delete(_ conversation: Conversation) {
        guard !(isBusy && conversation.id == selectedID) else { return }
        for name in conversation.messages.compactMap(\.imageName) {
            try? FileManager.default.removeItem(at: files.images.appendingPathComponent(name))
        }
        conversations.removeAll { $0.id == conversation.id }
        if conversations.isEmpty { conversations = [Conversation()] }
        if !conversations.contains(where: { $0.id == selectedID }) { selectedID = conversations[0].id }
        save()
    }

    func send() {
        guard canSend, let index = conversations.firstIndex(where: { $0.id == selectedID }) else { return }
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard prompt.count <= 6000 else { error = "Shorten your prompt to 6,000 characters or fewer for the phone context."; return }
        let fallback = attachedFiles.isEmpty ? "Describe this image." : "Summarize the attached file."
        let context = attachedFiles.isEmpty ? nil : attachedFiles.map { "Attached file “\($0.name)”:\n\($0.text)" }.joined(separator: "\n\n")
        let message = ChatMessage(role: .user, text: prompt.isEmpty ? fallback : prompt, imageName: attachmentName,
                                  files: attachedFiles.isEmpty ? nil : attachedFiles.map(\.name), context: context)
        attachedFiles = []
        conversations[index].messages.append(message)
        draft = ""
        attachmentName = nil
        beginReply(in: index)
    }

    /// Answer the conversation's last message (a new prompt, or a regenerated one).
    private func beginReply(in index: Int) {
        let history = conversations[index].messages
        let replyID = UUID()
        conversations[index].messages.append(ChatMessage(id: replyID, role: .assistant, text: "", status: .generating))
        tokens = 0
        phase = "Requesting background access"
        performance = ""
        isBusy = true
        stopReason = nil
        error = nil
        save()
        let conversationID = selectedID
        let model = model, system = systemPrompt
        let directory: URL
        do { directory = try download.loadingDirectory() } catch {
            conversations[index].messages.removeLast()
            isBusy = false
            self.error = "The model files couldn’t be prepared: \(error.localizedDescription)"
            return
        }
        activity.modelName = model.name
        continued.modelName = model.name
        notice = nil
        continued.begin(onLaunch: { [weak self] in
            self?.run(model: model, directory: directory, system: system, history: history, conversationID: conversationID, replyID: replyID)
        }, onExpire: { [weak self] in
            self?.stop(reason: "iOS ended the background task. Your partial reply is saved.")
        })
    }

    private func run(model: ModelChoice, directory: URL, system: String, history: [ChatMessage], conversationID: UUID, replyID: UUID) {
        // Continued processing already supplies a system Live Activity. Use the custom
        // Dynamic Island activity only for foreground fallback, avoiding duplicate loaders.
        if !continued.hasGrant { activity.start() }
        let question = history.last(where: { $0.role == .user })?.text ?? ""
        // Asking for a search in so many words turns it on for this reply.
        let active = WebSearch.explicitlyAsked(question) ? activeConnectors.union([Connector.web.id]) : activeConnectors
        let tools = toolDefinitions(for: active)
        generation = Task {
            do {
                // Built-in connectors are read right before the reply and join the system prompt.
                var system = system
                let read = Connector.builtIn.filter { active.contains($0.id) && $0.id != Connector.web.id }
                if !read.isEmpty {
                    await setPhase("Checking your sources")
                    let boxes = read.map(\.use)
                    for box in boxes { addTool(box, conversationID, replyID) }
                    let context = await ConnectorHub.context(for: active, prompt: question)
                    for box in boxes { finishTool(box.id, conversationID, replyID, failed: box.kind == Connector.wikipedia.id && !context.contains("Wikipedia —")) }
                    if !context.isEmpty { system += "\n\n" + context }
                }
                if active.contains(Connector.web.id) {
                    system += "\n\n" + WebSearch.guidance
                    if WebSearch.wantsSearch(question) {
                        await setPhase("Searching the web")
                        let query = WebSearch.searchQuery(from: question)
                        system += "\n\n" + (await useTool(WebSearch.definition, arguments: WebSearch.arguments(for: query), conversationID: conversationID, replyID: replyID))
                    }
                }
                let result = try await engine.respond(model: model, directory: directory, system: system, messages: history, imagesDirectory: files.images, tools: tools, callTool: { definition, arguments in
                    await self.useTool(definition, arguments: arguments, conversationID: conversationID, replyID: replyID)
                }, update: { text, count in
                    await self.received(text, count: count, conversationID: conversationID, replyID: replyID)
                }, phase: { phase in await self.setPhase(phase) })
                try Task.checkCancellation()
                performance = "\(result.tokens) tokens · \(String(format: "%.1f", Double(result.tokens) / max(result.seconds, 0.001))) tok/s · \(result.headroom) MB free"
                markReply(conversationID, replyID, status: .complete)
                phase = "Complete"
                continued.finish(success: true)
                activity.finish(phase: "Reply ready", count: tokens)
            } catch {
                markReply(conversationID, replyID, status: .interrupted)
                phase = "Stopped"
                if Task.isCancelled { notice = stopReason ?? "Generation stopped. Your partial reply is saved." }
                else if case IslandError.lowMemory = error { notice = error.localizedDescription }
                else { self.error = error.localizedDescription }
                continued.finish(success: false)
                activity.finish(phase: "Stopped", count: tokens)
            }
            isBusy = false
            generation = nil
            save()
            endGrace()
            // Releasing the model after every job leaves memory available to other apps,
            // unless an errand has been waiting for it.
            if desk.runs.contains(where: { $0.status == .queued }) { pumpErrands() } else { await engine.unload() }
        }
    }

    private func received(_ text: String, count: Int, conversationID: UUID, replyID: UUID) async {
        if let ci = conversations.firstIndex(where: { $0.id == conversationID }), let mi = conversations[ci].messages.firstIndex(where: { $0.id == replyID }) {
            conversations[ci].messages[mi].text = text
        }
        tokens = count
        continued.update(phase: ComputeTarget.useCPU ? "Writing in background" : "Generating", count: count)
        await activity.update(phase: "Generating", count: count)
        if Date().timeIntervalSince(lastSaved) > 1 { save(); lastSaved = .now }
    }

    private func setPhase(_ value: String) async {
        phase = value
        continued.update(phase: value, count: tokens)
        await activity.update(phase: value, count: tokens, force: true)
    }

    private func markReply(_ conversationID: UUID, _ replyID: UUID, status: ChatMessage.Status) {
        guard let ci = conversations.firstIndex(where: { $0.id == conversationID }), let mi = conversations[ci].messages.firstIndex(where: { $0.id == replyID }) else { return }
        conversations[ci].messages[mi].status = status
        // A reply that stops mid-tool leaves no box spinning.
        if status != .generating, let tools = conversations[ci].messages[mi].tools {
            conversations[ci].messages[mi].tools = tools.map { var use = $0; if use.status == .running { use.status = .failed }; return use }
        }
    }

    // MARK: Tools

    /// The tools a reply can call: web search when it's on, plus each active MCP server's.
    func toolDefinitions(for active: Set<String>) -> [ToolDefinition] {
        (active.contains(Connector.web.id) ? [WebSearch.definition] : []) + mcpServers.filter { active.contains($0.connectorID) }.flatMap { server in
            server.tools.prefix(8).map { ToolDefinition(url: server.url, token: Keychain.get(server.id.uuidString), tool: $0) }
        }
    }

    /// Runs a tool for the model: web search on device, anything else on its MCP server.
    nonisolated static func call(_ definition: ToolDefinition, arguments: String) async -> (output: String, links: [ToolUse.Link]) {
        if WebSearch.isLocal(definition) {
            let query = WebSearch.query(from: arguments)
            let hits = await WebSearch.search(query)
            return (WebSearch.report(hits, for: query), hits.prefix(5).map { ToolUse.Link(title: $0.title, url: $0.url) })
        }
        do { return (try await MCPClient(url: definition.url, token: definition.token).run(definition.tool.name, argumentsJSON: arguments), []) }
        catch { return ("The tool could not be reached: \(error.localizedDescription)", []) }
    }

    /// Calls a tool and keeps its box in the reply up to date.
    private func useTool(_ definition: ToolDefinition, arguments: String, conversationID: UUID, replyID: UUID) async -> String {
        let local = WebSearch.isLocal(definition)
        let host = definition.url.host() ?? "server"
        var box = local
            ? ToolUse(kind: Connector.web.id, icon: "magnifyingglass", running: "Searching the web", done: "Searched the web", detail: WebSearch.query(from: arguments))
            : ToolUse(kind: "mcp", icon: "server.rack", running: "Using \(definition.tool.name)", done: "Used \(definition.tool.name)", detail: host)
        addTool(box, conversationID, replyID)
        let result = await Self.call(definition, arguments: arguments)
        box.links = result.links
        let failed = result.output.hasPrefix("The tool could not") || result.output.hasPrefix("Tool error") || (local && result.links.isEmpty)
        finishTool(box.id, conversationID, replyID, failed: failed, links: result.links)
        return result.output
    }

    private func addTool(_ use: ToolUse, _ conversationID: UUID, _ replyID: UUID) {
        guard let ci = conversations.firstIndex(where: { $0.id == conversationID }), let mi = conversations[ci].messages.firstIndex(where: { $0.id == replyID }) else { return }
        conversations[ci].messages[mi].tools = (conversations[ci].messages[mi].tools ?? []) + [use]
    }

    private func finishTool(_ id: UUID, _ conversationID: UUID, _ replyID: UUID, failed: Bool = false, links: [ToolUse.Link] = []) {
        guard let ci = conversations.firstIndex(where: { $0.id == conversationID }), let mi = conversations[ci].messages.firstIndex(where: { $0.id == replyID }),
              let ti = conversations[ci].messages[mi].tools?.firstIndex(where: { $0.id == id }) else { return }
        conversations[ci].messages[mi].tools?[ti].status = failed ? .failed : .done
        if !links.isEmpty { conversations[ci].messages[mi].tools?[ti].links = links }
    }

    // MARK: Errands

    /// How many errands can be on the go at once.
    static let crewSize = 4
    /// Each errand gathers its sources (calendar, reminders, the web) as soon as it's sent,
    /// all at once; only the writing waits its turn for the model.
    @ObservationIgnored private var errandContexts: [UUID: Task<String, Never>] = [:]

    /// Send an errand off. It joins the crew right away and runs as soon as the model is free.
    func runErrand(title: String, instructions: String, sources: [String], errandID: UUID? = nil) {
        guard desk.active.count < Self.crewSize else {
            error = "The crew’s full: \(Self.crewSize) errands are on the go. Try again when one finishes."
            return
        }
        guard download.isReady || isDemo else { error = "Download \(model.name) first. Errands run on this iPhone."; return }
        var run = ErrandRun(errandID: errandID, title: title, instructions: instructions, sources: sources)
        run.personaID = errandPersona?.id
        run.stage = sources.allSatisfy({ $0 == Connector.web.id }) ? ErrandRun.nextUp : "Gathering"
        if let errandID { desk.markRan(errandID) }
        desk.start(run)
        prepare(run)
        pumpErrands()
    }

    /// The persona errands currently go out as (nil if none, or it was deleted).
    var errandPersona: Persona? { personas.first { $0.id == desk.personaID } }

    func rerun(_ run: ErrandRun) {
        runErrand(title: run.title, instructions: run.instructions, sources: run.sources)
    }

    /// Stop one errand: a waiting one just leaves the crew, the writing one stops mid-way.
    func cancelErrand(_ run: ErrandRun) {
        guard let current = desk.runs.first(where: { $0.id == run.id }), current.isActive else { return }
        if current.status == .running {
            stop(reason: "Errand stopped. Its partial result is saved.")
        } else {
            errandContexts.removeValue(forKey: run.id)?.cancel()
            desk.finish(run.id, status: .stopped)
        }
    }

    /// Fetches what an errand reads, in parallel with every other errand on the go.
    private func prepare(_ run: ErrandRun) {
        let active = Set(run.sources).subtracting([Connector.web.id]) // the web is searched while writing
        let names = connectors.filter { active.contains($0.id) }.map(\.name)
        let demo = isDemo
        errandContexts[run.id] = Task { [weak self] in
            guard let self, !active.isEmpty else { return "" }
            self.desk.setStage(run.id, "Reading " + ListFormatter.localizedString(byJoining: names))
            var context = ""
            if demo {
                try? await Task.sleep(for: .seconds(Double.random(in: 0.8...2.2)))
            } else {
                context = await ConnectorHub.context(for: active, prompt: run.instructions)
            }
            if self.desk.runs.first(where: { $0.id == run.id })?.status == .queued { self.desk.setStage(run.id, ErrandRun.nextUp) }
            return context
        }
    }

    /// Hands the model to the oldest waiting errand whenever it's free.
    func pumpErrands() {
        guard !isBusy, let run = desk.runs.last(where: { $0.status == .queued }) else { return }
        #if DEBUG && targetEnvironment(simulator)
        if isDemo { demoErrand(run); return }
        #endif
        guard download.isReady else { return }
        let directory: URL
        do { directory = try download.loadingDirectory() } catch {
            desk.finish(run.id, status: .failed, note: "The model files couldn’t be prepared: \(error.localizedDescription)")
            return
        }
        desk.begin(run.id)
        tokens = 0
        phase = "Starting errand"
        isBusy = true
        stopReason = nil
        let model = model
        activity.modelName = model.name
        continued.modelName = model.name
        continued.begin(onLaunch: { [weak self] in
            self?.performErrand(run, model: model, directory: directory)
        }, onExpire: { [weak self] in
            self?.stop(reason: "iOS ended the background task. The errand’s partial result is saved.")
        })
    }

    /// Runs every routine whose time has come. Called on launch, on return to the app (a
    /// tapped notification lands here) and periodically while Loocal is open.
    func runDueErrands() {
        guard download.isReady, !isDemo else { return }
        let due = desk.errands.filter(\.isDue).sorted { ($0.lastRun ?? $0.createdAt) < ($1.lastRun ?? $1.createdAt) }
        for errand in due where desk.active.count < Self.crewSize && !desk.active.contains(where: { $0.errandID == errand.id }) {
            runErrand(title: errand.title, instructions: errand.instructions, sources: errand.sources, errandID: errand.id)
        }
    }

    /// Open an errand's result as a regular chat, to keep going from it.
    func continueInChat(_ run: ErrandRun) {
        guard !isBusy else { return }
        newConversation()
        guard let index = conversations.firstIndex(where: { $0.id == selectedID }) else { return }
        conversations[index].messages = [ChatMessage(role: .user, text: run.instructions), ChatMessage(role: .assistant, text: run.text)]
        save()
    }

    private func performErrand(_ run: ErrandRun, model: ModelChoice, directory: URL) {
        if !continued.hasGrant { activity.start() }
        let tools = toolDefinitions(for: Set(run.sources))
        let gathered = errandContexts[run.id]
        generation = Task {
            do {
                // A persona's voice and know-how come first; the errand rules still apply.
                let persona = personas.first { $0.id == run.personaID }?.prompt.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                var system = (persona.isEmpty ? "" : persona + "\n\n") + ErrandDesk.systemPrompt + "\n\nIt is now " + Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()) + "."
                if let gathered {
                    desk.setStage(run.id, "Finishing reading")
                    let context = await gathered.value
                    if !context.isEmpty { system += "\n\n" + context }
                }
                if run.sources.contains(Connector.web.id) {
                    system += "\n\n" + WebSearch.guidance
                    if WebSearch.wantsSearch(run.instructions) {
                        desk.setStage(run.id, "Searching the web")
                        let query = WebSearch.searchQuery(from: run.instructions)
                        system += "\n\n" + (await Self.call(WebSearch.definition, arguments: WebSearch.arguments(for: query))).output
                    }
                }
                desk.setStage(run.id, "Thinking")
                _ = try await engine.respond(model: model, directory: directory, system: system, messages: [ChatMessage(role: .user, text: run.instructions)], imagesDirectory: files.images, tools: tools, callTool: { definition, arguments in
                    await Self.call(definition, arguments: arguments).output
                }, update: { text, count in
                    await self.errandReceived(text, count: count, runID: run.id)
                }, phase: { phase in
                    await self.setPhase(phase)
                    await MainActor.run { self.desk.setStage(run.id, phase == "Generating" ? "Writing" : phase) }
                })
                try Task.checkCancellation()
                desk.finish(run.id, status: .done)
                phase = "Complete"
                continued.finish(success: true)
                activity.finish(phase: "Errand done", count: tokens)
                if UIApplication.shared.applicationState != .active, let done = desk.runs.first(where: { $0.id == run.id }) { ErrandDesk.announce(done) }
            } catch {
                let cancelled = Task.isCancelled
                desk.finish(run.id, status: cancelled ? .stopped : .failed, note: cancelled ? nil : error.localizedDescription)
                phase = "Stopped"
                if cancelled { notice = stopReason ?? "Errand stopped. Its partial result is saved." }
                else if case IslandError.lowMemory = error { notice = error.localizedDescription }
                continued.finish(success: false)
                activity.finish(phase: "Stopped", count: tokens)
            }
            errandContexts[run.id] = nil
            isBusy = false
            generation = nil
            endGrace()
            // Keep the model loaded if another errand is waiting for it.
            if !desk.runs.contains(where: { $0.status == .queued }) { await engine.unload() }
            pumpErrands()
        }
    }

    private func errandReceived(_ text: String, count: Int, runID: UUID) async {
        desk.update(runID, text: text, tokens: count)
        tokens = count
        continued.update(phase: ComputeTarget.useCPU ? "Writing in background" : "Generating", count: count)
        await activity.update(phase: "Generating", count: count)
    }

    func stop(reason: String = "Generation stopped. Your partial reply is saved.") {
        guard isBusy else { return }
        stopReason = reason
        phase = "Stopping"
        if let generation { generation.cancel() }
        else {
            continued.finish(success: false)
            activity.finish(phase: "Stopped", count: tokens)
            if let index = conversations.firstIndex(where: { $0.id == selectedID }), let mi = conversations[index].messages.lastIndex(where: { $0.status == .generating }) { conversations[index].messages[mi].status = .interrupted }
            desk.interruptRunning()
            isBusy = false
            notice = reason
            save()
            pumpErrands()
        }
    }

    /// Leaving the app no longer stops a reply. Without background GPU, generation pauses at
    /// the next token as the app starts to leave, then moves to the CPU once it is really in
    /// the background (slower, but allowed), and back to the GPU on return.
    func willResignActive() {
        if isBusy {
            if !(continued.hasGrant && continued.grantedGPU) { ComputeTarget.mode = .leaving }
            if !continued.hasGrant && graceTask == .invalid {
                // No continued-processing grant: borrow UIKit's short background window.
                graceTask = UIApplication.shared.beginBackgroundTask(withName: "Loocal reply") { [weak self] in
                    self?.stop(reason: "iOS paused Loocal in the background. Your partial reply is saved.")
                    self?.endGrace()
                }
            }
        }
        save()
    }

    func didEnterBackground() {
        if !(continued.hasGrant && continued.grantedGPU) { ComputeTarget.mode = .background }
        save()
    }

    func didBecomeActive() {
        ComputeTarget.mode = .foreground
        activity.dismissFinished()
        endGrace()
        runDueErrands()
    }

    private func endGrace() {
        guard graceTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(graceTask)
        graceTask = .invalid
    }


    /// iOS sends memory warnings long before an app with a multi-gigabyte model is in real
    /// danger, so a reply keeps going; the engine watches actual headroom and stops itself
    /// cleanly if it gets genuinely low. When idle, the model is released.
    func memoryWarning() {
        if !isBusy { Task { await engine.unload() } }
    }

    func discardAttachment() {
        if let name = attachmentName { try? FileManager.default.removeItem(at: files.images.appendingPathComponent(name)) }
        attachmentName = nil
    }

    func attachPhoto(_ data: Data) async {
        guard model.vision else { error = "\(model.name) reads words only. Pick a vision model to share photos."; return }
        let conversationID = selectedID
        do {
            let result = try await Task.detached(priority: .userInitiated) { () throws -> Data in
                guard let source = CGImageSourceCreateWithData(data as CFData, nil), let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1024, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary), let jpeg = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.85) else { throw IslandError.message("That photo couldn’t be opened. Try another image.") }
                return jpeg
            }.value
            guard selectedID == conversationID, !isBusy else { return }
            // Temporary chats keep photos in their own folder, wiped when the chat ends and at launch.
            let name = (isTemporary ? LocalFiles.temporaryImages + "/" : "") + UUID().uuidString + ".jpg"
            if isTemporary { try FileManager.default.createDirectory(at: files.images.appendingPathComponent(LocalFiles.temporaryImages), withIntermediateDirectories: true) }
            try result.write(to: files.images.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            discardAttachment()
            attachmentName = name
        } catch { self.error = error.localizedDescription }
    }

    func save() {
        guard !isDemo else { return }
        let kept = conversations.filter { !$0.isTemporary }
        let selected = kept.contains { $0.id == selectedID } ? selectedID : (kept.first?.id ?? selectedID)
        do { try files.save(ChatArchive(conversations: kept.isEmpty ? [Conversation()] : kept, selectedID: selected)) }
        catch { self.error = "Couldn’t save your chat: \(error.localizedDescription)" }
    }
}

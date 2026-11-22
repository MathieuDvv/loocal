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
    /// Every background download session, for routing iOS completion events.
    var allDownloads: [ModelDownload] { Array(downloads.values) + [neuralVoices.engine] }
    var selectedModelID: String { didSet { UserDefaults.standard.set(selectedModelID, forKey: "model") } }
    var personas: [Persona] { didSet { Persona.save(personas) } }
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
        var downloads: [String: ModelDownload] = [:]
        for choice in ModelChoice.all {
            let directory = choice.folder.map { files.models.appendingPathComponent($0, isDirectory: true) } ?? files.models
            downloads[choice.id] = ModelDownload(spec: try .bundled(choice.manifest), directory: directory, sessionID: choice.sessionID, chunked: choice.parallelDownload)
        }
        self.downloads = downloads
        neuralVoices = NeuralVoiceStore(models: files.models)
        VoiceLibrary.preload()
        selectedModelID = ModelChoice.with(id: UserDefaults.standard.string(forKey: "model") ?? "").id
        personas = Persona.load()
        personaID = UserDefaults.standard.string(forKey: "persona").flatMap(UUID.init(uuidString:))
        activeConnectors = Set(UserDefaults.standard.stringArray(forKey: "connectors.active") ?? [])
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
            Conversation(createdAt: .now.addingTimeInterval(-3_600), messages: [ChatMessage(role: .user, text: "Explain what’s happening in this photo."), ChatMessage(role: .assistant, text: "A heron standing in shallow water at dusk, mid-strike.")]),
            Conversation(createdAt: .now.addingTimeInterval(-day), messages: [ChatMessage(role: .user, text: "Draft a short, warm note to my landlord"), ChatMessage(role: .assistant, text: "Hi Sam — thanks for sorting the boiler so quickly.")]),
            Conversation(createdAt: .now.addingTimeInterval(-4 * day), messages: [ChatMessage(role: .user, text: "Help me think through an idea: a tiny weekly newsletter"), ChatMessage(role: .assistant, text: "Begin with who it’s for, then the one thing they’d miss.")]),
            Conversation(createdAt: .now.addingTimeInterval(-20 * day), messages: [ChatMessage(role: .user, text: "Compare two ways to brew cold coffee"), ChatMessage(role: .assistant, text: "Immersion is forgiving; drip is brighter.")]),
        ]
        selectedID = thinking.id
        phase = "Loading model"
        isDemo = true
        streamDemo(conversationID: thinking.id, replyID: thinking.messages[3].id)
        if personas.isEmpty {
            personas = [
                Persona(name: "Editor", icon: "pencil.line", prompt: "You are a sharp, kind editor. Tighten prose, keep the author's voice, and explain each change in one line."),
                Persona(name: "Coach", icon: "flame", prompt: "You are a direct coach. Ask one clarifying question, then give a concrete next step."),
            ]
        }
    }

    /// Loops a fake streamed reply so the handwriting effect can be seen without a model.
    private func streamDemo(conversationID: UUID, replyID: UUID) {
        let reply = "Then nothing is lost. Pick it back up with **tonight’s two lines**: no catching up, no apology.\n\nThe habit is the return, not the streak."
        Task { @MainActor [weak self] in
            while let self {
                self.setDemoReply(conversationID, replyID, text: "", status: .generating)
                self.phase = "Thinking"
                try? await Task.sleep(for: .seconds(1.6))
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

    private func setDemoReply(_ conversationID: UUID, _ replyID: UUID, text: String, status: ChatMessage.Status) {
        guard let ci = conversations.firstIndex(where: { $0.id == conversationID }), let mi = conversations[ci].messages.firstIndex(where: { $0.id == replyID }) else { return }
        conversations[ci].messages[mi].text = text
        conversations[ci].messages[mi].status = status
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
        let active = activeConnectors
        let question = history.last(where: { $0.role == .user })?.text ?? ""
        let tools = mcpServers.filter { active.contains($0.connectorID) }.flatMap { server in
            server.tools.prefix(8).map { ToolDefinition(url: server.url, token: Keychain.get(server.id.uuidString), tool: $0) }
        }
        generation = Task {
            do {
                // Built-in connectors are read right before the reply and join the system prompt.
                var system = system
                if !active.isEmpty {
                    await setPhase("Checking your sources")
                    let context = await ConnectorHub.context(for: active, prompt: question)
                    if !context.isEmpty { system += "\n\n" + context }
                }
                let result = try await engine.respond(model: model, directory: directory, system: system, messages: history, imagesDirectory: files.images, tools: tools, callTool: { definition, arguments in
                    try await MCPClient(url: definition.url, token: definition.token).run(definition.tool.name, argumentsJSON: arguments)
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
            // Releasing the model after every job leaves memory available to other apps.
            await engine.unload()
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
            isBusy = false
            notice = reason
            save()
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

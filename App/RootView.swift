import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum AppTab: Hashable, CaseIterable {
    case history, chat, settings

    var label: String { switch self { case .history: "History"; case .chat: "New chat"; case .settings: "Settings" } }
    var symbol: String { switch self { case .history: "clock"; case .chat: "bubble"; case .settings: "gearshape" } }
    var order: Int { switch self { case .history: 0; case .chat: 1; case .settings: 2 } }
}

struct RootView: View {
    @Bindable var store: AppState
    @State private var tab: AppTab = .chat
    @State private var previous: AppTab = .chat
    @State private var keyboardVisible = false
    @State private var addingPersona = false
    @AppStorage("appearance") private var appearance: Appearance = .system

    var body: some View {
        ZStack {
            switch tab {
            case .history: HistoryView(store: store, open: { store.select($0); go(.chat) }).transition(slide)
            case .chat: ChatView(store: store, openSettings: { go(.settings) }, openPersonas: { addingPersona = true; go(.settings) }).transition(slide)
            case .settings: SettingsView(store: store, appearance: $appearance, addingPersona: $addingPersona).transition(slide)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.paper.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !keyboardVisible {
                DestinationBar(selection: tab, choose: choose)
                    .padding(.top, 6)
                    .padding(.bottom, -12) // Sit low, like Soma: tucked toward the home indicator.
                    .frame(maxWidth: .infinity)
                    .background {
                        // Only Settings scrolls under the bar, so only it gets a fade. Chat's composer
                        // and History's search field sit directly above the bar and must stay untouched.
                        VStack(spacing: 0) {
                            if tab == .settings {
                                LinearGradient(colors: [Ink.paper.opacity(0), Ink.paper], startPoint: .top, endPoint: .bottom).frame(height: 18)
                            }
                            Ink.paper
                        }
                        .padding(.top, tab == .settings ? -18 : 0)
                        .ignoresSafeArea(edges: .bottom)
                        .allowsHitTesting(false)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: keyboardVisible)
        .tint(Ink.primary)
        .preferredColorScheme(appearance.scheme)
        .animation(.smooth(duration: 0.35), value: appearance)
        .onOpenURL { _ in go(.chat) }
        #if DEBUG && targetEnvironment(simulator)
        .onAppear { if ProcessInfo.processInfo.arguments.contains("-uiDemo") { store.loadDemo() } }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in store.willResignActive() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in store.didEnterBackground() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in store.didBecomeActive() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in store.memoryWarning() }
        // Errors and interruptions drop in from the top instead of blocking the screen.
        .overlay(alignment: .top) { Toast(store: store) }
    }

    /// Pages drift in from the side of the tab you tapped, with a soft blur.
    private var slide: AnyTransition {
        let forward = tab.order >= previous.order
        return .asymmetric(
            insertion: .offset(x: forward ? 28 : -28).combined(with: .opacity),
            removal: .offset(x: forward ? -28 : 28).combined(with: .opacity)
        )
    }

    private func go(_ destination: AppTab) {
        previous = tab
        withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) { tab = destination }
    }

    private func choose(_ destination: AppTab) {
        // The middle destination starts a fresh chat when you're already looking at one.
        if destination == .chat && tab == .chat && !store.current.messages.isEmpty {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) { store.newConversation() }
            return
        }
        go(destination)
    }
}

/// Soma-style destination bar: three label-free icons in a 300 pt row, the selected one
/// sitting on a soft pill. No container chrome.
struct DestinationBar: View {
    let selection: AppTab
    let choose: (AppTab) -> Void
    @Namespace private var pill

    var body: some View {
        HStack {
            ForEach(AppTab.allCases, id: \.self) { item in
                let selected = item == selection
                Button { choose(item) } label: {
                    Image(systemName: item.symbol)
                        .font(.system(size: 19, weight: .regular))
                        .foregroundStyle(selected ? Ink.primary : Ink.tertiary)
                        .symbolEffect(.bounce.down, options: .speed(1.4), value: selected)
                        .frame(width: 72, height: 42)
                        .background {
                            if selected { Capsule().fill(Ink.fill).matchedGeometryEffect(id: "pill", in: pill) }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(PressStyle(scale: 0.9))
                .accessibilityLabel(item.label)
                .accessibilityIdentifier("tab-" + String(describing: item))
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                if item != AppTab.allCases.last { Spacer(minLength: 0) }
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: selection)
        .frame(maxWidth: 300).frame(height: 54)
        .padding(.horizontal, 24)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

// MARK: - Chat

struct ChatView: View {
    @Bindable var store: AppState
    let openSettings: () -> Void
    var openPersonas: () -> Void = {}
    @State private var photo: PhotosPickerItem?
    @State private var isPreparingPhoto = false
    @FocusState private var composerFocused: Bool
    @State private var viewport: CGFloat = 600
    @Namespace private var voiceSource
    @State private var conversationOpen = false
    @State private var attachOpen = false
    @State private var photosOpen = false
    @State private var filesOpen = false
    @State private var cameraOpen = false
    @State private var personaOpen = false
    @State private var serverPrompt = false
    @State private var serverName = ""
    @State private var serverToken = ""
    @State private var selecting: ChatMessage?

    var body: some View {
        VStack(spacing: 0) {
            ModelSelector(options: ModelChoice.all, disabled: store.isBusy, selection: $store.selectedModelID, dimmed: !store.download.isReady)
                .frame(maxWidth: .infinity)
                .padding(.top, 6).padding(.bottom, 8)
                .overlay(alignment: .bottom) {
                    if store.isTemporary && !store.current.messages.isEmpty {
                        HStack(spacing: 5) {
                            LoopMark(color: Ink.secondary, dashed: true).frame(width: 16)
                            Text("Temporary").font(.geist(12, .medium))
                        }
                        .foregroundStyle(Ink.secondary)
                        .offset(y: 16)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: store.isTemporary && !store.current.messages.isEmpty)
                .dismissesKeyboardOnTap()
                .zIndex(1)
            ZStack {
                if store.current.messages.isEmpty {
                    EmptyChatView(temporary: store.isTemporary, toggleTemporary: store.toggleTemporary)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    transcript.id(store.selectedID)
                        .transition(.opacity.combined(with: .offset(y: 12)))
                }
            }
            .frame(maxHeight: .infinity)
            .dismissesKeyboardOnTap() // everywhere above the composer
            .simultaneousGesture(TapGesture().onEnded { closeAttach() })
            .animation(.spring(response: 0.45, dampingFraction: 0.9), value: store.current.messages.isEmpty)
            .animation(.spring(response: 0.45, dampingFraction: 0.9), value: store.selectedID)
            if store.current.messages.isEmpty && store.download.isReady && store.draft.isEmpty {
                suggestions.transition(.move(edge: .bottom).combined(with: .opacity))
            }
            composer
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: store.draft.isEmpty)
        .background(Ink.paper)
        // Only one tray at a time: opening + closes the persona capsule and vice versa.
        .onChange(of: attachOpen) { _, open in if open { composerFocused = false; withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { personaOpen = false } } }
        .onChange(of: personaOpen) { _, open in if open { composerFocused = false; closeAttach() } }
        .onChange(of: store.selectedModelID) { _, _ in
            if !store.model.vision { withAnimation(.smooth) { store.discardAttachment() } }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            withAnimation(.smooth) { isPreparingPhoto = true }
            Task {
                do {
                    if let data = try await item.loadTransferable(type: Data.self) { await store.attachPhoto(data) }
                } catch { store.error = "The photo couldn’t be imported: \(error.localizedDescription)" }
                photo = nil
                withAnimation(.smooth) { isPreparingPhoto = false }
            }
        }
        .photosPicker(isPresented: $photosOpen, selection: $photo, matching: .images, photoLibrary: .shared())
        .fileImporter(isPresented: $filesOpen, allowedContentTypes: [.text, .pdf, .json, .commaSeparatedText, .sourceCode, .xml, .html], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { urls.forEach(store.attachFile) } }
        }
        .fullScreenCover(isPresented: $cameraOpen) {
            CameraPicker { data in Task { await store.attachPhoto(data) } }.ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $conversationOpen) {
            ConversationView(source: Self.demoMode ? ConversationMock() : VoiceConversation(store: store))
                .navigationTransition(.zoom(sourceID: "voice", in: voiceSource))
        }
        .sheet(item: $selecting) { message in
            SelectTextSheet(text: MessageView.rendered(message.text))
        }
        .alert("Add MCP server", isPresented: $serverPrompt) {
            TextField("https://server.example/mcp", text: $serverName)
                .textInputAutocapitalization(.never).keyboardType(.URL)
            SecureField("Token (optional)", text: $serverToken)
            Button("Connect") {
                let address = serverName, token = serverToken
                serverName = ""; serverToken = ""
                Task { await store.addMCPServer(address, token: token) }
            }
            Button("Cancel", role: .cancel) { serverName = ""; serverToken = "" }
        } message: { Text("Loocal connects over HTTPS and lets the model call this server’s tools. Its token stays in the Keychain.") }
    }

    /// The scripted voice mock is used only in the simulator demo.
    private static var demoMode: Bool {
        #if DEBUG && targetEnvironment(simulator)
        return ProcessInfo.processInfo.arguments.contains("-uiDemo")
        #else
        return false
        #endif
    }

    private var chips: [AttachmentChip] {
        store.attachedFiles.map { AttachmentChip(id: $0.id.uuidString, icon: "doc", title: $0.name) }
            + store.connectors.filter { store.activeConnectors.contains($0.id) }.map { AttachmentChip(id: $0.id, icon: $0.icon, title: $0.name) }
    }

    private func closeAttach() {
        guard attachOpen else { return }
        composerFocused = false
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { attachOpen = false }
    }

    private func handle(_ action: AttachAction) {
        if case .toggle(let connector) = action {
            Task { await store.toggleConnector(connector) }
            return
        }
        closeAttach()
        DispatchQueue.main.async {
            switch action {
            case .photos: photosOpen = true
            case .files: filesOpen = true
            case .camera:
                if UIImagePickerController.isSourceTypeAvailable(.camera) { cameraOpen = true }
                else { store.error = "This device has no camera available." }
            case .addServer: serverPrompt = true
            case .toggle: break
            }
        }
    }

    /// The latest turn (your last message and its reply) is given at least a screen of
    /// height. Sending scrolls your message to the top once, then the reply writes downward
    /// into the space below it, so nothing already on screen moves while it streams.
    private var transcript: some View {
        let messages = store.current.messages
        let split = messages.lastIndex(where: { $0.role == .user }) ?? messages.count
        return ScrollViewReader { proxy in
            ScrollView {
                // Non-lazy: lazy stacks estimate row heights and visibly correct them while scrolling.
                VStack(alignment: .leading, spacing: 26) {
                    ForEach(Array(messages[..<split])) { message in row(message) }
                    VStack(alignment: .leading, spacing: 26) {
                        ForEach(Array(messages[split...])) { message in row(message) }
                        if !store.isBusy && !store.performance.isEmpty {
                            Text(store.performance).font(.geist(11).monospacedDigit()).foregroundStyle(Ink.tertiary)
                                .transition(.opacity)
                        }
                    }
                    .frame(minHeight: max(0, viewport - 32), alignment: .top)
                    .id("turn")
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
                .animation(.spring(response: 0.45, dampingFraction: 0.82), value: messages.count)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewport = $0 }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages.count) { old, new in
                guard new > old, messages.last(where: { $0.role == .user }) != nil else { return }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) { proxy.scrollTo("turn", anchor: .top) }
            }
        }
    }

    private func row(_ message: ChatMessage) -> some View {
        MessageView(message: message, imageDirectory: store.files.images, phase: store.phase)
            // Padding just for the long-press preview, so its rounded edge never crops text.
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(.contextMenuPreview, .rect(cornerRadius: 22))
            .contextMenu { menu(for: message) }
            .padding(.horizontal, -12).padding(.vertical, -8)
            .transition(.asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: message.role == .user ? .bottomTrailing : .bottomLeading)),
                removal: .opacity))
    }

    /// Long-press actions on a prompt or a reply.
    @ViewBuilder private func menu(for message: ChatMessage) -> some View {
        // No menu while a reply is still being written.
        if message.status != .generating { menuItems(for: message) }
    }

    @ViewBuilder private func menuItems(for message: ChatMessage) -> some View {
        let plain = String(MessageView.rendered(message.text).characters)
        Button("Copy", systemImage: "doc.on.doc") {
            // This device only: copied text never syncs to your other devices via Universal Clipboard.
            UIPasteboard.general.setItems([["public.utf8-plain-text": plain]], options: [.localOnly: true])
        }
        if message.role == .user {
            Button("Edit", systemImage: "pencil") {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { store.edit(message) }
                composerFocused = true
            }
            .disabled(store.isBusy)
        } else if !message.text.isEmpty {
            Button("Read Aloud", systemImage: "speaker.wave.2") { Speaker.shared.say(plain) }
            ShareLink(item: plain) { Label("Share", systemImage: "square.and.arrow.up") }
            if store.canRegenerate(message) {
                Button("Regenerate", systemImage: "arrow.clockwise") { store.regenerate() }
            }
        }
        Button("Select Text", systemImage: "character.cursor.ibeam") { selecting = message }
    }

    private var suggestions: some View {
        SuggestionRow { store.draft = $0; composerFocused = true }
    }

    /// Without a downloaded model, the prompt box itself becomes the download box.
    private var composer: some View {
        ZStack {
            if store.composerReady {
                input.transition(.blurReplace.combined(with: .scale(0.98)))
            } else {
                DownloadComposer(download: store.download, model: store.model)
                    .transition(.blurReplace.combined(with: .scale(0.98)))
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: store.composerReady)
        .padding(6)
        .background(Ink.fill, in: .rect(cornerRadius: 25))
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let name = store.attachmentName, let image = UIImage(contentsOfFile: store.files.images.appendingPathComponent(name).path) {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: 64, height: 64).clipShape(.rect(cornerRadius: 14))
                    Button { withAnimation(.spring(response: 0.3)) { store.discardAttachment() } } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Ink.paper)
                            .frame(width: 20, height: 20).background(Ink.primary, in: .circle)
                    }
                    .buttonStyle(PressStyle(scale: 0.85))
                    .offset(x: 6, y: -6).accessibilityLabel("Remove photo")
                }
                .padding(.leading, 6).padding(.top, 6)
                .transition(.scale(scale: 0.6, anchor: .bottomLeading).combined(with: .opacity))
            }
            if !chips.isEmpty {
                ChipRow(chips: chips) { chip in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        store.attachedFiles.removeAll { $0.id.uuidString == chip.id }
                        store.activeConnectors.remove(chip.id)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if isPreparingPhoto {
                HStack(spacing: 8) { SpiralLoader(size: 14, color: Ink.secondary); Text("Preparing photo") }
                    .font(.geist(13)).foregroundStyle(Ink.secondary).padding(.leading, 8)
                    .transition(.opacity)
            }
            HStack(alignment: .bottom, spacing: 6) {
                HStack(spacing: 0) {
                    AttachControl(open: $attachOpen, connectors: store.connectors, active: store.activeConnectors, vision: store.model.vision, act: handle)
                        .disabled(store.isBusy || isPreparingPhoto)
                        .zIndex(1) // the tray unrolls over its neighbours
                }
                .zIndex(1)
                TextField(store.persona.map { "Ask \($0.name)" } ?? "Ask anything", text: $store.draft, axis: .vertical)
                    .font(.geist(16)).foregroundStyle(Ink.primary)
                    .lineLimit(1...6).padding(.vertical, 9)
                    .focused($composerFocused).disabled(store.isBusy)
                    // The text field is a UIKit view and wins taps over SwiftUI drawn above it,
                    // so it steps aside while a tray covers it.
                    .allowsHitTesting(!attachOpen && !personaOpen)
                    .opacity(attachOpen || personaOpen ? 0 : 1)
                    .animation(.easeOut(duration: 0.15), value: attachOpen || personaOpen)
                    .accessibilityIdentifier("prompt")
                Button { composerFocused = false; closeAttach(); conversationOpen = true } label: {
                    AudioLinesIcon(size: 19)
                        .foregroundStyle(Ink.primary)
                        .frame(width: 30, height: 38)
                        .contentShape(.rect)
                }
                .buttonStyle(PressStyle(scale: 0.85))
                .matchedTransitionSource(id: "voice", in: voiceSource)
                .accessibilityLabel("Conversation mode")
                .accessibilityIdentifier("conversation")
                .disabled(store.isBusy)
                .opacity(personaOpen ? 0 : 1)
                .animation(.easeOut(duration: 0.15), value: personaOpen)
                ZStack {
                    if store.isBusy {
                        Button { store.stop() } label: {
                            RoundedRectangle(cornerRadius: 2.5).fill(Ink.paper).frame(width: 11, height: 11)
                                .frame(width: 38, height: 38).background(Ink.primary, in: .circle)
                        }
                        .buttonStyle(PressStyle(scale: 0.88))
                        .accessibilityLabel("Stop generation")
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                    } else {
                        SendControl(store: store, open: $personaOpen, canSend: store.canSend && !isPreparingPhoto, send: { composerFocused = false; store.send() }, addPersona: openPersonas)
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: store.isBusy)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: chips)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: store.attachedFiles)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: store.canSend)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: store.attachmentName)
    }
}

private struct SuggestionRow: View {
    let choose: (String) -> Void
    @State private var appeared = false

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(EmptyChatView.prompts.enumerated()), id: \.element.title) { i, prompt in
                    Button { choose(prompt.text) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(prompt.title).font(.geist(14, .medium)).foregroundStyle(Ink.primary)
                            Text(prompt.detail).font(.geist(13)).foregroundStyle(Ink.secondary)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 11)
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Ink.hairline))
                        .contentShape(.rect(cornerRadius: 16))
                    }
                    .buttonStyle(PressStyle())
                    .rise(appeared, delay: 0.15 + Double(i) * 0.07, distance: 10)
                }
            }.padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, 10)
        .onAppear { appeared = true }
    }
}

struct EmptyChatView: View {
    let temporary: Bool
    var toggleTemporary: () -> Void = {}
    @State private var appeared = false
    @State private var flips = 0

    struct Prompt { let title: String; let detail: String; let text: String }
    static let prompts = [
        Prompt(title: "Think out loud", detail: "with an idea I’m stuck on", text: "Help me think through an idea: "),
        Prompt(title: "Explain a photo", detail: "and what’s happening in it", text: "Explain what’s happening in this photo."),
        Prompt(title: "Draft a note", detail: "short, warm, to the point", text: "Draft a short, warm note to "),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            VStack(spacing: 18) {
                // The logo is the switch: solid loop for a normal chat, dashed for temporary.
                Button {
                    flips += 1
                    withAnimation(.spring(response: 0.55, dampingFraction: 0.72)) { toggleTemporary() }
                } label: {
                    LoopMark(color: Ink.primary, dashed: temporary)
                        .frame(width: 46)
                        .padding(14)
                        .contentShape(.rect)
                        .rotation3DEffect(.degrees(Double(flips) * 180), axis: (x: 0, y: 1, z: 0))
                }
                .buttonStyle(PressStyle(scale: 0.85))
                .accessibilityLabel(temporary ? "Temporary chat. Tap for a normal chat" : "Start a temporary chat")
                .accessibilityIdentifier("temporaryToggle")
                .sensoryFeedback(.impact(weight: .medium), trigger: flips)
                .rise(appeared, delay: 0)
                ZStack {
                    if temporary {
                        VStack(spacing: 10) {
                            Text("Off the \(Text("record.").font(.serif(40, italic: true)))")
                                .font(.serif(40)).tracking(-0.4)
                            Text("Temporary chat · nothing is saved")
                                .font(.geist(14)).foregroundStyle(Ink.secondary)
                        }
                        .transition(.blurReplace.combined(with: .scale(0.96)))
                    } else {
                        Text("What’s on \(Text("your mind?").font(.serif(40, italic: true)))")
                            .font(.serif(40)).tracking(-0.4)
                            .transition(.blurReplace.combined(with: .scale(0.96)))
                    }
                }
                .multilineTextAlignment(.center).foregroundStyle(Ink.primary)
                .rise(appeared, delay: 0.06)
            }
            .padding(.horizontal, 32)
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity)
        .onAppear { appeared = true }
    }
}

struct MessageView: View {
    let message: ChatMessage
    let imageDirectory: URL
    var phase = ""

    var body: some View {
        if message.role == .user { user } else { assistant }
    }

    private var user: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if let files = message.files, !files.isEmpty {
                HStack(spacing: 6) {
                    ForEach(files, id: \.self) { name in
                        HStack(spacing: 6) {
                            Image(systemName: "doc").font(.system(size: 12))
                            Text(name).font(.geist(13, .medium)).lineLimit(1)
                        }
                        .foregroundStyle(Ink.primary)
                        .padding(.horizontal, 10).frame(height: 30)
                        .overlay(Capsule().stroke(Ink.hairline))
                    }
                }
            }
            if let image { image.resizable().scaledToFit().frame(maxWidth: 220, maxHeight: 260).clipShape(.rect(cornerRadius: 18)).accessibilityLabel("Attached photo") }
            Text(message.text)
                .font(.geist(16)).foregroundStyle(Ink.primary).lineSpacing(3)
                .padding(.horizontal, 16).padding(.vertical, 11)
                .background(Ink.fill, in: .rect(cornerRadius: 22))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
    }

    private var assistant: some View {
        VStack(alignment: .leading, spacing: 12) {
            // "Thinking" stays until the first whole word is ready, so the row never hops.
            if shown.isEmpty && message.status == .generating {
                HStack(spacing: 10) {
                    SpiralLoader(size: 18)
                    Text(phase.isEmpty || phase == "Generating" ? "Thinking" : phase)
                        .font(.geist(15)).foregroundStyle(Ink.secondary)
                        .contentTransition(.opacity)
                        .animation(.smooth, value: phase)
                }
                .padding(.top, 2)
                .transition(.opacity)
            } else if !shown.isEmpty {
                HandwrittenText(text: Self.rendered(shown), live: message.status == .generating)
                    .font(.geist(16)).foregroundStyle(Ink.primary).lineSpacing(5)
                    .transition(.opacity)
                if message.status == .generating { SpiralLoader(size: 14, color: Ink.secondary).transition(.opacity) }
            }
            if message.status == .interrupted {
                Text("Stopped · partial reply saved").font(.geist(12)).foregroundStyle(Ink.tertiary)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.smooth(duration: 0.3), value: shown.isEmpty)
        .animation(.smooth(duration: 0.3), value: message.status)
    }

    private var shown: String { StreamingText.stable(message.text, live: message.status == .generating) }

    private var image: Image? {
        guard let name = message.imageName, let ui = UIImage(contentsOfFile: imageDirectory.appendingPathComponent(name).path) else { return nil }
        return Image(uiImage: ui)
    }

    /// Light inline Markdown (bold, italics, code, links); falls back to plain text.
    static func rendered(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

// MARK: - History

struct HistoryView: View {
    let store: AppState
    let open: (Conversation) -> Void
    @State private var query = ""
    @State private var appeared = false

    private var matches: [Conversation] {
        let all = store.history
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { $0.messages.contains { $0.text.localizedCaseInsensitiveContains(q) } }
    }

    private var groups: [(String, [Conversation])] {
        let calendar = Calendar.current
        let buckets = Dictionary(grouping: matches) { c -> Int in
            if calendar.isDateInToday(c.createdAt) { return 0 }
            if calendar.isDateInYesterday(c.createdAt) { return 1 }
            if let days = calendar.dateComponents([.day], from: c.createdAt, to: .now).day, days < 7 { return 2 }
            return 3
        }
        let names = ["Today", "Yesterday", "Previous 7 days", "Earlier"]
        return buckets.keys.sorted().map { (names[$0], buckets[$0]!.sorted { $0.createdAt > $1.createdAt }) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.history.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    LoopMark(color: Ink.tertiary).frame(width: 40)
                    Text("Nothing here yet.").font(.serif(28, italic: true)).foregroundStyle(Ink.primary)
                    Text("Your conversations stay on this iPhone.").font(.geist(14)).foregroundStyle(Ink.secondary)
                }
                .rise(appeared, delay: 0.08)
                Spacer()
            } else {
                List {
                    ForEach(Array(groups.enumerated()), id: \.element.0) { g, group in
                        Section {
                            ForEach(Array(group.1.enumerated()), id: \.element.id) { i, conversation in
                                row(conversation).rise(appeared, delay: min(0.04 * Double(g * 2 + i), 0.3), distance: 8)
                            }
                        } header: {
                            Text(group.0).font(.geist(13, .medium)).foregroundStyle(Ink.secondary).textCase(nil)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.immediately)
                .contentMargins(.top, 8, for: .scrollContent)
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: matches.map(\.id))
                .dismissesKeyboardOnTap()
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(Ink.tertiary)
                TextField("Search chats", text: $query).font(.geist(15)).foregroundStyle(Ink.primary)
                if !query.isEmpty {
                    Button { withAnimation(.smooth) { query = "" } } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Ink.tertiary)
                    }
                    .buttonStyle(PressStyle(scale: 0.85))
                    .accessibilityLabel("Clear search")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 14).frame(height: 40)
            .background(Ink.fill, in: .capsule)
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 6)
            .animation(.spring(response: 0.3), value: query.isEmpty)
            .rise(appeared, delay: 0.1)
        }
        .background(Ink.paper)
        .onAppear { appeared = true }
    }

    private func row(_ conversation: Conversation) -> some View {
        Button { open(conversation) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(conversation.title).font(.geist(16)).foregroundStyle(Ink.primary).lineLimit(1)
                    Spacer(minLength: 12)
                    Text(conversation.createdAt, format: Calendar.current.isDateInToday(conversation.createdAt) ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day())
                        .font(.geist(12).monospacedDigit()).foregroundStyle(Ink.tertiary)
                }
                if let reply = conversation.messages.last(where: { $0.role == .assistant && !$0.text.isEmpty }) {
                    Text(String(MessageView.rendered(reply.text).characters)).font(.geist(14)).foregroundStyle(Ink.secondary).lineLimit(1)
                }
            }
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .listRowBackground(conversation.id == store.selectedID ? Ink.fill : Ink.paper)
        .listRowSeparatorTint(Ink.hairline)
        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
        .disabled(store.isBusy)
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive) { withAnimation(.smooth) { store.delete(conversation) } }
                .tint(.red) // the app-wide ink tint would otherwise turn it white on white
        }
    }
}

#Preview("New chat") { EmptyChatView(temporary: false) }
#Preview("Destination bar") { DestinationBar(selection: .chat, choose: { _ in }) }

/// A message opened for free text selection.
struct SelectTextSheet: View {
    let text: AttributedString
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Select text").font(.geist(15, .medium)).foregroundStyle(Ink.secondary)
                Spacer()
                Button("Done") { dismiss() }.font(.geist(15, .medium)).foregroundStyle(Ink.primary)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
            ScrollView {
                Text(text)
                    .font(.geist(17)).foregroundStyle(Ink.primary).lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.bottom, 24)
            }
        }
        .background(Ink.paper.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }
}

/// Top toast for errors (exclamation) and notices such as an interrupted reply. Swipe up
/// or tap to dismiss; it leaves on its own after a few seconds.
struct Toast: View {
    @Bindable var store: AppState
    @State private var drag: CGFloat = 0

    private var message: (text: String, isError: Bool)? {
        if let error = store.error { return (error, true) }
        if let notice = store.notice { return (notice, false) }
        return nil
    }

    var body: some View {
        ZStack {
            if let message {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: message.isError ? "exclamationmark.circle" : "pause.circle")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Ink.primary)
                    Text(message.text)
                        .font(.geist(14)).foregroundStyle(Ink.primary).lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16).padding(.vertical, 13)
                .background(RoundedRectangle(cornerRadius: 22).fill(Ink.paper).overlay(RoundedRectangle(cornerRadius: 22).stroke(Ink.hairline)).shadow(color: .black.opacity(0.12), radius: 18, y: 6))
                .padding(.horizontal, 14).padding(.top, 4)
                .offset(y: min(0, drag))
                .gesture(DragGesture().onChanged { drag = $0.translation.height }.onEnded { value in
                    if value.translation.height < -20 { dismiss() }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { drag = 0 }
                })
                .onTapGesture { dismiss() }
                .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: .top)))
                .id(message.text)
                .task(id: message.text) {
                    try? await Task.sleep(for: .seconds(message.isError ? 6 : 4))
                    if !Task.isCancelled { dismiss() }
                }
                .accessibilityAddTraits(.isStaticText)
                .accessibilityAction(named: "Dismiss") { dismiss() }
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: message?.text)
        .sensoryFeedback(.warning, trigger: store.error) { _, new in new != nil }
    }

    private func dismiss() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            if store.error != nil { store.error = nil } else { store.notice = nil }
        }
    }
}

/// The composer while the selected model isn't installed: one tap downloads it, then it
/// shows progress in place and turns back into the prompt box when ready.
struct DownloadComposer: View {
    @Bindable var download: ModelDownload
    let model: ModelChoice

    private var size: String { ByteCountFormatter.string(fromByteCount: download.spec.totalBytes, countStyle: .file) }

    var body: some View {
        Button { download.start() } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    ZStack {
                        if download.isDownloading {
                            SpiralLoader(size: 18, color: Ink.primary).transition(.scale.combined(with: .opacity))
                        } else {
                            Image(systemName: download.error == nil ? "arrow.down" : "arrow.clockwise")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Ink.paper)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .frame(width: 38, height: 38)
                    .background(download.isDownloading ? Ink.paper : Ink.primary, in: .circle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(download.isDownloading ? "Downloading \(model.name)" : download.error == nil ? "Download \(model.name)" : "Retry \(model.name)")
                            .font(.geist(15, .medium)).foregroundStyle(Ink.primary)
                            .contentTransition(.opacity)
                        Text(download.error ?? (download.isDownloading ? "You can leave the app meanwhile" : "\(size) · Wi-Fi · then fully offline"))
                            .font(.geist(13)).foregroundStyle(Ink.secondary).lineLimit(2)
                            .contentTransition(.opacity)
                    }
                    Spacer(minLength: 8)
                    if download.isDownloading {
                        Text(download.progress, format: .percent.precision(.fractionLength(0)))
                            .font(.geist(14, .medium).monospacedDigit()).foregroundStyle(Ink.primary)
                            .contentTransition(.numericText(value: download.progress))
                            .padding(.trailing, 8)
                            .transition(.opacity)
                    }
                }
                if download.isDownloading {
                    GeometryReader { proxy in
                        Capsule().fill(Ink.hairline).overlay(alignment: .leading) {
                            Capsule().fill(Ink.primary).frame(width: max(4, proxy.size.width * download.progress))
                        }
                    }
                    .frame(height: 3)
                    .padding(.horizontal, 6).padding(.bottom, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .disabled(download.isDownloading)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: download.isDownloading)
        .animation(.smooth(duration: 0.6), value: download.progress)
        .animation(.smooth, value: download.error)
        .accessibilityIdentifier("composerDownload")
    }
}

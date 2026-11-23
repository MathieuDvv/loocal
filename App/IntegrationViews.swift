import SwiftUI

// MARK: - Logos

/// An integration's app icon, drawn rather than shipped: its colours, a squircle, and a mark
/// that reads as the app at 28 pt in the tray and at 76 pt on its own page.
struct IntegrationLogo: View {
    let integration: Integration
    var size: CGFloat = 44

    private var corner: CGFloat { size * 0.235 }

    var body: some View {
        ZStack {
            LinearGradient(colors: background.map { Color(uiColor: UIColor(rgb: $0)) }, startPoint: .top, endPoint: .bottom)
            mark
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(.black.opacity(light ? 0.09 : 0), lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    private var light: Bool { [.gallery, .health, .googleHealth, .notion].contains(integration.tint) }

    private var background: [UInt32] {
        switch integration.tint {
        case .claude: [0xDE8566, 0xC96442]
        case .github: [0x2D333B, 0x0D1117]
        case .chatgpt: [0x1F1F1F, 0x000000]
        default: integration.tint.stops
        }
    }

    @ViewBuilder private var mark: some View {
        let s = size
        switch integration.tint {
        case .messages: symbol("message.fill", 0.54)
        case .mail: symbol("envelope.fill", 0.46)
        case .contacts: symbol("person.fill", 0.5).offset(y: s * 0.04)
        case .appStore:
            // The pencil-and-brush "A": two legs and a crossbar.
            ZStack {
                Capsule().frame(width: s * 0.09, height: s * 0.56).rotationEffect(.degrees(-28)).offset(x: s * 0.12)
                Capsule().frame(width: s * 0.09, height: s * 0.56).rotationEffect(.degrees(28)).offset(x: -s * 0.12)
                Capsule().frame(width: s * 0.5, height: s * 0.09).offset(y: s * 0.1)
            }
            .foregroundStyle(.white)
        case .chatgpt:
            ZStack {
                ForEach(0..<6) { i in
                    RoundedRectangle(cornerRadius: s * 0.1, style: .continuous)
                        .stroke(.white, lineWidth: s * 0.055)
                        .frame(width: s * 0.2, height: s * 0.36)
                        .offset(y: -s * 0.11)
                        .rotationEffect(.degrees(Double(i) * 60))
                }
            }
        case .claude:
            ZStack {
                ForEach(0..<12) { i in
                    Capsule().fill(Color(uiColor: UIColor(rgb: 0xFAF0E6)))
                        .frame(width: s * 0.07, height: s * (i % 2 == 0 ? 0.3 : 0.22))
                        .offset(y: -s * (i % 2 == 0 ? 0.15 : 0.11))
                        .rotationEffect(.degrees(Double(i) * 30 + (i % 3 == 0 ? 4 : -3)))
                }
            }
        case .gallery:
            ZStack {
                ForEach(Array([0xFDB827, 0xF68B1F, 0xEF4136, 0xD6246E, 0x9B4F96, 0x3F51B5, 0x1EA1DC, 0x7BC043].enumerated()), id: \.offset) { i, color in
                    Capsule().fill(Color(uiColor: UIColor(rgb: UInt32(color))).opacity(0.85))
                        .frame(width: s * 0.2, height: s * 0.34)
                        .offset(y: -s * 0.14)
                        .rotationEffect(.degrees(Double(i) * 45))
                        .blendMode(.multiply)
                }
            }
        case .github:
            // A cat's head, ears up.
            ZStack {
                Circle().frame(width: s * 0.44, height: s * 0.4).offset(y: s * 0.03)
                Triangle().frame(width: s * 0.16, height: s * 0.2).rotationEffect(.degrees(-14)).offset(x: -s * 0.14, y: -s * 0.15)
                Triangle().frame(width: s * 0.16, height: s * 0.2).rotationEffect(.degrees(14)).offset(x: s * 0.14, y: -s * 0.15)
                Capsule().frame(width: s * 0.06, height: s * 0.16).offset(y: s * 0.26)
            }
            .foregroundStyle(.white)
        case .health:
            Image(systemName: "heart.fill").font(.system(size: s * 0.36))
                .foregroundStyle(LinearGradient(colors: [Color(uiColor: UIColor(rgb: 0xFF6B8A)), Color(uiColor: UIColor(rgb: 0xFF2D55))], startPoint: .top, endPoint: .bottom))
                .offset(x: s * 0.16, y: -s * 0.16)
        case .googleHealth:
            Image(systemName: "heart.fill").font(.system(size: s * 0.5))
                .foregroundStyle(AngularGradient(colors: [0x4285F4, 0x34A853, 0xFBBC05, 0xEA4335, 0x4285F4].map { Color(uiColor: UIColor(rgb: $0)) }, center: .center))
        case .notion:
            Text("N").font(.serif(s * 0.6)).foregroundStyle(Color(uiColor: UIColor(rgb: 0x191919)))
                .frame(width: s * 0.6, height: s * 0.6)
                .overlay(RoundedRectangle(cornerRadius: s * 0.08).stroke(Color(uiColor: UIColor(rgb: 0x191919)), lineWidth: s * 0.045))
        default: symbol(integration.glyph, 0.5)
        }
    }

    private func symbol(_ name: String, _ scale: CGFloat) -> some View {
        Image(systemName: name).font(.system(size: size * scale, weight: .medium)).foregroundStyle(.white)
    }
}

private struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.closeSubpath() }
    }
}

/// The tray's door to integrations: four tiny app tiles in a square, the connected ones'
/// colours when there are any.
struct IntegrationsGlyph: View {
    let integrations: [Integration]
    var lit = false
    var size: CGFloat = 18

    var body: some View {
        let picks = Array((integrations.isEmpty ? [Integration.github, .claude, .messages, .health] : integrations).prefix(4))
        let tile = size * 0.44
        Grid(horizontalSpacing: size * 0.12, verticalSpacing: size * 0.12) {
            GridRow { cell(picks, 0, tile); cell(picks, 1, tile) }
            GridRow { cell(picks, 2, tile); cell(picks, 3, tile) }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder private func cell(_ picks: [Integration], _ i: Int, _ tile: CGFloat) -> some View {
        let color: Color = i < picks.count ? Color(uiColor: UIColor(rgb: picks[i].tint.stops.last!)) : Ink.tertiary
        RoundedRectangle(cornerRadius: tile * 0.3, style: .continuous)
            .fill(lit ? Ink.paper : color)
            .overlay(RoundedRectangle(cornerRadius: tile * 0.3, style: .continuous).strokeBorder(lit ? .clear : Ink.hairline, lineWidth: 0.5))
            .frame(width: tile, height: tile)
    }
}

// MARK: - Now and then: "you have GitHub"

/// Proposed above the prompt on a new chat, at most every day and a half: an app on this
/// iPhone that isn't connected yet. Its logo tumbles in; "Not now" quiets it for a month.
struct IntegrationSuggestion: View {
    let integration: Integration
    let connect: () -> Void
    let dismiss: () -> Void
    @State private var landed = false

    var body: some View {
        HStack(spacing: 12) {
            IntegrationLogo(integration: integration, size: 38)
                .shadow(color: Color(uiColor: integration.tint.ui).opacity(0.35), radius: landed ? 8 : 0, y: landed ? 4 : 0)
                .rotationEffect(.degrees(landed ? 0 : -18))
                .scaleEffect(landed ? 1 : 0.5)
                .offset(y: landed ? 0 : 10)
            VStack(alignment: .leading, spacing: 2) {
                Text("Add \(integration.name) to Loocal").font(.geist(14, .medium)).foregroundStyle(Ink.primary).lineLimit(1)
                Text("It’s on your iPhone · \(integration.tagline.lowercased())").font(.geist(13)).foregroundStyle(Ink.secondary).lineLimit(1)
            }
            .opacity(landed ? 1 : 0)
            .offset(x: landed ? 0 : -8)
            Spacer(minLength: 4)
            Button(action: connect) {
                Text("Connect").font(.geist(13, .medium)).foregroundStyle(Ink.paper)
                    .padding(.horizontal, 13).frame(height: 30)
                    .background(Ink.primary, in: .capsule)
            }
            .buttonStyle(PressStyle(scale: 0.92))
            .accessibilityIdentifier("integration.suggestion.connect")
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Ink.tertiary)
                    .frame(width: 26, height: 30).contentShape(.rect)
            }
            .buttonStyle(PressStyle(scale: 0.85))
            .accessibilityLabel("Not now")
        }
        .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 9)
        .background(Ink.paper, in: .rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Ink.hairline))
        .shadow(color: .black.opacity(0.05), radius: 12, y: 4)
        .padding(.horizontal, 16).padding(.bottom, 10)
        .onAppear { withAnimation(.spring(response: 0.55, dampingFraction: 0.62).delay(0.15)) { landed = true } }
        .sensoryFeedback(.impact(weight: .light), trigger: landed)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Settings › Integrations

struct IntegrationsPage: View {
    @Bindable var store: AppState
    @State private var opened: Integration?
    @State private var addingServer = false
    @State private var serverAddress = ""
    @State private var serverToken = ""
    @State private var appeared = false

    private var center: IntegrationCenter { store.integrations }
    private var onPhone: [Integration] { Integration.all.filter { center.detected.contains($0.id) && !center.isInstalled($0) } }
    private var more: [Integration] { Integration.all.filter { !center.detected.contains($0.id) && !center.isInstalled($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            hero
            if !center.connected.isEmpty {
                SectionLabel(text: "Connected").padding(.top, 6)
                VStack(spacing: 0) {
                    ForEach(Array(center.connected.enumerated()), id: \.element.id) { i, integration in
                        connectedRow(integration)
                        if i < center.connected.count - 1 { Rectangle().fill(Ink.hairline).frame(height: 1).padding(.leading, 66) }
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(Ink.hairline))
            }
            if !onPhone.isEmpty {
                SectionLabel(text: "On this iPhone").padding(.top, 10)
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(Array(onPhone.enumerated()), id: \.element.id) { i, integration in
                            Button { opened = integration } label: { card(integration) }
                                .buttonStyle(PressStyle(scale: 0.96))
                                .rise(appeared, delay: 0.08 + Double(i) * 0.04, distance: 8)
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
                .padding(.horizontal, -20)
            }
            if !more.isEmpty {
                SectionLabel(text: "More").padding(.top, 10)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 14) {
                    ForEach(more) { integration in
                        Button { opened = integration } label: {
                            VStack(spacing: 7) {
                                IntegrationLogo(integration: integration, size: 52)
                                    .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
                                Text(integration.name).font(.geist(12)).foregroundStyle(Ink.secondary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PressStyle(scale: 0.92))
                    }
                }
            }
            SectionLabel(text: "Custom servers").padding(.top, 10)
            servers
            Text("Connected integrations sit in the + tray. Pick one to place it in your message; Loocal reads it just before answering, for that message only.")
                .font(.geist(13)).foregroundStyle(Ink.tertiary).padding(.horizontal, 4).padding(.top, 4)
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: center.installed)
        .onAppear { appeared = true; center.scan(demo: RootDemo.on) }
        .sheet(item: $opened) { integration in
            IntegrationSheet(store: store, integration: integration)
                .presentationDetents([integration.key == .none ? .fraction(0.68) : .large])
                .presentationCornerRadius(34)
        }
        .alert("Add MCP server", isPresented: $addingServer) {
            TextField("https://server.example/mcp", text: $serverAddress).textInputAutocapitalization(.never).keyboardType(.URL)
            SecureField("Token (optional)", text: $serverToken)
            Button("Connect") {
                let address = serverAddress, token = serverToken
                serverAddress = ""; serverToken = ""
                Task { await store.addMCPServer(address, token: token) }
            }
            Button("Cancel", role: .cancel) { serverAddress = ""; serverToken = "" }
        } message: { Text("Loocal connects over HTTPS and lets the model call this server’s tools. Its token stays in the Keychain.") }
    }

    /// The connected logos fanned like a hand of cards; a dashed slot when there are none.
    private var hero: some View {
        let fan = Array(center.connected.prefix(5))
        return ZStack {
            if fan.isEmpty {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Ink.hairline, style: StrokeStyle(lineWidth: 1.2, dash: [4, 4]))
                    .frame(width: 64, height: 64)
                    .overlay { Image(systemName: "plus").font(.system(size: 18)).foregroundStyle(Ink.tertiary) }
            }
            ForEach(Array(fan.enumerated()), id: \.element.id) { i, integration in
                let mid = Double(fan.count - 1) / 2
                IntegrationLogo(integration: integration, size: 64)
                    .shadow(color: .black.opacity(0.14), radius: 10, y: 5)
                    .rotationEffect(.degrees(appeared ? (Double(i) - mid) * 9 : 0), anchor: .bottom)
                    .offset(x: appeared ? (CGFloat(i) - CGFloat(mid)) * 34 : 0, y: appeared ? abs(CGFloat(i) - CGFloat(mid)) * 6 : 12)
                    .zIndex(Double(i))
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity).frame(height: 104)
        .animation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.05), value: appeared)
    }

    private func connectedRow(_ integration: Integration) -> some View {
        Button { opened = integration } label: {
            HStack(spacing: 12) {
                IntegrationLogo(integration: integration, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(integration.name).font(.geist(15, .medium)).foregroundStyle(Ink.primary)
                    Text(center.needsKey(integration) ? "Needs a key" : integration.tagline).font(.geist(13))
                        .foregroundStyle(center.needsKey(integration) ? Color(uiColor: IslandTint.red.ui) : Ink.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.tertiary)
            }
            .padding(.horizontal, 13).padding(.vertical, 11)
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .transition(.opacity.combined(with: .move(edge: .top)))
        .accessibilityIdentifier("integration." + integration.id)
    }

    private func card(_ integration: Integration) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            IntegrationLogo(integration: integration, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(integration.name).font(.geist(14, .medium)).foregroundStyle(Ink.primary)
                Text(integration.tagline).font(.geist(12)).foregroundStyle(Ink.secondary).lineLimit(2).multilineTextAlignment(.leading)
            }
            Text("Connect").font(.geist(12, .medium)).foregroundStyle(Ink.paper)
                .padding(.horizontal, 11).frame(height: 26).background(Ink.primary, in: .capsule)
        }
        .padding(12)
        .frame(width: 148, height: 150, alignment: .topLeading)
        .background(Ink.fill.opacity(0.6), in: .rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Ink.hairline))
    }

    private var servers: some View {
        VStack(spacing: 0) {
            ForEach(store.mcpServers) { server in
                HStack(spacing: 12) {
                    Image(systemName: "server.rack").font(.system(size: 14)).foregroundStyle(Ink.primary)
                        .frame(width: 40, height: 40).background(Ink.fill, in: .rect(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.name).font(.geist(15, .medium)).foregroundStyle(Ink.primary)
                        Text("\(server.tools.count) tools · \(server.url.host() ?? "")").font(.geist(13)).foregroundStyle(Ink.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { store.removeMCPServer(server) } } label: {
                        Image(systemName: "minus.circle").font(.system(size: 17)).foregroundStyle(Ink.tertiary).frame(width: 36, height: 36)
                    }
                    .buttonStyle(PressStyle(scale: 0.85))
                    .accessibilityLabel("Remove \(server.name)")
                }
                .padding(.horizontal, 13).padding(.vertical, 10)
                Rectangle().fill(Ink.hairline).frame(height: 1).padding(.leading, 66)
            }
            Button { addingServer = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus").font(.system(size: 14)).frame(width: 40, height: 40)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Ink.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Add MCP server").font(.geist(15, .medium))
                        Text("Any tool server over HTTPS").font(.geist(13)).foregroundStyle(Ink.secondary)
                    }
                    Spacer()
                }
                .foregroundStyle(Ink.primary)
                .padding(.horizontal, 13).padding(.vertical, 10)
                .contentShape(.rect)
            }
            .buttonStyle(PressStyle(scale: 0.98))
            .accessibilityIdentifier("addMCPServer")
        }
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Ink.hairline))
    }
}

/// One integration: what it does, its key if it needs one, and Connect.
struct IntegrationSheet: View {
    @Bindable var store: AppState
    let integration: Integration
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var key = ""
    @State private var model = Assistants.openAIModel
    @State private var working = false
    @State private var problem: String?
    @State private var justConnected = false
    @State private var float = false

    private var center: IntegrationCenter { store.integrations }
    private var connected: Bool { center.isInstalled(integration) }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                ZStack(alignment: .bottomTrailing) {
                    IntegrationLogo(integration: integration, size: 84)
                        .shadow(color: Color(uiColor: integration.tint.ui).opacity(0.35), radius: 18, y: 10)
                        .offset(y: float ? -3 : 3)
                        .scaleEffect(justConnected ? 1.08 : 1)
                    if connected {
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Ink.paper)
                            .frame(width: 28, height: 28).background(Ink.primary, in: .circle)
                            .overlay(Circle().stroke(Ink.paper, lineWidth: 3))
                            .offset(x: 8, y: 6)
                            .transition(.scale(scale: 0.2).combined(with: .opacity))
                    }
                }
                .padding(.top, 34)
                VStack(spacing: 6) {
                    Text(integration.name).font(.serif(34)).tracking(-0.3).foregroundStyle(Ink.primary)
                    Text(integration.tagline).font(.geist(15)).foregroundStyle(Ink.secondary)
                }
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(integration.abilities, id: \.self) { ability in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Circle().fill(Color(uiColor: integration.tint.ui)).frame(width: 6, height: 6).offset(y: -2)
                            Text(ability).font(.geist(15)).foregroundStyle(Ink.primary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Ink.fill.opacity(0.6), in: .rect(cornerRadius: 20))
                if integration.key != .none { keyField }
                if integration.id == Integration.chatgpt.id {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel(text: "Model")
                        TextField("gpt-5-mini", text: $model)
                            .font(.geist(15)).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .padding(.horizontal, 14).frame(height: 46)
                            .background(Ink.fill, in: .rect(cornerRadius: 14))
                            .onSubmit { Assistants.openAIModel = model }
                    }
                }
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock").font(.system(size: 12)).foregroundStyle(Ink.tertiary).padding(.top, 2)
                    Text(integration.privacy).font(.geist(13)).foregroundStyle(Ink.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let problem {
                    Text(problem).font(.geist(13)).foregroundStyle(Color(uiColor: IslandTint.red.ui))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                action
            }
            .padding(.horizontal, 22).padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background(Ink.paper)
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: connected)
        .animation(.smooth, value: problem)
        .sensoryFeedback(.success, trigger: justConnected) { _, now in now }
        .onAppear {
            key = center.key(integration) ?? ""
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) { float = true }
        }
        .onDisappear { if integration.id == Integration.chatgpt.id { Assistants.openAIModel = model.isEmpty ? "gpt-5-mini" : model } }
    }

    private var keyField: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: integration.keyLabel + (integration.key == .optional ? " · optional" : ""))
            SecureField(integration.key == .optional ? "Paste to see your own" : "Paste it here", text: $key)
                .font(.geist(15)).textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(.horizontal, 14).frame(height: 46)
                .background(Ink.fill, in: .rect(cornerRadius: 14))
                .onSubmit { center.setKey(key, for: integration) }
                .accessibilityIdentifier("integration.key")
            HStack(spacing: 4) {
                Text(integration.keyHelp).font(.geist(12.5)).foregroundStyle(Ink.tertiary)
            }
            if let url = integration.keyURL {
                Button { openURL(url) } label: {
                    HStack(spacing: 4) {
                        Text("Get one").font(.geist(13, .medium))
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Ink.secondary)
                }
                .buttonStyle(PressStyle(scale: 0.96))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var action: some View {
        Button {
            if connected && key == (center.key(integration) ?? "") {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { center.disconnect(integration) }
                key = ""
                return
            }
            if integration.key != .none { center.setKey(key, for: integration) }
            working = true
            Task {
                problem = await center.connect(integration)
                working = false
                guard problem == nil else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.5)) { justConnected = true }
                try? await Task.sleep(for: .milliseconds(260))
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { justConnected = false }
                try? await Task.sleep(for: .milliseconds(650))
                dismiss()
            }
        } label: {
            ZStack {
                if working { SpiralLoader(size: 16, color: Ink.paper) }
                else {
                    Text(buttonTitle).font(.geist(16, .medium)).contentTransition(.opacity)
                }
            }
            .foregroundStyle(connected && !keyChanged ? Ink.primary : Ink.paper)
            .frame(maxWidth: .infinity).frame(height: 52)
            .background(connected && !keyChanged ? Ink.fill : Ink.primary, in: .capsule)
        }
        .buttonStyle(PressStyle(scale: 0.97))
        .disabled(working)
        .accessibilityIdentifier("integration.connect")
    }

    private var keyChanged: Bool { integration.key != .none && key != (center.key(integration) ?? "") }
    private var buttonTitle: String { connected ? (keyChanged ? "Save key" : "Disconnect") : "Connect \(integration.name)" }
}

/// The simulator review mode (-uiDemo): every catalog app counts as installed.
enum RootDemo {
    static var on: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("-uiDemo")
        #else
        false
        #endif
    }
}

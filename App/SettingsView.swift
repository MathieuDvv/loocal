import AVFoundation
import SwiftUI

struct SettingsView: View {
    @Bindable var store: AppState
    @Binding var appearance: Appearance
    @Binding var addingPersona: Bool
    @Namespace private var pill
    @State private var appeared = false
    @State private var editing: Persona?
    @State private var voicePage = false

    var body: some View {
        NavigationStack {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                section("Models", order: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(ModelChoice.all.enumerated()), id: \.element.id) { i, choice in
                            ModelRow(choice: choice, download: store.downloads[choice.id]!, selected: store.selectedModelID == choice.id) {
                                withAnimation(.snappy) { store.selectedModelID = choice.id }
                            }
                            if i < ModelChoice.all.count - 1 { Rectangle().fill(Ink.hairline).frame(height: 1).padding(.leading, 20) }
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(Ink.hairline))
                }

                section("Personas", order: 1) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(store.personas) { persona in
                            PersonaRow(persona: persona, active: store.personaID == persona.id) { editing = persona }
                                .transition(.scale(scale: 0.95).combined(with: .opacity))
                        }
                        if store.personas.count < Persona.limit {
                            Button { editing = Persona(name: "", icon: Persona.icons[store.personas.count % Persona.icons.count], prompt: "") } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "plus").font(.system(size: 15)).frame(width: 40, height: 40)
                                        .overlay(Circle().stroke(Ink.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                                    Text("New persona").font(.geist(15, .medium))
                                    Spacer()
                                    Text("\(store.personas.count) of \(Persona.limit)").font(.geist(13).monospacedDigit()).foregroundStyle(Ink.tertiary)
                                }
                                .foregroundStyle(Ink.primary)
                                .padding(12)
                                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Ink.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
                                .contentShape(.rect(cornerRadius: 20))
                            }
                            .buttonStyle(PressStyle(scale: 0.98))
                            .accessibilityIdentifier("newPersona")
                            .transition(.opacity)
                        }
                        Text("Hold the send button to switch personas.")
                            .font(.geist(13)).foregroundStyle(Ink.tertiary).padding(.leading, 4)
                    }
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: store.personas)
                }

                section("Voice", order: 2) {
                    Button { voicePage = true } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "waveform").font(.system(size: 15)).frame(width: 36, height: 36).background(Ink.fill, in: .circle)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(VoiceLibrary.summary(store.neuralVoices)).font(.geist(15, .medium)).foregroundStyle(Ink.primary)
                                    .contentTransition(.opacity)
                                Text("Conversation mode and Read Aloud").font(.geist(13)).foregroundStyle(Ink.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.tertiary)
                        }
                        .padding(12)
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Ink.hairline))
                        .contentShape(.rect(cornerRadius: 20))
                    }
                    .buttonStyle(PressStyle(scale: 0.98))
                    .accessibilityIdentifier("voiceRow")
                }

                section("Appearance", order: 3) {
                    HStack(spacing: 4) {
                        ForEach(Appearance.allCases) { option in
                            let selected = appearance == option
                            Button { withAnimation(.snappy(duration: 0.3)) { appearance = option } } label: {
                                Text(option.label)
                                    .font(.geist(14, .medium))
                                    .foregroundStyle(selected ? Ink.primary : Ink.tertiary)
                                    .frame(maxWidth: .infinity).frame(height: 38)
                                    .background {
                                        if selected {
                                            Capsule().fill(Ink.paper)
                                                .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
                                                .matchedGeometryEffect(id: "appearance", in: pill)
                                        }
                                    }
                                    .contentShape(.capsule)
                            }
                            .buttonStyle(PressStyle())
                            .accessibilityAddTraits(selected ? [.isSelected] : [])
                        }
                    }
                    .padding(4).background(Ink.fill, in: .capsule)
                    .sensoryFeedback(.selection, trigger: appearance)
                }
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(Ink.paper)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $voicePage) { VoiceSettingsView(store: store) }
        }
        .onAppear {
            appeared = true
            if addingPersona {
                addingPersona = false
                if store.personas.count < Persona.limit { editing = Persona(name: "", icon: Persona.icons[store.personas.count], prompt: "") }
            }
        }
        .sheet(item: $editing) { persona in
            PersonaEditor(persona: persona, isNew: !store.personas.contains { $0.id == persona.id }, save: { store.savePersona($0) }, delete: { store.deletePersona($0) })
        }
    }

    private func section<Content: View>(_ title: String, order: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: title)
            content()
        }
        .rise(appeared, delay: Double(order) * 0.06)
    }
}

// MARK: - Models

private struct ModelRow: View {
    let choice: ModelChoice
    @Bindable var download: ModelDownload
    let selected: Bool
    let select: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Button(action: select) {
                    HStack(spacing: 12) {
                        Circle()
                            .strokeBorder(selected ? Ink.primary : Ink.hairline, lineWidth: selected ? 5.5 : 1.5)
                            .frame(width: 18, height: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(choice.name).font(.geist(16, .medium)).foregroundStyle(Ink.primary)
                            Text("\(choice.detail) · \(ByteCountFormatter.string(fromByteCount: download.spec.totalBytes, countStyle: .file))")
                                .font(.geist(13)).foregroundStyle(Ink.secondary)
                        }
                        Spacer(minLength: 8)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(PressStyle(scale: 0.98))
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                trailing
            }
            if download.isDownloading {
                GeometryReader { proxy in
                    Capsule().fill(Ink.hairline).overlay(alignment: .leading) {
                        Capsule().fill(Ink.primary).frame(width: max(4, proxy.size.width * download.progress))
                    }
                }
                .frame(height: 3)
                .padding(.leading, 30)
                .animation(.smooth(duration: 0.6), value: download.progress)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let error = download.error {
                Text(error).font(.geist(13)).foregroundStyle(Ink.secondary).lineSpacing(2).padding(.leading, 30)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .animation(.smooth(duration: 0.35), value: download.isDownloading)
        .animation(.smooth(duration: 0.35), value: download.isReady)
        .animation(.smooth(duration: 0.35), value: download.error)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selected)
    }

    @ViewBuilder private var trailing: some View {
        Group {
            if download.isReady {
                Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.primary)
                    .frame(height: 32)
                    .accessibilityLabel("Installed")
            } else if download.isDownloading {
                HStack(spacing: 8) {
                    SpiralLoader(size: 14)
                    Text(download.progress, format: .percent.precision(.fractionLength(0)))
                        .font(.geist(13).monospacedDigit()).foregroundStyle(Ink.secondary)
                        .contentTransition(.numericText(value: download.progress))
                        .animation(.snappy, value: download.progress)
                }
                .frame(height: 32)
            } else {
                Button { download.start() } label: {
                    Text(download.error == nil ? "Get" : "Retry")
                        .font(.geist(14, .medium)).foregroundStyle(Ink.paper)
                        .padding(.horizontal, 16).frame(height: 32)
                        .background(Ink.primary, in: .capsule)
                }
                .buttonStyle(PressStyle(scale: 0.92))
                .accessibilityLabel("Download \(choice.name)")
                .accessibilityIdentifier(choice.id == ModelChoice.standard.id ? "downloadModel" : "download-\(choice.id)")
            }
        }
        .transition(.blurReplace)
    }
}

// MARK: - Personas

private struct PersonaRow: View {
    let persona: Persona
    let active: Bool
    let edit: () -> Void

    var body: some View {
        Button(action: edit) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: persona.icon).font(.system(size: 16))
                    .foregroundStyle(active ? Ink.paper : Ink.primary)
                    .frame(width: 40, height: 40)
                    .background(active ? Ink.primary : Ink.fill, in: .circle)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(persona.name.isEmpty ? "Untitled" : persona.name).font(.geist(15, .medium)).foregroundStyle(Ink.primary)
                        if active { Text("Active").font(.geist(11, .medium)).foregroundStyle(Ink.secondary).padding(.horizontal, 7).padding(.vertical, 2).overlay(Capsule().stroke(Ink.hairline)) }
                    }
                    Text(persona.prompt.isEmpty ? "No instructions yet" : persona.prompt)
                        .font(.geist(13)).foregroundStyle(Ink.secondary).lineLimit(2).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.tertiary).padding(.top, 13)
            }
            .padding(12)
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Ink.hairline))
            .contentShape(.rect(cornerRadius: 20))
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: active)
    }
}

struct PersonaEditor: View {
    @State var persona: Persona
    let isNew: Bool
    let save: (Persona) -> Void
    let delete: (Persona) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: Field?
    @Namespace private var iconPill
    private enum Field { case name, prompt }

    private var canSave: Bool { !persona.name.trimmingCharacters(in: .whitespaces).isEmpty && !persona.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }.font(.geist(15)).foregroundStyle(Ink.secondary)
                Spacer()
                Button {
                    persona.name = persona.name.trimmingCharacters(in: .whitespaces)
                    save(persona); dismiss()
                } label: {
                    Text("Save").font(.geist(15, .medium)).foregroundStyle(canSave ? Ink.paper : Ink.tertiary)
                        .padding(.horizontal, 16).frame(height: 34)
                        .background(canSave ? Ink.primary : Ink.hairline, in: .capsule)
                }
                .buttonStyle(PressStyle(scale: 0.92))
                .disabled(!canSave)
                .animation(.spring(response: 0.3), value: canSave)
                .accessibilityIdentifier("savePersona")
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    Image(systemName: persona.icon)
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Ink.paper)
                        .frame(width: 76, height: 76)
                        .background(Ink.primary, in: .circle)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(text: "Icon")
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8), spacing: 8) {
                            ForEach(Persona.icons, id: \.self) { icon in
                                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { persona.icon = icon } } label: {
                                    Image(systemName: icon).font(.system(size: 15))
                                        .foregroundStyle(persona.icon == icon ? Ink.paper : Ink.primary)
                                        .frame(width: 36, height: 36)
                                        .background {
                                            if persona.icon == icon { Circle().fill(Ink.primary).matchedGeometryEffect(id: "icon", in: iconPill) }
                                            else { Circle().fill(Ink.fill) }
                                        }
                                }
                                .buttonStyle(PressStyle(scale: 0.85))
                                .accessibilityLabel(icon)
                            }
                        }
                        .sensoryFeedback(.selection, trigger: persona.icon)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(text: "Name")
                        TextField("Editor, Coach, Friend…", text: $persona.name)
                            .font(.geist(16)).foregroundStyle(Ink.primary)
                            .focused($focus, equals: .name)
                            .padding(.horizontal, 16).frame(height: 48)
                            .background(Ink.fill, in: .rect(cornerRadius: 16))
                            .accessibilityIdentifier("personaName")
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(text: "Instructions")
                        TextField("How should the model behave? This becomes its system prompt.", text: $persona.prompt, axis: .vertical)
                            .font(.geist(16)).foregroundStyle(Ink.primary).lineSpacing(3)
                            .lineLimit(5...14)
                            .focused($focus, equals: .prompt)
                            .padding(16)
                            .background(Ink.fill, in: .rect(cornerRadius: 16))
                            .accessibilityIdentifier("personaPrompt")
                        Text("\(persona.prompt.count) / 2,000").font(.geist(12).monospacedDigit()).foregroundStyle(Ink.tertiary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }

                    if !isNew {
                        Button(role: .destructive) { delete(persona); dismiss() } label: {
                            Text("Delete persona").font(.geist(15, .medium)).foregroundStyle(Ink.secondary)
                                .frame(maxWidth: .infinity).frame(height: 48)
                                .overlay(Capsule().stroke(Ink.hairline))
                        }
                        .buttonStyle(PressStyle(scale: 0.97))
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Ink.paper.ignoresSafeArea())
        .onChange(of: persona.prompt) { _, value in if value.count > 2000 { persona.prompt = String(value.prefix(2000)) } }
        .onAppear { if isNew { focus = .name } }
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }
}

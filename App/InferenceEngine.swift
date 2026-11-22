import Foundation
import os
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM

/// Where token generation runs. iOS forbids GPU work from a backgrounded app unless the
/// device grants background GPU (iPhone Air doesn't). Switching device in the middle of a
/// reply used to leave GPU work in flight as the app left, which iOS kills the app for.
/// Now the app says when it is *leaving*: generation pauses at the next token, drains the
/// GPU, and waits. If the app really goes to the background, the reply is rebuilt on the
/// CPU from the prompt plus the words written so far; if the user comes straight back, it
/// simply carries on on the GPU.
enum ComputeTarget {
    enum Mode: Sendable { case foreground, leaving, background }
    private static let lock = OSAllocatedUnfairLock(initialState: Mode.foreground)
    static var mode: Mode {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
    static var useCPU: Bool { mode == .background }
    static var device: Device { useCPU ? .cpu : .gpu }
}

struct InferenceResult: Sendable {
    var text: String
    var tokens: Int
    var seconds: TimeInterval
    /// Lowest free memory seen during the reply, in megabytes.
    var headroom: Int
}

actor InferenceEngine {
    private var container: ModelContainer?
    private var loadedID: String?

    /// Used when no persona is chosen.
    static let defaultSystemPrompt = "You are a helpful assistant. Answer directly and accurately."

    func unload() {
        container = nil
        loadedID = nil
        #if !targetEnvironment(simulator)
        GPU.clearCache()
        #endif
    }

    /// Generate a reply. With MCP tools, the model may answer with a `<tool_call>`; the tool
    /// runs via `callTool`, its output is added to the chat and generation resumes (at most
    /// two tool rounds). Only text before a tool call is ever shown.
    func respond(model: ModelChoice, directory: URL, system: String, messages: [ChatMessage], imagesDirectory: URL,
                 tools: [ToolDefinition] = [],
                 callTool: @escaping @Sendable (ToolDefinition, String) async throws -> String = { _, _ in "" },
                 update: @escaping @Sendable (String, Int) async -> Void,
                 phase: @escaping @Sendable (String) async -> Void) async throws -> InferenceResult {
        #if targetEnvironment(simulator)
        throw IslandError.message("Model inference requires a physical iPhone or iPad. The simulator is for the interface and Live Activity only.")
        #else
        try Task.checkCancellation()
        if loadedID != model.id { unload() } // Only one model is ever resident.
        if container == nil {
            await phase("Loading model")
            GPU.set(cacheLimit: 64 * 1024 * 1024)
            let configuration = ModelConfiguration(directory: directory, extraEOSTokens: model.stopTokens)
            switch model.family {
            case .qwenVL:
                let registry = ModelTypeRegistry(creators: ["qwen3_vl": { url in
                    let data = try ModelCompatibility.qwenConfiguration(Data(contentsOf: url))
                    return Qwen3VL(try JSONDecoder().decode(Qwen3VLConfiguration.self, from: data))
                }])
                let factory = VLMModelFactory(typeRegistry: registry, processorRegistry: VLMProcessorTypeRegistry.shared, modelRegistry: VLMRegistry.shared)
                container = try await factory.loadContainer(configuration: configuration)
            case .gemmaText:
                container = try await LLMModelFactory.shared.loadContainer(configuration: configuration)
            }
            loadedID = model.id
        }
        guard let container else { throw IslandError.message("The model could not load.") }
        try Task.checkCancellation()
        await phase("Reading prompt")
        // Qwen's chat template takes tool specs natively; Gemma gets them described in text.
        let specs: [[String: any Sendable]]? = tools.isEmpty || model.family != .qwenVL ? nil : tools.map(Self.spec)
        let systemText = tools.isEmpty || model.family == .qwenVL ? system : system + "\n\n" + Self.describe(tools)
        // Fresh KV cache per reply prevents retained vision tensors and unbounded chat growth.
        return try await container.perform { context in
            // Never touch the GPU queue from the background: even an empty sync is GPU work.
            defer { if ComputeTarget.useCPU { Stream.cpu.synchronize() } else { Stream.gpu.synchronize() }; GPU.clearCache() }
            var recent = Array(messages.suffix(7))
            while recent.count > 1 && recent.first?.role == .assistant { recent.removeFirst() }
            var toolTurns: [Chat.Message] = []
            func prepare(_ recent: [ChatMessage]) async throws -> LMInput {
                let imageID = recent.last(where: { $0.imageName != nil })?.id
                let chat: [Chat.Message] = [.system(systemText)] + recent.map { message in
                    // Text-only models never receive images; the photo stays in the transcript.
                    let images: [UserInput.Image] = model.vision && message.id == imageID ? message.imageName.map { [.url(imagesDirectory.appendingPathComponent($0))] } ?? [] : []
                    let content = message.context.map { $0 + "\n\n" + message.text } ?? message.text
                    return Chat.Message(role: message.role == .user ? .user : .assistant, content: content, images: images)
                } + toolTurns
                let user = UserInput(chat: chat, processing: .init(resize: CGSize(width: 512, height: 512)), tools: specs)
                return try await Device.withDefaultDevice(ComputeTarget.device) {
                    try await context.processor.prepare(input: user)
                }
            }
            let parameters = GenerateParameters(maxTokens: ModelSpec.maxOutputTokens, temperature: 0.7, topP: 0.9, prefillStepSize: 128)
            let eos = Set(context.configuration.extraEOSTokens.compactMap { context.tokenizer.convertTokenToId($0) })
            var lowest = MemoryHeadroom.megabytes
            var total = 0
            let start = Date()
            for round in 0..<3 {
                var input = try await prepare(recent)
                while input.text.tokens.size > ModelSpec.maxInputTokens && recent.count > 1 {
                    try Task.checkCancellation()
                    recent.removeFirst()
                    while recent.count > 1 && recent.first?.role == .assistant { recent.removeFirst() }
                    input = try await prepare(recent)
                }
                guard input.text.tokens.size <= ModelSpec.maxInputTokens else {
                    throw IslandError.message("This prompt exceeds the 2,048-token phone context. Shorten your message or attach a smaller file.")
                }
                try Task.checkCancellation()
                await phase("Generating")
                // Prompt reading runs wherever the app is right now: GPU in the foreground, CPU if
                // the user already left.
                var onGPU = !ComputeTarget.useCPU
                var iterator = try Device.withDefaultDevice(ComputeTarget.device) {
                    try TokenIterator(input: input, model: context.model, parameters: parameters)
                }
                var tokens: [Int] = []
                // Keep generation inside this actor-owned operation. Cancellation drains GPU work
                // before another request can load or release model memory.
                while tokens.count < ModelSpec.maxOutputTokens {
                    try Task.checkCancellation()
                    if onGPU && ComputeTarget.mode != .foreground {
                        // Leaving: finish what the GPU already has, then queue nothing more until
                        // we know whether the app is coming back.
                        Stream.gpu.synchronize()
                        while ComputeTarget.mode == .leaving {
                            try await Task.sleep(for: .milliseconds(40))
                        }
                        if ComputeTarget.mode == .background {
                            await phase("Writing in background")
                            iterator = try Device.withDefaultDevice(.cpu) {
                                try TokenIterator(input: Self.continuing(input, with: tokens), model: context.model, parameters: parameters)
                            }
                            onGPU = false
                        }
                    } else if !onGPU && ComputeTarget.mode == .foreground {
                        onGPU = true // Back in the app: CPU results sit in shared memory, carry on on the GPU.
                    }
                    guard let token = Device.withDefaultDevice(onGPU ? .gpu : .cpu, { iterator.next() }) else { break }
                    if token == context.tokenizer.eosTokenId || token == context.tokenizer.unknownTokenId || eos.contains(token) { break }
                    tokens.append(token)
                    if tokens.count % 8 == 1 {
                        // Check real headroom; iOS's memory warnings arrive far earlier and are ignored.
                        lowest = min(lowest, MemoryHeadroom.megabytes)
                        if MemoryHeadroom.bytes < MemoryHeadroom.floor {
                            await update(ToolCall.visible(context.tokenizer.decode(tokens: tokens)), total + tokens.count)
                            throw IslandError.lowMemory(MemoryHeadroom.megabytes)
                        }
                    }
                    if tokens.count == 1 || tokens.count % 4 == 0 {
                        await update(ToolCall.visible(context.tokenizer.decode(tokens: tokens)), total + tokens.count)
                    }
                }
                // Pending GPU work must finish while the app may still use the GPU.
                if onGPU && ComputeTarget.mode == .foreground { Stream.gpu.synchronize() }
                total += tokens.count
                let text = context.tokenizer.decode(tokens: tokens)
                if round < 2, let call = ToolCall.parse(text), let tool = tools.first(where: { $0.tool.name == call.name }) {
                    await phase("Using \(tool.tool.name)")
                    let output = (try? await callTool(tool, call.argumentsJSON)) ?? "The tool could not be reached."
                    toolTurns += [.assistant(text), .tool(String(output.prefix(1500)))]
                    continue
                }
                let visible = ToolCall.visible(text)
                await update(visible, total)
                return InferenceResult(text: visible, tokens: total, seconds: Date().timeIntervalSince(start), headroom: min(lowest, MemoryHeadroom.megabytes))
            }
            throw IslandError.message("The model kept calling tools without answering.")
        }
        #endif
    }

    /// The original prompt followed by the tokens written so far, to resume on another device.
    /// Images (and their placeholder tokens) are kept, so a vision reply picks up exactly.
    static func continuing(_ input: LMInput, with generated: [Int]) -> LMInput {
        let prompt = input.text.tokens.asArray(Int32.self)
        let all = prompt + generated.map(Int32.init)
        let shape = input.text.tokens.ndim == 2 ? [1, all.count] : [all.count]
        let tokens = MLXArray(all).reshaped(shape)
        let mask = input.text.mask.map { MLX.ones(shape, dtype: $0.dtype) }
        return LMInput(text: .init(tokens: tokens, mask: mask), image: input.image, video: input.video)
    }

    /// OpenAI-style function spec for the chat template; schemas are trimmed to fit the context.
    private static func spec(_ definition: ToolDefinition) -> [String: any Sendable] {
        let schema = (try? JSONSerialization.jsonObject(with: Data(definition.tool.schema.utf8))) ?? [String: Any]()
        return ["type": "function", "function": [
            "name": definition.tool.name,
            "description": String(definition.tool.description.prefix(200)),
            "parameters": sendable(schema),
        ] as [String: any Sendable]]
    }

    private static func describe(_ tools: [ToolDefinition]) -> String {
        "You can call tools. To call one, reply with only <tool_call>{\"name\": \"…\", \"arguments\": {…}}</tool_call> and wait for the result.\nTools:\n"
            + tools.map { "- \($0.tool.name): \($0.tool.description.prefix(160)) Arguments schema: \($0.tool.schema.prefix(260))" }.joined(separator: "\n")
    }

    private static func sendable(_ value: Any) -> any Sendable {
        switch value {
        case let dictionary as [String: Any]: return dictionary.mapValues { sendable($0) } as [String: any Sendable]
        case let array as [Any]: return array.map { sendable($0) } as [any Sendable]
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): return number.boolValue
        case let number as NSNumber: return number.doubleValue
        case let string as String: return string
        default: return "\(value)"
        }
    }
}

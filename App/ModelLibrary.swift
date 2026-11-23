import Foundation

/// A model shared to Loocal from Hugging Face: how it's listed, and the files to fetch.
struct SharedModel: Codable, Sendable, Equatable {
    var choice: ModelChoice
    var spec: ModelSpec
    var repository: String { spec.repository }
}

extension ModelSpec: Equatable {
    static func == (a: ModelSpec, b: ModelSpec) -> Bool { a.repository == b.repository && a.revision == b.revision && a.files.map(\.name) == b.files.map(\.name) }
}

extension ModelSpec {
    /// The weights, which is what has to fit in memory.
    var weightBytes: Int64 { files.filter { $0.name.hasSuffix(".safetensors") }.reduce(0) { $0 + $1.size } }
}

/// Models shared from Hugging Face: reading a shared link, looking the model up, and
/// keeping the list on disk.
enum ModelLibrary {
    /// Where shared models are listed, next to the chats.
    static func listURL(_ files: LocalFiles) -> URL { files.root.appendingPathComponent("shared-models.json") }

    static func load(_ files: LocalFiles) -> [SharedModel] {
        guard let data = try? Data(contentsOf: listURL(files)) else { return [] }
        return (try? JSONDecoder().decode([SharedModel].self, from: data)) ?? []
    }

    static func save(_ models: [SharedModel], _ files: LocalFiles) {
        try? JSONEncoder().encode(models).write(to: listURL(files), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: Links

    /// Hugging Face pages that aren't a model.
    private static let reserved: Set<String> = ["datasets", "spaces", "docs", "blog", "settings", "organizations", "collections", "papers", "posts", "pricing", "learn", "join", "login", "api", "tasks", "enterprise", "chat"]

    /// `owner/name` from a Hugging Face model link (`huggingface.co/owner/name`, its files
    /// tab, a file in it, `hf.co/…`, or `huggingface.co/models/…`).
    static func repository(from url: URL) throws -> String {
        let host = url.host()?.lowercased().replacingOccurrences(of: "www.", with: "") ?? ""
        guard ["huggingface.co", "hf.co"].contains(host) else {
            throw IslandError.message("That isn’t a Hugging Face link. Share a model’s page from huggingface.co.")
        }
        var parts = url.pathComponents.filter { $0 != "/" }
        if parts.first == "models" { parts.removeFirst() }
        if let first = parts.first, reserved.contains(first.lowercased()) {
            throw IslandError.message(first == "datasets" ? "That’s a dataset, not a model." : first == "spaces" ? "That’s a Space, not a model. Share the model’s own page." : "Share a model’s page from Hugging Face.")
        }
        guard parts.count >= 2 else { throw IslandError.message("Share a model’s page from Hugging Face, like huggingface.co/owner/model.") }
        return parts[0] + "/" + parts[1]
    }

    // MARK: Looking a model up

    struct Info: Decodable {
        struct Sibling: Decodable {
            struct LFS: Decodable { let sha256: String?; let size: Int64? }
            let rfilename: String
            let size: Int64?
            let lfs: LFS?
        }
        struct Config: Decodable {
            struct Quantization: Decodable { let bits: Int? }
            let model_type: String?
            let quantization_config: Quantization?
        }
        let id: String
        let sha: String?
        let pipeline_tag: String?
        let library_name: String?
        let tags: [String]?
        let gated: Gated?
        let siblings: [Sibling]?
        let config: Config?

        /// `false`, or how access is granted ("auto", "manual").
        enum Gated: Decodable {
            case open, gated
            init(from decoder: Decoder) throws {
                let value = try decoder.singleValueContainer()
                self = (try? value.decode(Bool.self)) == false ? .open : .gated
            }
        }
    }

    /// Model types MLX runs as text models (mlx-swift-lm 2.29.3's LLM registry).
    static let textTypes: Set<String> = ["mistral", "llama", "phi", "phi3", "phimoe", "gemma", "gemma2", "gemma3", "gemma3_text", "gemma3n", "qwen2", "qwen3", "qwen3_moe", "starcoder2", "cohere", "openelm", "internlm2", "deepseek_v3", "granite", "granitemoehybrid", "mimo", "glm4", "acereason", "falcon_h1", "bitnet", "smollm3", "ernie4_5", "lfm2", "baichuan_m1", "exaone4", "gpt_oss", "olmoe", "olmo2", "olmo3", "bailing_moe", "lfm2_moe", "nanochat", "afmoe", "jamba_3b", "mistral3"]
    /// …and as vision models (its VLM registry).
    static let visionTypes: Set<String> = ["paligemma", "qwen2_vl", "qwen2_5_vl", "qwen3_vl", "idefics3", "gemma3", "smolvlm", "fastvlm", "llava_qwen2", "pixtral", "mistral3"]

    /// Looks the model up on Hugging Face and works out what Loocal would download.
    static func fetch(_ repository: String, session: URLSession = .shared) async throws -> SharedModel {
        guard let api = URL(string: "https://huggingface.co/api/models/\(repository)?blobs=true") else { throw IslandError.message("That model link isn’t valid.") }
        let (data, response) = try await session.data(from: api)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: break
        case 401, 403, 404: throw IslandError.message("\(repository) wasn’t found on Hugging Face. It may be private.")
        default: throw IslandError.message("Hugging Face didn’t answer. Try sharing the model again in a moment.")
        }
        let info = try JSONDecoder().decode(Info.self, from: data)
        if case .gated = info.gated { throw IslandError.message("\(info.id) asks you to accept its license on Hugging Face, which Loocal can’t do for you. Look for an ungated copy, such as one from mlx-community.") }
        guard let revision = info.sha else { throw IslandError.message("Hugging Face didn’t say which version of \(info.id) to fetch.") }
        let siblings = info.siblings ?? []
        let tags = Set(info.tags ?? [])
        let image = ["text-to-image", "image-to-image"].contains(info.pipeline_tag ?? "") || info.library_name == "diffusers" || tags.contains("diffusers") || siblings.contains { $0.rfilename == "model_index.json" }
        let files = wanted(siblings, keepFolders: image)
        guard files.contains(where: { $0.name.hasSuffix(".safetensors") }) else {
            throw IslandError.message(tags.contains("gguf") ? "\(info.id) is a GGUF model. Loocal runs MLX models: look for an MLX copy, such as one from mlx-community." : "\(info.id) has no safetensors weights Loocal can run.")
        }
        let spec = ModelSpec(repository: info.id, revision: revision, files: files)

        let family: ModelChoice.Family
        var bits = info.config?.quantization_config?.bits
        if image {
            // Painting runs Stable Diffusion pipelines (SDXL, SD 1.x and 2.x) in diffusers format.
            let index = URL(string: "https://huggingface.co/\(info.id)/resolve/\(revision)/model_index.json")!
            let (indexData, _) = try await session.data(from: index)
            let pipeline = ((try? JSONSerialization.jsonObject(with: indexData)) as? [String: Any])?["_class_name"] as? String
            guard let pipeline, Painter.Pipeline(className: pipeline) != nil else {
                throw IslandError.message("Loocal paints with Stable Diffusion models in diffusers format, like stabilityai/sdxl-turbo. \(info.id) \(pipeline.map { "is a \($0)." } ?? "has no diffusers pipeline.")")
            }
            family = .image
        } else {
            guard files.contains(where: { $0.name == "config.json" }), files.contains(where: { $0.name == "tokenizer.json" }) else {
                throw IslandError.message("\(info.id) is missing the config or tokenizer Loocal needs to run it.")
            }
            let configURL = URL(string: "https://huggingface.co/\(info.id)/resolve/\(revision)/config.json")!
            let (configData, _) = try await session.data(from: configURL)
            let config = (try? JSONSerialization.jsonObject(with: configData)) as? [String: Any] ?? [:]
            let type = (config["model_type"] as? String) ?? info.config?.model_type ?? ""
            bits = bits ?? ((config["quantization"] as? [String: Any])?["bits"] as? Int)
            family = try Self.family(type: type, vision: config["vision_config"] != nil, repository: info.id)
        }
        let name = shortName(info.id)
        let parameters = parameters(in: info.id) ?? Double(spec.weightBytes) * 8 / Double(bits ?? 16) / 1e9
        let owner = info.id.split(separator: "/").first.map(String.init) ?? ""
        let what = switch family {
        case .image: "pictures"
        case .qwenVL, .vision: "words and vision"
        case .gemmaText, .text: "words only"
        }
        let slug = info.id.replacingOccurrences(of: "/", with: "--")
        let choice = ModelChoice(id: "hf." + info.id.lowercased(), name: name, detail: "\(owner) · \(what)", manifest: nil,
                                 folder: "Shared/" + slug, family: family, parameters: parameters, custom: true)
        return SharedModel(choice: choice, spec: spec)
    }

    static func family(type: String, vision: Bool, repository: String) throws -> ModelChoice.Family {
        if type == "qwen3_vl" { return .qwenVL }
        if vision, visionTypes.contains(type) { return .vision }
        if textTypes.contains(type) { return type.hasPrefix("gemma3") && type != "gemma3n" ? .gemmaText : .text }
        if visionTypes.contains(type) { return .vision }
        throw IslandError.message(type.isEmpty ? "Loocal couldn’t tell what kind of model \(repository) is." : "Loocal can’t run \(type) models yet.")
    }

    /// The files worth fetching: weights, config and tokenizer, never docs, pictures or
    /// copies of the weights in other formats.
    static func wanted(_ siblings: [some SiblingLike], keepFolders: Bool) -> [ModelSpec.File] {
        let skipped: Set<String> = ["md", "png", "jpg", "jpeg", "gif", "webp", "svg", "pdf", "gitattributes", "gitignore"]
        let otherFormats: Set<String> = ["bin", "pt", "pth", "ckpt", "gguf", "onnx", "onnx_data", "msgpack", "h5", "ot", "tflite", "mlmodel", "pb", "npz"]
        let otherFolders = ["onnx/", "openvino/", "coreml/", "gguf/", "original/", "flax/", "tf/"]
        let names = Set(siblings.map(\.name))
        let hasSafetensors = names.contains { $0.hasSuffix(".safetensors") }
        let pipeline = names.contains("model_index.json")
        return siblings.compactMap { sibling in
            let name = sibling.name
            if keepFolders, name.hasSuffix(".safetensors") {
                // A picture pipeline's parts live in folders: a single-file copy at the root,
                // and full-precision twins of half-precision weights, are the same model again.
                if pipeline && !name.contains("/") { return nil }
                if !name.contains(".fp16."), names.contains(name.replacingOccurrences(of: ".safetensors", with: ".fp16.safetensors")) { return nil }
            }
            let lower = name.lowercased()
            let ext = (lower as NSString).pathExtension
            if !keepFolders && name.contains("/") { return nil } // MLX would read stray weights in subfolders
            if lower.hasPrefix(".") || name.contains("/.") || skipped.contains(ext) || lower.hasPrefix("license") || lower.hasPrefix("readme") { return nil }
            if otherFolders.contains(where: lower.hasPrefix) { return nil }
            if hasSafetensors && otherFormats.contains(ext) { return nil }
            guard let size = sibling.bytes else { return nil }
            return ModelSpec.File(name: name, size: size, sha256: sibling.hash)
        }
    }

    /// A name short enough for the model carousel: "Llama-3.2-3B-Instruct-4bit" → "Llama 3.2 3B".
    static func shortName(_ repository: String) -> String {
        let base = repository.split(separator: "/").last.map(String.init) ?? repository
        let noise: Set<String> = ["mlx", "instruct", "it", "chat", "hf", "bf16", "fp16", "fp32", "f16", "dwq", "qat", "abliterated", "uncensored", "gguf", "awq", "gptq", "mixed", "optimized", "q4", "q8", "q6", "q3"]
        let words = base.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " }).map(String.init).filter { word in
            let lower = word.lowercased()
            return !noise.contains(lower) && lower.wholeMatch(of: /\d+(\.\d+)?bits?/) == nil && lower.wholeMatch(of: /\d{4}/) == nil
        }
        var name = (words.isEmpty ? [base] : words).joined(separator: " ")
        name = name.replacing(/(\d)b\b/) { "\($0.output.1)B" }
        if let first = name.first, first.isLowercase { name = first.uppercased() + name.dropFirst() }
        return name.count > 22 ? String(name.prefix(21)) + "…" : name
    }

    /// Billions of parameters, from the name: "3B", "0.5B", "1.5b", "270M". "A3B" (active
    /// experts) and "E4B" don't count: the full size comes first.
    static func parameters(in repository: String) -> Double? {
        let name = repository.split(separator: "/").last.map(String.init) ?? repository
        func first(_ unit: String) -> Double? {
            let pattern = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9.])(\\d+(?:\\.\\d+)?)[\(unit)](?![A-Za-z])")
            let range = NSRange(name.startIndex..., in: name)
            guard let match = pattern.firstMatch(in: name, range: range), let value = Range(match.range(at: 1), in: name) else { return nil }
            return Double(name[value])
        }
        return first("Bb") ?? first("Mm").map { $0 / 1000 }
    }
}

/// A file in a Hugging Face listing, as `wanted` reads it.
protocol SiblingLike {
    var name: String { get }
    var bytes: Int64? { get }
    var hash: String? { get }
}

extension ModelLibrary.Info.Sibling: SiblingLike {
    var name: String { rfilename }
    var bytes: Int64? { lfs?.size ?? size }
    var hash: String? { lfs?.sha256 }
}

/// Whether a model's weights are likely more than iOS lets Loocal use on this phone.
enum ModelFit {
    static func mayNotFit(_ spec: ModelSpec) -> Bool {
        let ceiling = Int64(MemoryHeadroom.ceiling)
        guard ceiling > 0 else { return false } // unknown (the simulator)
        // What loading needs (as the engine checks it), plus room for a short reply.
        return spec.weightBytes + Int64(MemoryHeadroom.floor) + 160 * 1_048_576 + 256 * 1_048_576 > ceiling
    }
}

import CoreGraphics
import Foundation
import MLX
import StableDiffusion
import UIKit

/// What the chat shows for a picture being painted, and the picture once it's done.
struct PaintInfo: Codable, Sendable, Equatable {
    var prompt: String
    var width: Int
    var height: Int
    var model: String
}

/// How far a picture has got: denoising steps done of all.
struct PaintStep: Equatable, Sendable {
    var done: Int
    var total: Int
    var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
}

/// Paints pictures with a downloaded Stable Diffusion model (SDXL Turbo, SD 2.1 and their
/// fine-tunes in diffusers format). One picture at a time; the model is let go afterwards so
/// chat models get their memory back.
actor Painter {
    /// Stable Diffusion pipelines Loocal can run, by `model_index.json`'s class.
    enum Pipeline: Sendable {
        case xl, base
        init?(className: String) {
            switch className {
            case "StableDiffusionXLPipeline": self = .xl
            case "StableDiffusionPipeline": self = .base
            default: return nil
            }
        }
        static func read(_ directory: URL) -> Pipeline? {
            let data = try? Data(contentsOf: directory.appendingPathComponent("model_index.json"))
            let root = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            return (root?["_class_name"] as? String).flatMap(Pipeline.init(className:))
        }
    }

    /// Steps and guidance: distilled models (Turbo, Lightning) need a couple of steps and no
    /// guidance; the rest want more of both.
    static func settings(for id: String, pipeline: Pipeline) -> (steps: Int, cfg: Float) {
        let id = id.lowercased()
        if id.contains("turbo") { return (2, 0) }
        if id.contains("lightning") { return (4, 0) }
        if id.contains("lcm") { return (4, 1) }
        return pipeline == .xl ? (20, 5) : (20, 7.5)
    }

    /// Pictures come out square, this many pixels a side (latents are 8× smaller).
    static let side = 512

    /// Paints `prompt`. `step` is told each denoising step as it finishes (1-based).
    func paint(model: ModelChoice, directory: URL, prompt: String, seed: UInt64? = nil,
               step: @escaping @Sendable (Int, Int) async -> Void) async throws -> CGImage {
        #if targetEnvironment(simulator)
        // The simulator has no Metal GPU for MLX: a stand-in picture, so the interface can be seen.
        let total = 2
        for i in 1...total {
            try await Task.sleep(for: .seconds(2.2))
            try Task.checkCancellation()
            await step(i, total)
        }
        return Self.standIn(prompt)
        #else
        guard let pipeline = Pipeline.read(directory) else {
            throw IslandError.message("\(model.name) isn’t a Stable Diffusion model Loocal can paint with yet.")
        }
        let weights = (try? FileManager.default.subpathsOfDirectory(atPath: directory.path))?
            .filter { $0.hasSuffix(".safetensors") }
            .reduce(0) { $0 + Int(DownloadDelegate.size(of: directory.appendingPathComponent($1))) } ?? 0
        // 8-bit weights when the half-precision ones wouldn't leave room to work.
        let quantize = MemoryHeadroom.ceiling > 0 && weights + 2_500 * 1_048_576 > MemoryHeadroom.ceiling
        let base: StableDiffusionConfiguration = pipeline == .xl ? .presetSDXLTurbo : .presetStableDiffusion21Base
        let client = HubClient(directory: directory)
        GPU.set(cacheLimit: 64 * 1024 * 1024)
        defer { GPU.clearCache() }
        // SD 1.x/2.x decoders run fine in half precision, which halves the biggest moment of
        // the whole generation (SDXL's decoder needs float32 to stay clean).
        let configuration = LoadConfiguration(float16: true, quantize: quantize, decoderFloat16: pipeline == .base)
        // The only reference to the models, so letting it go below really frees them.
        var generator = try base.textToImageGenerator(client: client, configuration: configuration)
        guard generator != nil else {
            throw IslandError.message("\(model.name) couldn’t be prepared for painting.")
        }
        try Task.checkCancellation()
        generator?.ensureLoaded()
        let (steps, cfg) = Self.settings(for: model.id, pipeline: pipeline)
        var parameters = EvaluateParameters(cfgWeight: cfg, steps: steps, latentSize: [Self.side / 8, Self.side / 8], seed: seed)
        parameters.prompt = prompt
        var last: MLXArray?
        var done = 0
        for xt in generator!.generateLatents(parameters: parameters) {
            try Task.checkCancellation()
            eval(xt)
            last = xt
            done += 1
            await step(done, steps)
        }
        guard let last else { throw IslandError.message("The picture couldn’t be painted.") }
        // Turning the result into pixels is the peak: the UNet and text encoder (most of the
        // weights) are let go first, and only the decoder stays. Measured on SD Turbo, this and
        // the half-precision decoder take the peak from 6.9 GB (past what iOS allows) to 3.2 GB.
        let decoder = generator!.detachedDecoder()
        generator = nil
        GPU.clearCache()
        let decoded = decoder(last)
        let pixels = (decoded[0] * 255).asType(.uint8)
        eval(pixels)
        return Image(pixels).asCGImage()
        #endif
    }

    /// A soft, painterly gradient standing in for a picture where MLX can't run.
    static func standIn(_ prompt: String) -> CGImage {
        let size = CGSize(width: side, height: side)
        var hash = prompt.unicodeScalars.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1.value)) &* 1099511628211 }
        func next() -> CGFloat { hash = hash &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(hash >> 33) / CGFloat(UInt32.max >> 1) }
        let renderer = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        let image = renderer.image { context in
            let cg = context.cgContext
            let hue = next()
            UIColor(hue: hue, saturation: 0.45, brightness: 0.95, alpha: 1).setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            for i in 0..<14 {
                let color = UIColor(hue: (hue + next() * 0.5).truncatingRemainder(dividingBy: 1), saturation: 0.5 + next() * 0.4, brightness: 0.55 + next() * 0.45, alpha: 0.55)
                let center = CGPoint(x: next() * size.width, y: next() * size.height)
                let radius = 60 + next() * 200
                let colors = [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                    cg.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
                }
                if i % 3 == 0 {
                    let path = UIBezierPath()
                    path.move(to: CGPoint(x: next() * size.width, y: next() * size.height))
                    path.addCurve(to: CGPoint(x: next() * size.width, y: next() * size.height),
                                  controlPoint1: CGPoint(x: next() * size.width, y: next() * size.height),
                                  controlPoint2: CGPoint(x: next() * size.width, y: next() * size.height))
                    color.withAlphaComponent(0.35).setStroke()
                    path.lineWidth = 18 + next() * 30
                    path.lineCapStyle = .round
                    path.stroke()
                }
            }
        }
        return image.cgImage!
    }
}

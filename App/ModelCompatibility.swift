import Foundation

/// MLX Swift LM 2.29.3 reads tying from text_config, while this checkpoint
/// declares it at the root. Preserve the checkpoint's untied output head in memory,
/// without modifying the pinned, verified files on disk.
enum ModelCompatibility {
    static func qwenConfiguration(_ data: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["model_type"] as? String == "qwen3_vl",
              var text = root["text_config"] as? [String: Any] else {
            throw IslandError.message("The installed model has an unsupported configuration.")
        }
        if text["tie_word_embeddings"] == nil, let tying = root["tie_word_embeddings"] as? Bool {
            text["tie_word_embeddings"] = tying
            root["text_config"] = text
        }
        return try JSONSerialization.data(withJSONObject: root)
    }
}

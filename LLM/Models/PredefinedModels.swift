import Foundation

// MARK: - Predefined Models
//
// LiteRT-LM 的 Gemma 4 模型描述符。
// 产品层和 UI 通过 ModelCatalog.availableModels 拿到这些，不直接引用。

public extension ModelDescriptor {

    // MARK: - Gemma 4 E2B (LiteRT)

    /// Gemma 4 E2B — 轻量, ~2.4 GB 单文件，适合 Live 和日常聊天
    static let gemma4E2B = ModelDescriptor(
        id: "gemma-4-e2b-it-litert",
        displayName: "Gemma 4 E2B",
        family: .gemma4,
        artifactKind: .litertlmFile,
        downloadURLs: [
            // 1. ModelScope (国内优先)
            URL(string: "https://modelscope.cn/models/litert-community/gemma-4-E2B-it-litert-lm/resolve/master/gemma-4-E2B-it.litertlm")!,
            // 2. HuggingFace Mirror (hf-mirror.com)
            URL(string: "https://hf-mirror.com/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm")!,
            // 3. HuggingFace (原站)
            URL(string: "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm")!,
        ],
        fileName: "gemma-4-E2B-it.litertlm",
        expectedFileSize: 2_600_000_000,
        capabilities: ModelCapabilities(
            supportsVision: true,
            supportsAudio: true,
            supportsLive: true,
            supportsStructuredPlanning: false,
            supportsThinking: true,
            supportsPersistentSession: true,
            supportsSessionSnapshot: false,
            safeContextBudgetTokens: 3500,
            defaultReservedOutputTokens: 1024
        ),
        runtimeProfile: MLXModelProfiles.gemma4_e2b
    )

    // MARK: - Gemma 4 E4B (LiteRT)

    /// Gemma 4 E4B — 重量, ~3.4 GB 单文件，支持复杂规划和多工具编排
    static let gemma4E4B = ModelDescriptor(
        id: "gemma-4-e4b-it-litert",
        displayName: "Gemma 4 E4B",
        family: .gemma4,
        artifactKind: .litertlmFile,
        downloadURLs: [
            // 1. ModelScope (国内优先)
            URL(string: "https://modelscope.cn/models/litert-community/gemma-4-E4B-it-litert-lm/resolve/master/gemma-4-E4B-it.litertlm")!,
            // 2. HuggingFace Mirror (hf-mirror.com)
            URL(string: "https://hf-mirror.com/litert-community/gemma-4-E4B-it-litert-lm/resolve/main/gemma-4-E4B-it.litertlm")!,
            // 3. HuggingFace (原站)
            URL(string: "https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/main/gemma-4-E4B-it.litertlm")!,
        ],
        fileName: "gemma-4-E4B-it.litertlm",
        expectedFileSize: 3_700_000_000,
        capabilities: ModelCapabilities(
            supportsVision: true,
            supportsAudio: true,
            supportsLive: false,          // E4B CPU 延迟太高，不适合 Live
            supportsStructuredPlanning: true,
            supportsThinking: true,
            supportsPersistentSession: true,
            supportsSessionSnapshot: false,
            safeContextBudgetTokens: 2900,
            defaultReservedOutputTokens: 896
        ),
        runtimeProfile: MLXModelProfiles.gemma4_e4b
    )

    // MARK: - All Models

    /// 所有可用模型（按推荐顺序）
    static let allModels: [ModelDescriptor] = [.gemma4E2B, .gemma4E4B]

    /// 默认模型
    static let defaultModel: ModelDescriptor = .gemma4E2B
}

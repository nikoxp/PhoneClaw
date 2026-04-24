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
            // LiteRT GPU KV-cache = 4096 (vs 32K 省 ~4 GB Metal buffer).
            // input + output 必须 ≤ 4096. 输入预算 3000 + 生成预算 900 = 3900,
            // 留 196 token margin 给 BOS/EOS / 系统控制 token / tool_call tail.
            // 2026-04-23: 预算从 1300/700 (对应 2048 KV) 提到 3000/900 (对应 4096 KV) —
            // 首轮调用 Calendar / Contacts / Health 等技能时 SKILL.md 会 inline
            // 进 prompt (~1000-1500 token), 1300 input 预算会 hard-reject 掉所有
            // 技能触发型对话. 3000 input 能 hold 住 system + 2 个 skill + 首轮 user.
            // 输出预算从 700 → 900: 技能触发后模型常常返回 JSON tool_call + 自然语言
            // 解释, 700 偶尔会在 ```json 块中间截断.
            safeContextBudgetTokens: 3000,
            defaultReservedOutputTokens: 900
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
            // LiteRT KV-cache = 2048 (E4B 专用, E2B 用 4096). 原因:
            // E4B 权重 ~3.4 GB + 4096 KV (~1 GB) 在 Sideloadly 免费签名
            // app 的 jetsam 阈值 (~3-4 GB) 下会 runtime invoke 失败
            // ("Failed to invoke the compiled model"). 2048 KV 把 KV 占
            // 降到 ~0.5 GB, 总内存 ~3.9 GB 刚好能装下。
            // 输入预算 1300 + 生成预算 600 = 1900, 留 148 token margin.
            safeContextBudgetTokens: 1300,
            defaultReservedOutputTokens: 600
        ),
        runtimeProfile: MLXModelProfiles.gemma4_e4b
    )

    // MARK: - All Models

    /// 所有可用模型（按推荐顺序）
    static let allModels: [ModelDescriptor] = [.gemma4E2B, .gemma4E4B]

    /// 默认模型
    static let defaultModel: ModelDescriptor = .gemma4E2B
}

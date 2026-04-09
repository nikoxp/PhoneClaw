import Foundation

// MARK: - Runtime Profile 类型
//
// 设计目标: 把"哪个模型在 headroom X 时给 Y token"的所有业务参数, 从硬编码
// switch / tier 表迁移成**连续的线性公式**。原因:
//   1. tier 表是 step function, 在边界附近 1 MB 差距导致几百 token 跳变, 不直观
//   2. 标定 tier 表需要逐档调数字, 校准成本高; 公式只调 4 个参数
//   3. chunked prefill 已让 prepared 长度对峰值内存影响极小, 可以用线性外推
//
// 所有 token 预算 = clamp(min, max(0, headroom - safetyMargin) * tokensPerMB, max)
//
// 多模态和 historyDepth 仍保留 tier 表, 因为:
//   - 多模态: imageSoftCap + maxOut 双约束, 而且有硬天花板 512, 不是单调线性
//   - historyDepth: 整数消息数, 只有 4 个离散值

/// 线性预算公式:
///   tokens = clamp(minTokens, max(0, headroom - safetyMarginMB) * tokensPerMB, maxTokens)
public struct LinearBudgetFormula: Sendable, Equatable {
    public let safetyMarginMB: Int  // headroom 减去这个量才参与计算 (留给系统/transient peak)
    public let tokensPerMB: Double  // 1 MB usable headroom 折算多少 token
    public let minTokens: Int       // 下限 (即使 headroom 极低也保证最少这么多)
    public let maxTokens: Int       // 上限 (避免 headroom 极大时给出荒诞的输出长度)

    public init(safetyMarginMB: Int, tokensPerMB: Double, minTokens: Int, maxTokens: Int) {
        self.safetyMarginMB = safetyMarginMB
        self.tokensPerMB = tokensPerMB
        self.minTokens = minTokens
        self.maxTokens = maxTokens
    }

    public func evaluate(headroom: Int) -> Int {
        let usable = max(0, headroom - safetyMarginMB)
        let raw = Int((Double(usable) * tokensPerMB).rounded())
        return min(maxTokens, max(minTokens, raw))
    }
}

/// 单档预算 (仅用于 historyDepth, 整数离散映射)
public struct BudgetTier: Sendable, Equatable {
    public let headroomMaxMB: Int  // headroom < 此值时命中此档
    public let tokens: Int         // 此处 tokens 字段是"消息条数"

    public init(headroomMaxMB: Int, tokens: Int) {
        self.headroomMaxMB = headroomMaxMB
        self.tokens = tokens
    }
}

/// 多模态单档预算: 双约束 (image cap + max output) + 硬天花板
public struct MultimodalTier: Sendable, Equatable {
    public let headroomMaxMB: Int
    public let imageSoftTokenCap: Int?
    public let maxOutputTokens: Int

    public init(headroomMaxMB: Int, imageSoftTokenCap: Int?, maxOutputTokens: Int) {
        self.headroomMaxMB = headroomMaxMB
        self.imageSoftTokenCap = imageSoftTokenCap
        self.maxOutputTokens = maxOutputTokens
    }
}

/// 模型运行时 profile
///
/// 历史背景:
/// 早期版本有 textSequenceBudget / thinkingSequenceBudget 两个字段, 用来表达
/// "prompt + output 的总序列预算"。这是 chunked prefill 之前的设计, 假设 KV
/// cache 与总序列长度线性增长, prompt 必须从 output 预算里扣减。
///
/// chunked prefill (windowSize=256) 上线后, 单次 forward 的 transient 内存
/// 与 prompt 长度解耦, prepared 长度对峰值内存几乎无影响 (实测 prepared
/// 290 → 3319 之间, footprint Δ 完全不相关)。"总序列预算"概念失去意义,
/// 已删除。output 上限只受 textOutputBudget / thinkingOutputBudget 单一约束,
/// 它们已经是 headroom 的函数, 内存吃紧时自动收紧, 无需再做 prepared 扣减。
public struct ModelRuntimeProfile: Sendable {
    /// 触发 thinking 模式的 marker (nil = 不支持 thinking)
    public let thinkingMarker: String?

    /// 普通文本输出 token 上限 (单次 generateStream 的硬上限, 不含 prompt)
    public let textOutputBudget: LinearBudgetFormula

    /// thinking 输出 token 上限
    public let thinkingOutputBudget: LinearBudgetFormula

    /// 多模态输出: 保留 tier 表 (双约束 + 硬天花板, 不适合线性化)
    public let multimodalOutputTiers: [MultimodalTier]

    /// 多模态严格下限 (headroom <= 此值直接 throw multimodalMemoryRisk)
    /// 0 = 不做严格下限检查
    public let multimodalCriticalHeadroomMB: Int

    /// safeHistoryDepth: 整数离散映射, 保留 tier 表
    public let historyDepthTiers: [BudgetTier]

    public init(
        thinkingMarker: String?,
        textOutputBudget: LinearBudgetFormula,
        thinkingOutputBudget: LinearBudgetFormula,
        multimodalOutputTiers: [MultimodalTier],
        multimodalCriticalHeadroomMB: Int,
        historyDepthTiers: [BudgetTier]
    ) {
        self.thinkingMarker = thinkingMarker
        self.textOutputBudget = textOutputBudget
        self.thinkingOutputBudget = thinkingOutputBudget
        self.multimodalOutputTiers = multimodalOutputTiers
        self.multimodalCriticalHeadroomMB = multimodalCriticalHeadroomMB
        self.historyDepthTiers = historyDepthTiers
    }
}

// MARK: - Gemma 4 Profiles
//
// 公式系数标定原则 (基于 2026-04-08 实测日志):
//   - E4B baseline footprint = 4550 MB, 生成时峰值 +400 MB transient
//   - jetsam = 6144 MB, 实测 headroom 稳定在 1500-1600 MB
//   - safetyMarginMB = 300: 留 200 MB jetsam buffer + 100 MB transient overhead
//   - tokensPerMB 约为 1.0-1.8: 1 MB usable headroom 大概折 1-2 个 token 的 KV cache
//   - sequence > output: 序列预算包含 prompt + output, 系数比 output 更高

public enum MLXModelProfiles {

    // MARK: Gemma 4 E2B — 轻量, 26 layers (KV cache 较小)

    public static let gemma4_e2b = ModelRuntimeProfile(
        thinkingMarker: "<|think|>",

        // 单次输出 token 上限
        // @500: 1.4*250=350→min384;  @1000: 1.4*750=1050;  @1500: 1.4*1250=1750;  @2000: cap 2048
        textOutputBudget: LinearBudgetFormula(
            safetyMarginMB: 250, tokensPerMB: 1.4, minTokens: 384, maxTokens: 2_048
        ),

        // thinking 输出比文本更紧 (避免思考占满预算把答案挤掉)
        // @500: min;  @1000: 1.1*750=825;  @1500: 1.1*1250=1375;  @2000: cap 1536
        thinkingOutputBudget: LinearBudgetFormula(
            safetyMarginMB: 250, tokensPerMB: 1.1, minTokens: 256, maxTokens: 1_536
        ),

        // 多模态: E2B 不像 E4B 那么吃内存, 平表
        multimodalOutputTiers: [
            MultimodalTier(headroomMaxMB: .max, imageSoftTokenCap: 160, maxOutputTokens: 512),
        ],
        multimodalCriticalHeadroomMB: 0,

        historyDepthTiers: [
            BudgetTier(headroomMaxMB: 500,    tokens: 0),
            BudgetTier(headroomMaxMB: 900,    tokens: 2),
            BudgetTier(headroomMaxMB: 1_500,  tokens: 4),
            BudgetTier(headroomMaxMB: .max,   tokens: 6),
        ]
    )

    // MARK: Gemma 4 E4B — 重量, 42 layers (KV cache 大, 更紧)

    public static let gemma4_e4b = ModelRuntimeProfile(
        thinkingMarker: "<|think|>",

        // 单次输出 token 上限
        // 实测验证 @1500: 1.0*1200=1200 vs 旧 tier 1280 (基本持平)
        // @1700: 1.0*1400=1400; @2000: 1.0*1700=1700→cap 1500
        textOutputBudget: LinearBudgetFormula(
            safetyMarginMB: 300, tokensPerMB: 1.0, minTokens: 256, maxTokens: 1_500
        ),

        // thinking 单独放更紧的系数
        thinkingOutputBudget: LinearBudgetFormula(
            safetyMarginMB: 300, tokensPerMB: 0.85, minTokens: 192, maxTokens: 1_280
        ),

        // 多模态: E4B vision 激活内存大, 必须保留细分 tier
        multimodalOutputTiers: [
            MultimodalTier(headroomMaxMB: 500,    imageSoftTokenCap: 48,  maxOutputTokens: 120),
            MultimodalTier(headroomMaxMB: 700,    imageSoftTokenCap: 64,  maxOutputTokens: 200),
            MultimodalTier(headroomMaxMB: 900,    imageSoftTokenCap: 80,  maxOutputTokens: 340),
            MultimodalTier(headroomMaxMB: 1_100,  imageSoftTokenCap: 96,  maxOutputTokens: 512),
            MultimodalTier(headroomMaxMB: 1_300,  imageSoftTokenCap: 128, maxOutputTokens: 512),
            MultimodalTier(headroomMaxMB: .max,   imageSoftTokenCap: 160, maxOutputTokens: 512),
        ],
        multimodalCriticalHeadroomMB: 320,

        historyDepthTiers: [
            BudgetTier(headroomMaxMB: 700,    tokens: 0),
            BudgetTier(headroomMaxMB: 1_100,  tokens: 2),
            BudgetTier(headroomMaxMB: 1_700,  tokens: 4),
            BudgetTier(headroomMaxMB: .max,   tokens: 6),
        ]
    )

    // MARK: - Lookup

    /// 根据 model.id 查 profile
    public static func profile(for modelID: String) -> ModelRuntimeProfile? {
        switch modelID {
        case "gemma-4-e2b-it-4bit": return gemma4_e2b
        case "gemma-4-e4b-it-4bit": return gemma4_e4b
        default: return nil
        }
    }
}

import Foundation
import CoreImage
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
#if canImport(UIKit)
import UIKit
#endif

// MARK: - MLX Local LLM Service

public struct BundledModelOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let directoryName: String
    public let displayName: String
    public let repositoryID: String
    public let requiredFiles: [String]

    /// Planner 及其他结构化 JSON 输出场景是否可用。
    /// false 时 Planner 入口会被跳过（具体降级策略见 architecture-decisions.md ADR-004）。
    public let supportsStructuredPlanning: Bool

    /// 运行时 budget / thinking / fallback 行为数据。所有 headroom→token 表都在这里,
    /// 框架层 RuntimeBudgets 只查表, 不判断 model.id。
    public let runtimeProfile: ModelRuntimeProfile

    // Hashable / Equatable: 仅用 id (ModelRuntimeProfile 不 Hashable)
    public static func == (lhs: BundledModelOption, rhs: BundledModelOption) -> Bool {
        lhs.id == rhs.id
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// MLX GPU inference service for Gemma 4.
/// Forces MLX Metal GPU path — no CPU fallback.
@Observable
public class MLXLocalLLMService: LLMEngine {
    static let availableModels: [BundledModelOption] = [
        .init(
            id: "gemma-4-e2b-it-4bit",
            directoryName: "gemma-4-e2b-it-4bit",
            displayName: "Gemma 4 E2B",
            repositoryID: "mlx-community/gemma-4-e2b-it-4bit",
            requiredFiles: [
                "config.json",
                "generation_config.json",
                "model.safetensors",
                "model.safetensors.index.json",
                "processor_config.json",
                "tokenizer.json",
                "tokenizer_config.json",
                "chat_template.jinja"
            ],
            supportsStructuredPlanning: false,
            runtimeProfile: MLXModelProfiles.gemma4_e2b
        ),
        .init(
            id: "gemma-4-e4b-it-4bit",
            directoryName: "gemma-4-e4b-it-4bit",
            displayName: "Gemma 4 E4B",
            repositoryID: "mlx-community/gemma-4-e4b-it-4bit",
            requiredFiles: [
                "config.json",
                "generation_config.json",
                "model.safetensors",
                "model.safetensors.index.json",
                "processor_config.json",
                "tokenizer.json",
                "tokenizer_config.json",
                "chat_template.jinja"
            ],
            supportsStructuredPlanning: true,
            runtimeProfile: MLXModelProfiles.gemma4_e4b
        )
    ]
    static let defaultModel = availableModels[0]

    // MARK: - State

    public private(set) var isLoaded = false
    public private(set) var isLoading = false
    public private(set) var isGenerating = false
    public private(set) var stats = LLMStats()
    public var statusMessage = "等待加载模型..."
    public internal(set) var selectedModel = defaultModel
    public internal(set) var loadedModel: BundledModelOption?
    public var modelDisplayName: String { loadedModel?.displayName ?? selectedModel.displayName }
    public var selectedModelID: String { selectedModel.id }
    public var loadedModelID: String? { loadedModel?.id }
    public internal(set) var modelInstallStates: [String: ModelInstallState] = [:]
    public internal(set) var modelDownloadMetrics: [String: ModelDownloadMetrics] = [:]

    // MARK: - Compatibility Settings

    public var useGPU = true
    public var samplingTopK: Int = 40
    public var samplingTopP: Float = 0.95
    public var samplingTemperature: Float = 1.0
    public var maxOutputTokens: Int = 4000

    // Internal (not private) so extensions in ModelDownloader/Installer/GPULifecycle
    // files can read/write these. Not part of the public API.
    var modelContainer: ModelContainer?
    var cancelled = false
    var currentLoadTask: Task<Void, Never>?
    var currentGenerationTask: Task<Void, Never>?
    var currentDownloadTasks: [String: Task<Void, Never>] = [:]
    let foregroundStateLock = NSLock()
    var foregroundGPUAllowed = true
    var lifecycleObserverTokens: [NSObjectProtocol] = []
    var audioCapabilityEnabled = false

    /// Local path to the model directory
    var modelPath: URL {
        ModelPaths.resolve(for: selectedModel)
    }

    // MARK: - Init

    public init(selectedModelID: String? = nil) {
        if let selectedModelID,
           let option = Self.availableModels.first(where: { $0.id == selectedModelID }) {
            self.selectedModel = option
        }
        self.stats.backend = "mlx-gpu"
        configureLifecycleObservers()
        cleanupStalePartialDirectories()
        refreshModelInstallStates()
    }

    deinit {
        for token in lifecycleObserverTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Convenience init with default model location
    public convenience init() {
        self.init(selectedModelID: nil)
    }

    func loadModel() {
        currentLoadTask?.cancel()
        currentLoadTask = Task { [weak self] in
            guard let self else { return }
            defer { self.currentLoadTask = nil }
            do {
                if self.isLoading {
                    return
                }
                try await load()
                try await warmup()
            } catch is CancellationError {
                await MainActor.run {
                    if self.statusMessage.hasPrefix("正在加载") || self.statusMessage.hasPrefix("正在初始化") {
                        self.statusMessage = "已取消模型切换"
                    }
                }
            } catch {
                if let mlxError = error as? MLXError,
                   case .modelDirectoryMissing = mlxError {
                    statusMessage = "请在配置中下载 \(self.selectedModel.displayName) 模型"
                } else {
                    statusMessage = "❌ \(error.localizedDescription)"
                }
                self.isLoaded = false
                self.loadedModel = nil
                self.refreshModelInstallStates()
                print("[MLX] Load failed: \(error.localizedDescription)")
            }
        }
    }

    func generateStream(
        prompt: String,
        images: [CIImage] = [],
        audios: [UserInput.Audio] = [],
        onToken: @escaping (String) -> Void,
        onComplete: @escaping (Result<String, Error>) -> Void
    ) {
        Task {
            var fullResponse = ""

            do {
                for try await token in generateStream(prompt: prompt, images: images, audios: audios) {
                    fullResponse += token
                    await MainActor.run {
                        onToken(token)
                    }
                }

                await MainActor.run {
                    onComplete(.success(fullResponse))
                }
            } catch {
                await MainActor.run {
                    onComplete(.failure(error))
                }
            }
        }
    }

    func generateStream(
        chat: [Chat.Message],
        onToken: @escaping (String) -> Void,
        onComplete: @escaping (Result<String, Error>) -> Void
    ) {
        Task {
            var fullResponse = ""

            do {
                for try await token in generateStream(chat: chat) {
                    fullResponse += token
                    await MainActor.run {
                        onToken(token)
                    }
                }

                await MainActor.run {
                    onComplete(.success(fullResponse))
                }
            } catch {
                await MainActor.run {
                    onComplete(.failure(error))
                }
            }
        }
    }

    func generateStream(
        chat: [Chat.Message],
        additionalContext: [String: any Sendable]?,
        onToken: @escaping (String) -> Void,
        onComplete: @escaping (Result<String, Error>) -> Void
    ) {
        Task {
            var fullResponse = ""

            do {
                for try await token in generateStream(chat: chat, additionalContext: additionalContext) {
                    fullResponse += token
                    await MainActor.run {
                        onToken(token)
                    }
                }

                await MainActor.run {
                    onComplete(.success(fullResponse))
                }
            } catch {
                await MainActor.run {
                    onComplete(.failure(error))
                }
            }
        }
    }

    // MARK: - LLMEngine Protocol

    public func load() async throws {
        if isLoading {
            return
        }
        let model = selectedModel
        let path = ModelPaths.resolve(for: model)
        isLoading = true
        defer {
            isLoading = false
        }
        statusMessage = "正在初始化模型..."
        await Gemma4Registration.setAudioCapabilityEnabled(audioCapabilityEnabled)
        await Gemma4Registration.register()

        guard ModelPaths.hasRequiredFiles(model, at: path) else {
            throw MLXError.modelDirectoryMissing(model.displayName)
        }

        statusMessage = "正在加载 \(model.displayName)..."
        let loadStart = CFAbsoluteTimeGetCurrent()
        print("[MLX] load capability — audio=\(audioCapabilityEnabled ? 1 : 0)")

        // ── Memory diagnostics (read before load) ──────────────────────────────
        let physMB = Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576
        let (footprintBefore, limitBefore) = MemoryStats.footprintMB()
        print("[MEM] Physical RAM: \(Int(physMB)) MB")
        print("[MEM] Before load — footprint: \(Int(footprintBefore)) MB, jetsam limit: \(Int(limitBefore)) MB")
        print("[MEM] MLX before — active: \(MLX.GPU.activeMemory / 1_048_576) MB, cache: \(MLX.GPU.cacheMemory / 1_048_576) MB")

        let container = try await VLMModelFactory.shared.loadContainer(
            from: path,
            using: MLXTokenizersLoader()
        )

        try Task.checkCancellation()
        self.modelContainer = container
        self.isLoaded = true
        self.loadedModel = model

        // ── Memory diagnostics (read after load) ───────────────────────────────
        let (footprintAfter, _) = MemoryStats.footprintMB()
        print("[MEM] After load  — footprint: \(Int(footprintAfter)) MB")
        print("[MEM] MLX after   — active: \(MLX.GPU.activeMemory / 1_048_576) MB, cache: \(MLX.GPU.cacheMemory / 1_048_576) MB")

        let elapsed = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000
        stats.loadTimeMs = elapsed
        statusMessage = "模型已就绪 ✅ (\(Int(elapsed))ms)"

        print("[MLX] Model loaded in \(Int(elapsed))ms — backend: mlx-gpu — model: \(model.displayName)")
    }

    private func ensureAudioCapability(hasAudio: Bool) async throws {
        guard hasAudio != audioCapabilityEnabled || !isLoaded || modelContainer == nil else {
            return
        }

        audioCapabilityEnabled = hasAudio
        print("[MLX] capability switch requested — audio=\(hasAudio ? 1 : 0)")

        if isLoaded || modelContainer != nil {
            await prepareForReload(cancelCurrentGeneration: false, cancelCurrentLoad: false)
        }

        try await load()
    }

    /// 当前可用内存 headroom（MB）。Agent 用来动态调整 history 深度。
    public var availableHeadroomMB: Int {
        MemoryStats.headroomMB
    }

    /// 根据当前剩余内存推荐安全的 history 深度（消息条数）。
    /// Chunked prefill (LLM/MLX/Gemma4Model.swift) 把单次 forward 的 transient
    /// 内存峰值钉死在 chunk² (windowSize=256), 不再随总序列长度线性增长。
    /// 因此 history 可以放更多: KV cache 增量是每 token ~14KB × layers, 几条
    /// 历史消息只多几十 MB, 远低于现在 ~1GB 的稳定 headroom。
    public var safeHistoryDepth: Int {
        let profile = (loadedModel ?? selectedModel).runtimeProfile
        return RuntimeBudgets.safeHistoryDepth(profile: profile, headroom: availableHeadroomMB)
    }


    public func warmup() async throws {
        // Warmup skipped for E2B.
        //
        // E2B has 26 layers (E4B has 42). Running MLXLMCommon.generate() for the first time
        // triggers Metal JIT shader compilation across all unique kernel variants
        // (attention, MLP, PLE, RoPE ...). This compilation adds a temporary
        // memory spike on top of the already-loaded 4.9 GB weights, which pushes
        // the process past the jetsam limit on iPhone 17 Pro Max.
        //
        // Skipping warmup means the first user inference compiles shaders lazily
        // (first response is ~2-3s slower) but avoids the OOM kill on startup.
        print("[MLX] Warmup skipped — shaders will compile on first inference")
        statusMessage = "模型已就绪 ✅"
    }

    public func generateStream(
        prompt: String,
        images: [CIImage],
        audios: [UserInput.Audio]
    ) -> AsyncThrowingStream<String, Error> {
        let input: UserInput
        if images.isEmpty, audios.isEmpty {
            input = UserInput(prompt: prompt)
        } else {
            input = UserInput(
                chat: [
                    .user(
                        prompt,
                        images: images.map { .ciImage($0) },
                        audios: audios
                    )
                ]
            )
        }
        return generateStream(input: input, isMultimodal: !images.isEmpty || !audios.isEmpty)
    }

    public func generateStream(chat: [Chat.Message]) -> AsyncThrowingStream<String, Error> {
        generateStream(chat: chat, additionalContext: nil)
    }

    public func generateStream(
        chat: [Chat.Message],
        additionalContext: [String: any Sendable]?
    ) -> AsyncThrowingStream<String, Error> {
        let input = UserInput(chat: chat, additionalContext: additionalContext)
        let hasMedia = !input.images.isEmpty || !input.audios.isEmpty
        return generateStream(input: input, isMultimodal: hasMedia)
    }


    private func currentMultimodalFallbackRecommendation() -> String {
        // 默认用户只装一个模型, 不建议"切换到另一个模型" (他可能根本没有)。
        // 给可执行的自救步骤: 关后台、减附件数量/尺寸。
        return "可尝试: 关闭后台应用释放内存; 减少附件数量; 或把图片缩小再试。"
    }


    private func generateStream(
        input: UserInput,
        isMultimodal: Bool
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish(throwing: MLXError.modelNotLoaded)
                    return
                }
                do {
                    try await self.ensureAudioCapability(hasAudio: !input.audios.isEmpty)
                } catch {
                    continuation.finish(throwing: error)
                    return
                }

                guard let container = modelContainer else {
                    continuation.finish(throwing: MLXError.modelNotLoaded)
                    return
                }

                // Free Metal buffers cached from previous inference before
                // allocating the new computation graph. Critical on low-headroom devices:
                // the follow-up prompt is longer than the first inference,
                // and without clearing, residual cache + new activations
                // exceed the 6GB jetsam limit on iPhone.
                //
                // NOTE: No prompt prefix caching is implemented. Every generateStream call
                // rebuilds the full KV cache from scratch. Prompt prefix stability does NOT
                // improve inference latency in the current architecture. Any future proposal
                // to restructure prompts for "cache hit rate" should first implement actual
                // prefix caching before assuming performance gains.
                MLX.GPU.clearCache()

                let currentModel = self.loadedModel ?? self.selectedModel
                let profile = currentModel.runtimeProfile
                let headroom = MemoryStats.headroomMB

                let thinkingEnabled = RuntimeBudgets.isThinkingEnabled(input: input, profile: profile)
                let textBudget = RuntimeBudgets.text(profile: profile, headroom: headroom, enabled: !isMultimodal)
                let runtimeBudget: MultimodalBudget?
                do {
                    runtimeBudget = try RuntimeBudgets.multimodal(
                        profile: profile,
                        headroom: headroom,
                        hasImages: !input.images.isEmpty,
                        hasAudio: !input.audios.isEmpty,
                        modelDisplayName: currentModel.displayName,
                        fallbackRecommendation: "请关闭后台应用后重试，或减少附件数量。\(self.currentMultimodalFallbackRecommendation())"
                    )
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                let thinkingBudget = RuntimeBudgets.thinking(profile: profile, headroom: headroom, enabled: thinkingEnabled)

                if let runtimeBudget {
                    print(
                        "[MEM] multimodal runtime budget — model=\(currentModel.displayName), "
                            + "headroom=\(headroom) MB, "
                            + "imageSoftTokenCap=\(runtimeBudget.imageSoftTokenCap.map(String.init) ?? "n/a"), "
                            + "maxOutputTokens=\(runtimeBudget.maxOutputTokens), "
                            + "audio=\(!input.audios.isEmpty ? 1 : 0)"
                    )
                }
                if let thinkingBudget {
                    print("[MEM] thinking runtime budget — model=\(currentModel.displayName), headroom=\(headroom) MB, maxOutputTokens=\(thinkingBudget.maxOutputTokens)")
                }
                if let textBudget {
                    print("[MEM] text runtime budget — model=\(currentModel.displayName), headroom=\(headroom) MB, maxOutputTokens=\(textBudget.maxOutputTokens)")
                }

                // TODO: 抽出 ModelAdapter 协议后移除 Gemma 专属耦合
                Gemma4Processor.setRuntimeImageSoftTokenCap(runtimeBudget?.imageSoftTokenCap)
                defer {
                    Gemma4Processor.setRuntimeImageSoftTokenCap(nil)
                }
                let effectiveMaxOutputTokens: Int = {
                    let multimodalCap = isMultimodal
                        ? runtimeBudget?.maxOutputTokens ?? profile.multimodalOutputTiers.last?.maxOutputTokens ?? maxOutputTokens
                        : maxOutputTokens
                    let thinkingCap = thinkingBudget?.maxOutputTokens ?? maxOutputTokens
                    let textCap = textBudget?.maxOutputTokens ?? maxOutputTokens
                    return min(maxOutputTokens, multimodalCap, thinkingCap, textCap)
                }()
                var resolvedMaxOutputTokens = effectiveMaxOutputTokens

                self.isGenerating = true
                self.cancelled = false
                let genStart = CFAbsoluteTimeGetCurrent()
                var firstTokenTime: Double? = nil
                var tokenCount = 0
                var hitTokenCap = false

                let (fp, _) = MemoryStats.footprintMB()
                print("[MEM] generateStream start — footprint: \(Int(fp)) MB, MLX active: \(MLX.GPU.activeMemory / 1_048_576) MB")

                do {
                    try await self.ensureForegroundGPUExecution()
                    _ = try await container.perform { context in
                        try await self.ensureForegroundGPUExecution()
                        if isMultimodal {
                            print("[VLM] multimodal budget — maxOutputTokens=\(resolvedMaxOutputTokens)")
                        } else if thinkingEnabled {
                            print("[LLM] thinking budget — baseMaxOutputTokens=\(resolvedMaxOutputTokens)")
                        }
                        let preparedInput = try await context.processor.prepare(input: input)
                        let preparedSequenceLength = preparedInput.text.tokens.dim(1)
                        if isMultimodal {
                            print("[VLM] prepared sequence length=\(preparedSequenceLength)")
                        } else {
                            // 不再基于 prepared 长度二次扣减 output 上限。
                            // chunked prefill 让 prepared 长度对峰值内存几乎无影响,
                            // resolvedMaxOutputTokens 已由 textOutputBudget(headroom)
                            // 决定, 直接使用即可。
                            print(
                                "[LLM] prepared sequence length=\(preparedSequenceLength), "
                                    + "outputCap=\(resolvedMaxOutputTokens)"
                            )
                        }
                        try await self.ensureForegroundGPUExecution()

                        // prefillStepSize: chunked prefill window. 把长 prompt
                        // 切成 256 token / chunk 处理，每个 chunk 跑完调 eval(cache)
                        // 释放 compute graph，单 chunk transient 峰值控制在 ~400 MB
                        // 以内，避免长 prompt（800+ tokens）单次 forward 把 attention
                        // workspace 推过 iPhone 6.1 GB jetsam 上限。
                        //
                        // MLX 默认 512 是为桌面 Apple Silicon 调的；iPhone E4B
                        // (42 layers) 在 512 chunk 下 transient 峰值约 1.7 GB,
                        // 加上 4.6 GB 已驻留 weights+KV 会撞 jetsam。
                        // 这是框架层修复，与 prompt 内容、skill 数量、SKILL.md
                        // 格式完全无关。
                        return try MLXLMCommon.generate(
                            input: preparedInput,
                            parameters: .init(
                                maxTokens: resolvedMaxOutputTokens,
                                temperature: samplingTemperature,
                                topP: samplingTopP,
                                topK: samplingTopK,
                                prefillStepSize: 256
                            ),
                            context: context
                        ) { tokens in
                            if self.cancelled || !self.isForegroundGPUAllowed() {
                                return .stop
                            }

                            tokenCount = tokens.count
                            if firstTokenTime == nil {
                                firstTokenTime = (CFAbsoluteTimeGetCurrent() - genStart) * 1000
                            }

                            // Stream the latest token
                            if let lastToken = tokens.last {
                                let text = context.tokenizer.decode(tokenIds: [lastToken])
                                continuation.yield(text)
                            }

                            // Multimodal path uses a tighter generation budget on iPhone.
                            // If we hit the cap, signal truncation so the caller can append a notice.
                            if tokens.count >= resolvedMaxOutputTokens {
                                hitTokenCap = true
                                return .stop
                            }
                            return .more
                        }
                    }

                    let elapsed = CFAbsoluteTimeGetCurrent() - genStart
                    self.stats.ttftMs = firstTokenTime ?? 0
                    self.stats.tokensPerSec = elapsed > 0
                        ? Double(tokenCount) / elapsed : 0
                    self.stats.totalTokens = tokenCount

                    print(
                        "[MLX] Generated \(tokenCount) tokens in \(String(format: "%.1f", elapsed))s"
                    )
                    print(
                        "[MLX] TTFT: \(String(format: "%.0f", self.stats.ttftMs))ms, "
                            + "Speed: \(String(format: "%.1f", self.stats.tokensPerSec)) tok/s")

                    // 推理结束后立即释放 Metal activation 缓存，
                    // 确保下一轮有最大可用 headroom。
                    MLX.GPU.clearCache()
                    let (fpEnd, _) = MemoryStats.footprintMB()
                    print("[MEM] generateStream end  — footprint: \(Int(fpEnd)) MB, headroom: \(self.availableHeadroomMB) MB")

                    // If we hit the token cap mid-sentence, append a visible notice.
                    // This makes truncation explicit rather than silently dropping content.
                    if hitTokenCap {
                        let isChinese = Locale.preferredLanguages.contains { $0.hasPrefix("zh") }
                        let modeLabel = isChinese
                            ? (thinkingEnabled ? "思考" : "输出")
                            : (thinkingEnabled ? "Thinking" : "Output")
                        continuation.yield("\n\n> ⚠️ \(modeLabel)已达单次输出上限（\(resolvedMaxOutputTokens) tokens），内容可能不完整。")
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }

                self.isGenerating = false
                self.currentGenerationTask = nil
            }

            currentGenerationTask = task
            continuation.onTermination = { [weak self] _ in
                task.cancel()
                if self?.currentGenerationTask?.isCancelled == true {
                    self?.currentGenerationTask = nil
                }
            }
        }
    }

    public func cancel() {
        cancelled = true
        currentGenerationTask?.cancel()
        currentLoadTask?.cancel()
    }

    public func prepareForReload(
        cancelCurrentGeneration: Bool = true,
        cancelCurrentLoad: Bool = true
    ) async {
        cancelled = true
        if cancelCurrentGeneration {
            currentGenerationTask?.cancel()
        }
        if cancelCurrentLoad {
            currentLoadTask?.cancel()
        }

        while isGenerating || isLoading {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        unload(
            cancelCurrentGeneration: cancelCurrentGeneration,
            cancelCurrentLoad: cancelCurrentLoad
        )
        MLX.GPU.clearCache()
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    public func unload() {
        unload(cancelCurrentGeneration: true, cancelCurrentLoad: true)
    }

    public func unload(
        cancelCurrentGeneration: Bool = true,
        cancelCurrentLoad: Bool = true
    ) {
        if cancelCurrentGeneration {
            currentGenerationTask?.cancel()
        }
        if cancelCurrentLoad {
            currentLoadTask?.cancel()
        }
        modelContainer = nil
        isLoaded = false
        isLoading = false
        isGenerating = false
        loadedModel = nil
        cancelled = false
        stats = LLMStats()
        stats.backend = "mlx-gpu"
        MLX.GPU.clearCache()
        statusMessage = "模型已卸载"
        print("[MLX] Model unloaded")
    }
}


import Foundation
import CoreImage
import LiteRTLMSwift

// MARK: - LiteRT Backend
//
// InferenceService conformer，内部持有 LiteRTLMEngine。
// CPU-only，无 GPU 分支。
//
// 推理路径:
//   - 纯文本: persistent Session API → sessionGenerateStreaming()
//   - 多模态 (图/音): Conversation API → conversationSend()
//   - Raw text (Live): Session API with raw turn markers
//
// 模型管理 (load/unload/select) 在这里实现。
// 资产管理 (download/install/path) 在 LiteRTModelStore 里。

@Observable
final class LiteRTBackend: InferenceService {

    // MARK: - State

    private(set) var isLoaded = false
    private(set) var isLoading = false
    private(set) var isGenerating = false
    var statusMessage = "等待加载模型..."
    private(set) var stats = InferenceStats()

    // MARK: - Sampling Config

    var samplingTopK: Int = 40
    var samplingTopP: Float = 0.95
    var samplingTemperature: Float = 1.0
    var maxOutputTokens: Int = 4000

    // MARK: - Internal

    private var engine: LiteRTLMEngine?
    private var loadedModelID: String?
    private var cancelled = false

    /// 模型文件路径解析 — 由外部 (ModelInstaller) 提供
    private let modelPathResolver: (String) -> URL?

    // MARK: - Init

    /// - Parameter modelPathResolver: 给定 modelID 返回 .litertlm 文件的 URL (nil = 未安装)
    init(modelPathResolver: @escaping (String) -> URL?) {
        self.modelPathResolver = modelPathResolver
        self.stats.backend = "litert-cpu"
    }

    /// 便捷 init: 使用默认路径 (Documents/models/<fileName>)
    convenience init() {
        self.init { modelID in
            guard let descriptor = ModelDescriptor.allModels.first(where: { $0.id == modelID }) else {
                return nil
            }
            let modelsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                .appendingPathComponent("models", isDirectory: true)
            let path = modelsDir.appendingPathComponent(descriptor.fileName)
            return FileManager.default.fileExists(atPath: path.path) ? path : nil
        }
    }

    // MARK: - InferenceService: Lifecycle

    func load(modelID: String) async throws {
        guard !isLoading else { return }

        // 已加载同一模型 — no-op
        if isLoaded, loadedModelID == modelID { return }

        // 如果加载了不同模型，先卸载
        if isLoaded { unload() }

        guard let modelPath = modelPathResolver(modelID) else {
            let descriptor = ModelDescriptor.allModels.first { $0.id == modelID }
            let name = descriptor?.displayName ?? modelID
            statusMessage = "请先在配置中下载 \(name) 模型"
            throw ModelBackendError.modelFileMissing(name)
        }

        isLoading = true
        statusMessage = "正在加载模型..."
        cancelled = false

        let loadStart = CFAbsoluteTimeGetCurrent()

        do {
            let newEngine = LiteRTLMEngine(modelPath: modelPath, backend: "cpu")
            try await newEngine.load()

            // 打开 persistent session (KV cache 复用)
            try await newEngine.openSession(
                temperature: samplingTemperature,
                maxTokens: maxOutputTokens
            )

            self.engine = newEngine
            self.loadedModelID = modelID
            self.isLoaded = true
            self.isLoading = false

            let elapsed = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000
            self.stats.loadTimeMs = elapsed

            let descriptor = ModelDescriptor.allModels.first { $0.id == modelID }
            statusMessage = "已加载 \(descriptor?.displayName ?? modelID)"
            print("[LiteRT] Model loaded in \(String(format: "%.0f", elapsed))ms")
        } catch {
            isLoading = false
            isLoaded = false
            statusMessage = "❌ \(error.localizedDescription)"
            print("[LiteRT] Load failed: \(error.localizedDescription)")
            throw error
        }
    }

    func unload() {
        engine?.closeSession()
        engine?.closeConversation()
        Task { @MainActor in
            engine?.unload()
        }
        engine = nil
        loadedModelID = nil
        isLoaded = false
        isGenerating = false
        statusMessage = "等待加载模型..."
    }

    func cancel() {
        cancelled = true
        // Session API 没有显式 cancel — 通过 cancelled 标志在 stream 消费侧中断。
        // Conversation API 有 cancelConversation() — 未来补。
    }

    // MARK: - InferenceService: Text Generation

    func generate(prompt: String) -> AsyncThrowingStream<String, Error> {
        guard let engine, isLoaded else {
            return AsyncThrowingStream { $0.finish(throwing: ModelBackendError.modelNotLoaded) }
        }

        isGenerating = true
        cancelled = false
        let startTime = CFAbsoluteTimeGetCurrent()

        return AsyncThrowingStream { [weak self] continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                var tokenCount = 0
                var firstTokenTime: Double?

                do {
                    for try await token in engine.sessionGenerateStreaming(input: prompt) {
                        if self.cancelled {
                            continuation.finish()
                            break
                        }
                        tokenCount += 1
                        if firstTokenTime == nil {
                            firstTokenTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                        }
                        continuation.yield(token)
                    }
                    if !self.cancelled {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isGenerating = false
                    if let ttft = firstTokenTime {
                        self.stats.ttftMs = ttft
                    }
                    self.stats.totalTokens = tokenCount
                    let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                    if elapsed > 0, tokenCount > 0 {
                        self.stats.tokensPerSec = Double(tokenCount) / elapsed
                    }
                }
            }
        }
    }

    // MARK: - InferenceService: Multimodal Generation

    func generateMultimodal(
        images: [CIImage],
        audios: [AudioInput],
        prompt: String,
        systemPrompt: String
    ) -> AsyncThrowingStream<String, Error> {
        guard let engine, isLoaded else {
            return AsyncThrowingStream { $0.finish(throwing: ModelBackendError.modelNotLoaded) }
        }

        isGenerating = true
        cancelled = false

        return AsyncThrowingStream { [weak self] continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                do {
                    // 把 CIImage 转 JPEG Data
                    var imagesData: [Data] = []
                    for ciImage in images {
                        if let data = self.ciImageToJPEG(ciImage) {
                            imagesData.append(data)
                        }
                    }

                    // 把 AudioInput 转 WAV Data
                    var audiosData: [Data] = []
                    for audio in audios {
                        let wavData = ChatAudioAttachment.makeWAVData(
                            pcm: audio.samples,
                            sampleRate: audio.sampleRate,
                            channelCount: audio.channelCount
                        )
                        audiosData.append(wavData)
                    }

                    // 走 Conversation API (非流式，当前 LiteRTLMEngine 没有封装 conversation stream)
                    // TODO: 补 conversationSendStreaming 后改为流式
                    let result = try await engine.multimodal(
                        audioData: audiosData,
                        imagesData: imagesData,
                        prompt: prompt
                    )

                    if !self.cancelled {
                        continuation.yield(result)
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }

                await MainActor.run { [weak self] in
                    self?.isGenerating = false
                }
            }
        }
    }

    // MARK: - InferenceService: Raw Text (Live)

    func generateRaw(text: String, images: [CIImage]) -> AsyncThrowingStream<String, Error> {
        if images.isEmpty {
            // 纯文本: 走 Session API，raw text 原样编码
            return generate(prompt: text)
        } else {
            // 有图: 走 Conversation API
            return generateMultimodal(
                images: images,
                audios: [],
                prompt: text,
                systemPrompt: ""
            )
        }
    }

    // MARK: - Private Helpers

    private func ciImageToJPEG(_ ciImage: CIImage, maxDimension: Int = 1024) -> Data? {
        let context = CIContext()
        let extent = ciImage.extent

        // 缩放到 maxDimension
        let scale: CGFloat
        let longestSide = max(extent.width, extent.height)
        if longestSide > CGFloat(maxDimension) {
            scale = CGFloat(maxDimension) / longestSide
        } else {
            scale = 1.0
        }

        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        return context.jpegRepresentation(
            of: scaledImage,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8]
        )
    }
}

// MARK: - Backend Error

enum ModelBackendError: LocalizedError {
    case modelNotLoaded
    case modelFileMissing(String)
    case memoryRisk(model: String, headroomMB: Int, recommendation: String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "模型未加载，请先在配置页下载并加载模型。"
        case .modelFileMissing(let name):
            return "\(name) 模型文件不存在，请先在配置页下载。"
        case .memoryRisk(let model, let headroomMB, let recommendation):
            return "\(model) 当前剩余内存仅约 \(headroomMB) MB。\(recommendation)"
        }
    }
}

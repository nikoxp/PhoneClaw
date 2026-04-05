# 如何把 Gemma 4 E4B 封装成 iOS App 在 iPhone 上运行

## 实操指南 — 从零到跑通

---

## 一、当前可用的方案

| 方案 | 推理引擎 | 模型格式 | iOS 支持 | Function Calling |
|------|---------|---------|---------|-----------------|
| **MediaPipe LLM Inference** | MediaPipe | `.bin` / `.task` | ✅ CocoaPods | ❌ 仅 Android |
| **LiteRT-LM** | LiteRT-LM | `.litertlm` | ⚠️ C++ API (Swift Coming Soon) | ✅ 内置 |
| **MediaPipe + 手动解析** | MediaPipe | `.bin` | ✅ CocoaPods | ✅ 自己做 |

### 推荐方案：MediaPipe LLM Inference API + 手动 Function Calling 解析

**理由**：
- CocoaPods 一行命令集成，不需要编译 C++ 库
- 有官方 iOS 示例代码
- E4B 模型本身支持 function calling 输出格式，我们只需要解析它的输出

---

## 二、环境准备

### 前提条件
```
✅ Mac (你有 M3 Max)
✅ Xcode (App Store 安装)
✅ CocoaPods >= 1.12.1
✅ 物理 iPhone (iOS 17+)
✅ Apple Developer 账号 (免费即可，但 7 天过期)
```

### 安装 CocoaPods（如果还没有）
```bash
sudo gem install cocoapods
```

---

## 三、创建 Xcode 项目

### Step 1：新建项目
```
1. 打开 Xcode
2. File → New → Project
3. 选择 iOS → App
4. 配置：
   - Product Name: PhoneClaw
   - Interface: SwiftUI
   - Language: Swift
   - 保存到: ./
```

### Step 2：添加 CocoaPods 依赖
```bash
cd ./

# 初始化 Podfile
pod init
```

编辑 `Podfile`：
```ruby
platform :ios, '17.0'

target 'PhoneClaw' do
  use_frameworks!
  
  # MediaPipe LLM 推理引擎
  pod 'MediaPipeTasksGenAI'
  pod 'MediaPipeTasksGenAIC'
end
```

安装依赖：
```bash
pod install
```

⚠️ **此后必须打开 `PhoneClaw.xcworkspace`（不是 .xcodeproj）**

### Step 3：添加内存权限
在 Xcode 中，给 target 添加 Entitlement:
```
com.apple.developer.kernel.increased-memory-limit = true
```
这允许 App 使用更多内存（E4B 约需 3.6GB）

---

## 四、下载 E4B 模型

### 方式 A：从 Kaggle 下载（推荐）
```
1. 访问 https://www.kaggle.com/models/google/gemma-4
2. 找到 "Gemma 4 E4B" 的 MediaPipe 格式（.bin 或 .task）
3. 下载量化版本（int4/int8）
```

### 方式 B：从 Hugging Face 下载
```bash
# litert-community 提供预转换模型
# 访问 https://huggingface.co/litert-community
# 搜索 gemma-4-E4B
```

### 放入项目
```
1. 将下载的模型文件（如 gemma-4-e4b-it-int4.bin）拖入 Xcode 项目
2. 确保勾选 "Copy items if needed"
3. 确保在 Build Phases → Copy Bundle Resources 中包含该文件
```

---

## 五、核心代码

### 5.1 LLM 推理服务
```swift
// LocalLLMService.swift
import Foundation
import MediaPipeTasksGenai

class LocalLLMService {
    private var llmInference: LlmInference?
    var isLoaded = false
    
    /// 加载模型
    func loadModel() throws {
        guard let modelPath = Bundle.main.path(
            forResource: "gemma-4-e4b-it-int4",  // 你的模型文件名
            ofType: "bin"
        ) else {
            throw NSError(domain: "LLM", code: 1, 
                         userInfo: [NSLocalizedDescriptionKey: "找不到模型文件"])
        }
        
        let options = LlmInferenceOptions()
        options.baseOptions.modelPath = modelPath
        options.maxTokens = 2048
        options.topk = 40
        options.temperature = 0.7
        options.randomSeed = 42
        
        llmInference = try LlmInference(options: options)
        isLoaded = true
        print("[LLM] 模型加载完成")
    }
    
    /// 同步生成（简单场景）
    func generate(prompt: String) throws -> String {
        guard let llm = llmInference else {
            throw NSError(domain: "LLM", code: 2, 
                         userInfo: [NSLocalizedDescriptionKey: "模型未加载"])
        }
        return try llm.generateResponse(inputText: prompt)
    }
    
    /// 流式生成（推荐，响应更快）
    func generateStream(prompt: String) -> AsyncThrowingStream<String, Error> {
        guard let llm = llmInference else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: NSError(domain: "LLM", code: 2, 
                    userInfo: [NSLocalizedDescriptionKey: "模型未加载"]))
            }
        }
        return llm.generateResponseAsync(inputText: prompt)
    }
}
```

### 5.2 构造 Prompt（含 Function Calling 指令）
```swift
// PromptBuilder.swift
import Foundation

struct PromptBuilder {
    
    /// 构造包含 Skill 定义的完整 Prompt
    static func build(
        userMessage: String,
        availableTools: [ToolDefinition],
        history: [ChatMessage] = []
    ) -> String {
        var prompt = """
        <start_of_turn>system
        你是 PhoneClaw，一个运行在 iPhone 上的私人 AI 助手。

        你可以调用以下工具来访问 iPhone 的功能：

        """
        
        // 添加工具定义
        for tool in availableTools {
            prompt += """
            工具名称: \(tool.name)
            描述: \(tool.description)
            参数: \(tool.parametersDescription)
            
            """
        }
        
        prompt += """
        
        当需要使用工具时，用以下格式回复：
        <tool_call>
        {"name": "工具名", "arguments": {参数}}
        </tool_call>
        
        如果不需要工具，直接回复。用中文回答。
        <end_of_turn>
        """
        
        // 添加历史对话
        for msg in history {
            if msg.role == .user {
                prompt += "\n<start_of_turn>user\n\(msg.content)<end_of_turn>"
            } else {
                prompt += "\n<start_of_turn>model\n\(msg.content)<end_of_turn>"
            }
        }
        
        // 添加当前用户消息
        prompt += "\n<start_of_turn>user\n\(userMessage)<end_of_turn>"
        prompt += "\n<start_of_turn>model\n"
        
        return prompt
    }
}

struct ToolDefinition {
    let name: String
    let description: String
    let parametersDescription: String
}
```

### 5.3 Skill 协议 + 剪贴板 Skill
```swift
// AgentSkill.swift
import UIKit

protocol AgentSkill {
    var name: String { get }
    var description: String { get }
    var parametersDescription: String { get }
    func execute(args: [String: Any]) async throws -> String
}

// ClipboardSkill.swift
struct ClipboardReadSkill: AgentSkill {
    let name = "clipboard_read"
    let description = "读取 iPhone 剪贴板内容"
    let parametersDescription = "无参数"
    
    func execute(args: [String: Any]) async throws -> String {
        let content: String? = await MainActor.run {
            UIPasteboard.general.string
        }
        if let text = content, !text.isEmpty {
            return "{\"success\": true, \"content\": \"\(text)\"}"
        }
        return "{\"success\": false, \"error\": \"剪贴板为空\"}"
    }
}

struct ClipboardWriteSkill: AgentSkill {
    let name = "clipboard_write"
    let description = "写入文本到剪贴板"
    let parametersDescription = "text: 要复制的文本"
    
    func execute(args: [String: Any]) async throws -> String {
        guard let text = args["text"] as? String else {
            return "{\"success\": false, \"error\": \"缺少 text 参数\"}"
        }
        await MainActor.run {
            UIPasteboard.general.string = text
        }
        return "{\"success\": true, \"copied\": true}"
    }
}
```

### 5.4 Agent Engine（核心循环）
```swift
// AgentEngine.swift
import Foundation

@Observable
class AgentEngine {
    let llm = LocalLLMService()
    var messages: [ChatMessage] = []
    var isProcessing = false
    
    // 注册的 Skills
    let skills: [AgentSkill] = [
        ClipboardReadSkill(),
        ClipboardWriteSkill(),
    ]
    
    // 工具定义（给 prompt 用）
    var toolDefinitions: [ToolDefinition] {
        skills.map { ToolDefinition(
            name: $0.name,
            description: $0.description,
            parametersDescription: $0.parametersDescription
        )}
    }
    
    func setup() {
        do {
            try llm.loadModel()
        } catch {
            print("模型加载失败: \(error)")
        }
    }
    
    func processInput(_ text: String) async {
        messages.append(ChatMessage(role: .user, content: text))
        isProcessing = true
        defer { isProcessing = false }
        
        do {
            // 构造 prompt
            let prompt = PromptBuilder.build(
                userMessage: text,
                availableTools: toolDefinitions,
                history: Array(messages.suffix(10))
            )
            
            // LLM 推理
            let response = try llm.generate(prompt: prompt)
            
            // 检查是否有 tool_call
            if let call = parseToolCall(response) {
                // 找到对应 Skill 并执行
                if let skill = skills.first(where: { $0.name == call.name }) {
                    let result = try await skill.execute(args: call.arguments)
                    
                    // 把结果发回 LLM 生成最终回复
                    let followUp = prompt + response + """
                    
                    <start_of_turn>user
                    工具执行结果: \(result)
                    请根据结果回复。
                    <end_of_turn>
                    <start_of_turn>model
                    
                    """
                    let finalResponse = try llm.generate(prompt: followUp)
                    messages.append(ChatMessage(role: .assistant, content: finalResponse))
                }
            } else {
                messages.append(ChatMessage(role: .assistant, content: response))
            }
        } catch {
            messages.append(ChatMessage(role: .assistant, content: "❌ 错误: \(error)"))
        }
    }
    
    // 解析 <tool_call>JSON</tool_call>
    private func parseToolCall(_ text: String) -> (name: String, arguments: [String: Any])? {
        guard let regex = try? NSRegularExpression(
            pattern: "<tool_call>\\s*(\\{.*?\\})\\s*</tool_call>",
            options: .dotMatchesLineSeparators
        ) else { return nil }
        
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let jsonRange = Range(match.range(at: 1), in: text) else { return nil }
        
        let json = String(text[jsonRange])
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = dict["name"] as? String else { return nil }
        
        return (name, dict["arguments"] as? [String: Any] ?? [:])
    }
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: Role
    let content: String
    enum Role { case user, assistant, system }
}
```

---

## 六、部署到 iPhone

### Step 1：连接 iPhone
```
1. USB 连接 iPhone 到 Mac
2. iPhone 上信任此电脑
3. 如首次开发：iPhone → 设置 → 隐私与安全 → 开发者模式 → 打开
```

### Step 2：Xcode 签名配置
```
1. Xcode → PhoneClaw target → Signing & Capabilities
2. Team: 选择你的 Apple ID
3. Bundle Identifier: 改为唯一名称（如 com.youname.phoneclaw）
```

### Step 3：编译运行
```
1. Xcode 顶部选择你的 iPhone 作为运行目标
2. Command + R 编译运行
3. 首次运行会在 iPhone 上弹出"不受信任的开发者"
   → 设置 → 通用 → VPN与设备管理 → 信任你的证书
```

---

## 七、mediapipe-samples 官方示例（参考）

如果想先跑通官方 demo：
```bash
git clone https://github.com/google-ai-edge/mediapipe-samples.git
cd mediapipe-samples/examples/llm_inference/ios
pod install
open LlmInference.xcworkspace
# 下载模型放入项目，然后 Command+R 运行
```

---

## 八、关键注意事项

### 内存
- E4B 模型约 3.6GB，需要 iPhone 15 Pro 或以上（6GB RAM+）
- 必须添加 `increased-memory-limit` entitlement
- 如果内存不够，先用 E2B（2.5GB）验证

### 模型格式
- MediaPipe iOS 需要 `.bin` 或 `.task` 格式
- `.litertlm` 格式目前仅 LiteRT-LM 原生支持（iOS Swift API 尚未发布）
- 确认从 Kaggle/HF 下载的是 MediaPipe 兼容格式

### Function Calling
- E4B 本身训练时支持 function calling（Gemma 4 特性）
- 但 MediaPipe iOS API 没有封装 function calling 层
- 我们通过 prompt engineering + 输出解析 自己实现
- 这和 Gallery App 的 Agent Skills 功能原理相同

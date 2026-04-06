import Foundation
import Yams

// MARK: - SKILL.md 解析器 + 加载器
//
// 参考 Vera 项目的 skill_loader.py，实现 Swift 版。
// 渐进式加载：
//   1. 启动时：只加载 YAML frontmatter（元数据）
//   2. load_skill 时：加载完整 body（指令体）

// MARK: - 数据模型

struct SkillExample {
    let query: String
    let scenario: String
}

struct SkillMetadata {
    let id: String              // 目录名 "clipboard"
    let name: String            // 默认英文名 / 回退显示名
    let localizedNameZh: String?
    let description: String
    let version: String
    let icon: String
    let disabled: Bool
    let triggers: [String]
    let allowedTools: [String]
    let examples: [SkillExample]

    var displayName: String {
        if Locale.preferredLanguages.contains(where: { $0.lowercased().hasPrefix("zh") }),
           let localizedNameZh,
           !localizedNameZh.isEmpty {
            return localizedNameZh
        }
        return name
    }
}

struct SkillDefinition: Identifiable {
    let id: String
    let filePath: URL
    let metadata: SkillMetadata
    var body: String?           // Markdown body（懒加载）
    var isEnabled: Bool

    /// 完整的 SKILL.md 原始内容
    var rawContent: String? {
        try? String(contentsOf: filePath, encoding: .utf8)
    }
}

// MARK: - Skill Loader

class SkillLoader {
    private static let skillAliases: [String: String] = [
        "contacts_delete": "contacts",
        "contacts-delete": "contacts"
    ]

    let skillsDirectory: URL
    private var cache: [String: SkillDefinition] = [:]

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.skillsDirectory = appSupport.appendingPathComponent("PhoneClaw/skills", isDirectory: true)
        ensureDefaultSkills()
    }

    // MARK: - 公开接口

    /// 发现并加载所有 Skill 的元数据
    func discoverSkills() -> [SkillDefinition] {
        cache.removeAll()
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: skillsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        var results: [SkillDefinition] = []
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir)
            guard isDir.boolValue else { continue }

            let skillFile = item.appendingPathComponent("SKILL.md")
            guard FileManager.default.fileExists(atPath: skillFile.path) else { continue }

            let skillId = item.lastPathComponent
            if Self.skillAliases[skillId] != nil {
                continue
            }
            if let def = loadDefinition(skillId: skillId, file: skillFile) {
                cache[skillId] = def
                results.append(def)
            }
        }
        return results
    }

    /// 完整加载 Skill（包括 body）— load_skill 时调用
    func loadBody(skillId: String) -> String? {
        let resolvedSkillId = canonicalSkillId(for: skillId)
        if let cached = cache[resolvedSkillId], cached.body != nil {
            return cached.body
        }
        let skillFile = skillsDirectory
            .appendingPathComponent(resolvedSkillId, isDirectory: true)
            .appendingPathComponent("SKILL.md")

        guard let content = try? String(contentsOf: skillFile, encoding: .utf8) else { return nil }
        let body = parseBody(content)
        cache[resolvedSkillId]?.body = body
        return body
    }

    /// 保存 SKILL.md（编辑后写回）
    func saveSkill(skillId: String, content: String) throws {
        let skillFile = skillsDirectory
            .appendingPathComponent(skillId, isDirectory: true)
            .appendingPathComponent("SKILL.md")
        try content.write(to: skillFile, atomically: true, encoding: .utf8)
        // 清缓存，下次重新解析
        cache.removeValue(forKey: skillId)
    }

    /// 重新加载所有（热更新入口）
    func reloadAll() -> [SkillDefinition] {
        return discoverSkills()
    }

    /// 根据工具名反查 Skill ID
    func findSkillId(forTool toolName: String) -> String? {
        for (id, def) in cache {
            if def.metadata.allowedTools.contains(toolName) {
                return id
            }
        }
        return nil
    }

    /// 获取缓存的 SkillDefinition
    func getDefinition(_ skillId: String) -> SkillDefinition? {
        cache[canonicalSkillId(for: skillId)]
    }

    /// 更新启用状态
    func setEnabled(_ skillId: String, enabled: Bool) {
        cache[canonicalSkillId(for: skillId)]?.isEnabled = enabled
    }

    func canonicalSkillId(for skillId: String) -> String {
        Self.skillAliases[skillId] ?? skillId
    }

    // MARK: - 解析

    private func loadDefinition(skillId: String, file: URL) -> SkillDefinition? {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        guard let frontmatter = parseFrontmatter(content) else { return nil }

        let metadata = SkillMetadata(
            id: skillId,
            name: frontmatter["name"] as? String ?? skillId,
            localizedNameZh: frontmatter["name-zh"] as? String,
            description: frontmatter["description"] as? String ?? "",
            version: frontmatter["version"] as? String ?? "1.0.0",
            icon: frontmatter["icon"] as? String ?? "wrench",
            disabled: frontmatter["disabled"] as? Bool ?? false,
            triggers: frontmatter["triggers"] as? [String] ?? [],
            allowedTools: frontmatter["allowed-tools"] as? [String] ?? [],
            examples: parseExamples(frontmatter["examples"])
        )

        return SkillDefinition(
            id: skillId,
            filePath: file,
            metadata: metadata,
            body: nil, // 懒加载
            isEnabled: !metadata.disabled
        )
    }

    private func parseFrontmatter(_ content: String) -> [String: Any]? {
        // 匹配 --- ... --- 包裹的 YAML
        guard let regex = try? NSRegularExpression(
            pattern: "^---\\s*\\n(.*?)\\n---\\s*\\n",
            options: .dotMatchesLineSeparators
        ) else { return nil }

        let range = NSRange(content.startIndex..., in: content)
        guard let match = regex.firstMatch(in: content, range: range),
              let yamlRange = Range(match.range(at: 1), in: content) else { return nil }

        let yamlString = String(content[yamlRange])
        // 用 Yams 解析
        guard let parsed = try? Yams.load(yaml: yamlString) as? [String: Any] else { return nil }
        return parsed
    }

    private func parseBody(_ content: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "^---\\s*\\n.*?\\n---\\s*\\n(.*)$",
            options: .dotMatchesLineSeparators
        ) else { return content }

        let range = NSRange(content.startIndex..., in: content)
        if let match = regex.firstMatch(in: content, range: range),
           let bodyRange = Range(match.range(at: 1), in: content) {
            return String(content[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseExamples(_ raw: Any?) -> [SkillExample] {
        guard let list = raw as? [[String: Any]] else { return [] }
        return list.compactMap { dict in
            guard let query = dict["query"] as? String,
                  let scenario = dict["scenario"] as? String else { return nil }
            return SkillExample(query: query, scenario: scenario)
        }
    }

    // MARK: - 首次启动：写入默认 Skill

    private func ensureDefaultSkills() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: skillsDirectory.path) {
            try? fm.createDirectory(at: skillsDirectory, withIntermediateDirectories: true)
        }

        for (dirName, content) in Self.defaultSkills {
            let dir = skillsDirectory.appendingPathComponent(dirName, isDirectory: true)
            let file = dir.appendingPathComponent("SKILL.md")
            let normalized = content.hasSuffix("\n") ? content : content + "\n"
            let current = try? String(contentsOf: file, encoding: .utf8)
            if current == normalized { continue }
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? normalized.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - 内置默认 SKILL.md

    static let defaultSkills: [(String, String)] = [
        ("clipboard", """
        ---
        name: Clipboard
        name-zh: 剪贴板
        description: '读写系统剪贴板内容。当用户需要读取、复制或操作剪贴板时使用。'
        version: "1.0.0"
        icon: doc.on.clipboard
        disabled: false

        triggers:
          - 剪贴板
          - 粘贴
          - 复制
          - clipboard

        allowed-tools:
          - clipboard-read
          - clipboard-write

        examples:
          - query: "读取我的剪贴板内容"
            scenario: "读取剪贴板"
          - query: "把这段文字复制到剪贴板"
            scenario: "写入剪贴板"
        ---

        # 剪贴板操作

        你负责帮助用户读写系统剪贴板。

        ## 可用工具

        - **clipboard-read**: 读取剪贴板当前内容（无参数）
        - **clipboard-write**: 将文本写入剪贴板（参数: text — 要复制的文本）

        ## 执行流程

        1. 用户要求读取 → 调用 `clipboard-read`
        2. 用户要求复制/写入 → 调用 `clipboard-write`，传入 text 参数
        3. 根据工具返回结果，简洁回答用户

        ## 调用格式

        <tool_call>
        {"name": "工具名", "arguments": {}}
        </tool_call>
        """),

        ("device", """
        ---
        name: Device
        name-zh: 设备
        description: '使用 iOS 官方公开 API 查询当前设备名称、设备类型、系统版本、内存和处理器数量。'
        version: "1.0.0"
        icon: desktopcomputer
        disabled: false

        triggers:
          - 设备
          - 系统信息
          - 当前设备
          - 本机

        allowed-tools:
          - device-info
          - device-name
          - device-model
          - device-system-version
          - device-memory
          - device-processor-count
          - device-identifier-for-vendor

        examples:
          - query: "这台手机的设备信息是什么"
            scenario: "查看官方设备信息汇总"
          - query: "系统版本是多少"
            scenario: "查看系统版本"
          - query: "这台设备叫什么名字"
            scenario: "查看设备名称"
          - query: "内存多大"
            scenario: "查看物理内存"
          - query: "处理器核心数是多少"
            scenario: "查看处理器数量"
        ---

        # 设备信息查询

        你负责帮助用户查看当前这台设备的系统与硬件基础信息。

        ## 可用工具

        - **device-info**: 汇总查询当前设备名称、设备类型、系统版本、物理内存、处理器数量
        - **device-name**: 查询当前设备名称
        - **device-model**: 查询当前设备类型（官方 `UIDevice.model` / `localizedModel`）
        - **device-system-version**: 查询系统名称和系统版本
        - **device-memory**: 查询物理内存大小
        - **device-processor-count**: 查询处理器核心数
        - **device-identifier-for-vendor**: 查询当前 App 的 `identifierForVendor`

        ## 执行流程

        1. 只有当用户明确询问当前设备、本机、手机、系统版本、内存、处理器等信息时，才调用这些工具
        2. 如果用户只是泛泛提到“配置”或“信息”，但没有明确在问当前设备，不要调用这个工具
        3. 能用单个专用工具回答时，优先使用最小 sufficient 的那个工具；只有用户想要整体参数时，才调用 `device-info`
        4. 工具返回后，直接把 JSON 转成用户友好的中文描述
        5. 这些工具只使用 iOS 官方公开 API，不要自行映射成具体营销机型名
        6. 如果用户问“手机型号”，要如实说明官方 API 只能返回通用设备类型，例如 `iPhone`
        7. 如果工具结果已经足够，直接回答，不要反问用户“你指的是什么配置”

        ## 调用格式

        <tool_call>
        {"name": "device-info", "arguments": {}}
        </tool_call>
        """),

        ("text", """
        ---
        name: Text
        name-zh: 文本
        description: '文本处理工具：哈希计算、翻转等。当用户需要对文本进行处理或转换时使用。'
        version: "1.0.0"
        icon: textformat
        disabled: false

        triggers:
          - 哈希
          - hash
          - 翻转
          - 反转
          - 文本处理

        allowed-tools:
          - calculate-hash
          - text-reverse

        examples:
          - query: "计算 Hello World 的哈希值"
            scenario: "哈希计算"
          - query: "把这段文字翻转过来"
            scenario: "文本翻转"
        ---

        # 文本处理

        你负责帮助用户进行文本处理操作。

        ## 可用工具

        - **calculate-hash**: 计算文本的哈希值（参数: text — 要计算哈希的文本）
        - **text-reverse**: 翻转文本（参数: text — 要翻转的文本）

        ## 执行流程

        1. 判断用户需要哪种文本操作
        2. 调用对应工具，传入 text 参数
        3. 返回处理结果

        ## 调用格式

        <tool_call>
        {"name": "工具名", "arguments": {"text": "要处理的文本"}}
        </tool_call>
        """),

        ("calendar", """
        ---
        name: Calendar
        name-zh: 日历
        description: '创建新的日历事项。当用户需要安排日程、会议、约会或写入日历时使用。'
        version: "1.0.0"
        icon: calendar
        disabled: false

        triggers:
          - 日历
          - 日程
          - 会议
          - 约会
          - 安排

        allowed-tools:
          - calendar-create-event

        examples:
          - query: "帮我创建一个明天下午两点的会议"
            scenario: "新建日历事项"
        ---

        # 日历事项创建

        你负责帮助用户创建新的日历事项。

        ## 可用工具

        - **calendar-create-event**: 创建日历事项
          - `title`: 必填，事项标题
          - `start`: 必填，ISO 8601 开始时间，例如 `2026-04-07T14:00:00`
          - `end`: 可选，ISO 8601 结束时间；不传时默认开始后一小时
          - `location`: 可选，地点
          - `notes`: 可选，备注

        ## 执行流程

        1. 只有当用户明确要新建/安排日历事项时才调用工具
        2. 由你从用户话语中提取参数，工具层不做自然语言解析
        3. 传给工具前，必须把时间整理成 ISO 8601 字符串
        4. 如果缺少 `title` 或 `start`，先简短追问，不要猜测
        5. 工具成功后，直接告诉用户已创建什么事项和时间

        ## 调用格式

        <tool_call>
        {"name": "calendar-create-event", "arguments": {"title": "会议", "start": "2026-04-07T14:00:00"}}
        </tool_call>
        """),

        ("reminders", """
        ---
        name: Reminders
        name-zh: 提醒事项
        description: '创建新的提醒事项。当用户需要记得做某事、设置待办或提醒时使用。'
        version: "1.0.0"
        icon: bell
        disabled: false

        triggers:
          - 提醒
          - 待办
          - 记得
          - 提示

        allowed-tools:
          - reminders-create

        examples:
          - query: "提醒我今晚八点发文件"
            scenario: "新建提醒事项"
        ---

        # 提醒事项创建

        你负责帮助用户创建新的提醒事项。

        ## 可用工具

        - **reminders-create**: 创建提醒事项
          - `title`: 必填，提醒标题
          - `due`: 可选，ISO 8601 提醒时间，例如 `2026-04-07T20:00:00`
          - `notes`: 可选，备注

        ## 执行流程

        1. 只有当用户明确要设置提醒或待办时才调用工具
        2. 由你提取标题、时间、备注
        3. 如果有时间，必须转换成 ISO 8601 字符串
        4. 如果缺少 `title`，先简短追问
        5. 工具成功后，直接告诉用户提醒已创建

        ## 调用格式

        <tool_call>
        {"name": "reminders-create", "arguments": {"title": "发文件", "due": "2026-04-07T20:00:00"}}
        </tool_call>
        """),

        ("contacts", """
        ---
        name: Contacts
        name-zh: 通讯录
        description: '查询、创建、更新或删除联系人。当用户要查电话、看联系方式、存号码、补充联系人信息或删除联系人时使用。'
        version: "1.1.0"
        icon: person.crop.circle
        disabled: false

        triggers:
          - 联系人
          - 通讯录
          - 查电话
          - 联系电话
          - 存号码
          - 联系方式
          - 删除联系人

        allowed-tools:
          - contacts-search
          - contacts-upsert
          - contacts-delete

        examples:
          - query: "把王总电话 13812345678 添加到联系人"
            scenario: "新建或更新联系人"
          - query: "检查下联系人张晓霞的电话多少"
            scenario: "查询联系人电话"
          - query: "把王总从联系人中删除"
            scenario: "删除联系人"
        ---

        # 联系人查询与维护

        你负责帮助用户查询、创建、更新或删除通讯录联系人。

        ## 可用工具

        - **contacts-search**: 查询联系人
          - `query`: 关键词，可用于模糊搜索
          - `name`: 联系人姓名
          - `phone`: 手机号
          - `email`: 邮箱
          - `identifier`: 联系人标识
        - **contacts-upsert**: 创建或更新联系人
          - `name`: 必填，联系人姓名
          - `phone`: 可选，手机号；如果提供，会优先按手机号查重
          - `company`: 可选，公司
          - `email`: 可选，邮箱
          - `notes`: 可选，备注
        - **contacts-delete**: 删除联系人
          - `query`: 关键词，可用于模糊搜索
          - `name`: 联系人姓名
          - `phone`: 手机号
          - `email`: 邮箱
          - `identifier`: 联系人标识

        ## 执行流程

        1. 如果用户在查询电话、邮箱、联系方式，优先调用 `contacts-search`
        2. 如果用户在删除、移除、删掉联系人，调用 `contacts-delete`
        3. 如果用户在保存、添加或更新联系人，调用 `contacts-upsert`
        4. 查询或删除时优先提取 `name`，提取不到再用 `query`
        5. 保存或更新时提取姓名、手机号、公司、邮箱、备注
        6. 如果缺少保存联系人所需的 `name`，先简短追问
        7. 删除时如果匹配到多个联系人，不要猜测，应提示用户说得更具体
        8. 工具成功后，直接用中文给出简洁结果

        ## 调用格式

        <tool_call>
        {"name": "contacts-search", "arguments": {"name": "张晓霞"}}
        </tool_call>

        <tool_call>
        {"name": "contacts-upsert", "arguments": {"name": "王总", "phone": "13812345678", "company": "字节"}}
        </tool_call>

        <tool_call>
        {"name": "contacts-delete", "arguments": {"name": "王总"}}
        </tool_call>
        """),
    ]
}

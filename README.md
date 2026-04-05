# PhoneClaw

An on-device AI Agent for iPhone, powered by **Gemma 4** and **MLX** (Metal GPU). Fully offline — no network, no cloud, no privacy leaks.

## Features

- **Fully Offline** — runs entirely on-device via MLX Metal GPU inference
- **Multimodal** — supports image input (vision language model)
- **File-driven Skill System** — define capabilities in plain `SKILL.md` files, no code changes needed
- **Multi-round Tool Chain** — agent can call multiple tools in sequence (up to 10 rounds)
- **Memory-safe** — dynamic history depth, GPU cache management for 6 GB jetsam limit
- **In-app Skill Editor** — view, edit, and hot-reload SKILL.md directly on device

## Project Structure

```
PhoneClaw/
├── App/PhoneClawApp.swift          ← Entry point
├── Agent/AgentEngine.swift         ← Agent loop (tool detection, multi-round chain)
├── LLM/
│   ├── LLMEngine.swift             ← Protocol definition
│   ├── MLXLocalLLMService.swift    ← MLX GPU inference (Gemma 4)
│   ├── PromptBuilder.swift         ← Gemma 4 chat template + function calling
│   └── MLX/                        ← Custom Gemma 4 VLM implementation (9 files)
├── Skills/
│   ├── Skills.swift                ← Data models
│   ├── SkillLoader.swift           ← SKILL.md parser (YAML frontmatter + body)
│   └── ToolRegistry.swift          ← Native iOS API tool registry
├── UI/
│   ├── ContentView.swift           ← Chat UI with skill progress cards
│   ├── ChatModels.swift            ← UI data models
│   ├── SkillsManagerView.swift     ← Skills management panel
│   ├── ConfigurationsView.swift    ← Model parameter settings
│   └── Theme.swift                 ← Design system
├── Assets.xcassets/
├── Info.plist
└── PhoneClaw.entitlements          ← increased-memory-limit
```

## Requirements

- Xcode 16+
- iOS 17.0+
- iPhone with Apple Silicon (A17 Pro or later recommended for Gemma 4 E2B/E4B)
- CocoaPods (`gem install cocoapods`)

## Model

This project uses **Gemma 4 E2B** (4-bit quantized, MLX format). Download the model directory and place it at `Models/gemma-4-e2b-it-4bit/` in the project root.

You can download from Hugging Face:
```
mlx-community/gemma-4-2b-it-4bit
```

## Getting Started

### 1. Install dependencies

```bash
pod install
```

### 2. Open the workspace

```bash
open PhoneClaw.xcworkspace
```

> ⚠️ Always open `.xcworkspace`, not `.xcodeproj`

### 3. Sign and run

1. In Xcode: select the **PhoneClaw** target → **Signing & Capabilities**
2. Set your **Team** (Apple ID)
3. Change **Bundle Identifier** to something unique (e.g. `com.yourname.phoneclaw`)
4. Connect your iPhone via USB
5. Press **⌘R**

First install requires trusting the certificate on iPhone:  
**Settings → General → VPN & Device Management → Trust**

## Built-in Skills

| Skill | Tools |
|-------|-------|
| Clipboard | `clipboard-read`, `clipboard-write` |
| Device | `device-info`, `device-name`, `device-model`, `device-system-version`, `device-memory`, `device-processor-count` |
| Text | `calculate-hash`, `text-reverse` |

## Adding Custom Skills

Create a new directory under `ApplicationSupport/PhoneClaw/skills/<skill-name>/SKILL.md`:

```yaml
---
name: MySkill
description: 'What this skill does'
version: "1.0.0"
icon: star
disabled: false

triggers:
  - keyword1

allowed-tools:
  - my-tool-name

examples:
  - query: "example user query"
    scenario: "what happens"
---

# Skill Instructions

Tell the model what to do and how to call the tools.
```

Then register the native implementation in `ToolRegistry.swift`.

## Architecture

```
User Input
  → PromptBuilder (Gemma 4 chat template)
  → MLX GPU inference (streaming)
  → Detect <tool_call>
      ├── load_skill → inject SKILL.md body → re-infer
      └── tool execution → ToolRegistry → iOS API → re-infer
  → Final text response
```

## License

MIT

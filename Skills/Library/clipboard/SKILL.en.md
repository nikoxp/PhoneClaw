---
name: Clipboard
name-zh: 剪贴板
description: 'Read and write system clipboard contents. Use when the user needs to read, copy, or manipulate the clipboard.'
version: "1.0.0"
icon: doc.on.clipboard
disabled: false
type: device
chip_prompt: "Read my clipboard"
chip_label: "Read Clipboard"

triggers:
  - clipboard
  - paste
  - copy
  - pasteboard

allowed-tools:
  - clipboard-read
  - clipboard-write

examples:
  - query: "Read my clipboard"
    scenario: "Read the clipboard"
  - query: "Copy this text to the clipboard"
    scenario: "Write to the clipboard"
---

# Clipboard Operations

You are responsible for helping the user read and write the system clipboard.

## Available Tools

- **clipboard-read**: Read the current contents of the clipboard (no parameters)
- **clipboard-write**: Write text to the clipboard (parameter: text — the text to copy)

## Execution Flow

1. User asks to read → call `clipboard-read`
2. User asks to copy/write → call `clipboard-write`, passing the text parameter
3. Based on the tool's return value, answer the user concisely

## Call Format

<tool_call>
{"name": "tool_name", "arguments": {}}
</tool_call>

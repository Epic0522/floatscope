# FloatScope

<p align="center">
  <strong>A tiny glassy macOS floating hub for local AI agents.</strong>
</p>

<p align="center">
  <img alt="macOS" src="https://img.shields.io/badge/macOS-15%2B-111111?style=flat-square&logo=apple">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-6-orange?style=flat-square&logo=swift">
  <img alt="UI" src="https://img.shields.io/badge/UI-SwiftUI%20%2B%20AppKit-blue?style=flat-square">
  <img alt="License" src="https://img.shields.io/badge/License-TBD-lightgrey?style=flat-square">
</p>

<p align="center">
  <a href="#english">English</a> · <a href="#简体中文">简体中文</a>
</p>

---

## English

FloatScope is a lightweight native macOS app that keeps a small always-on-top chat capsule near your workspace. It can talk to one or more local AI agents, show recent conversation in a floating glass panel, send screenshots or attachments, and keep long-running agent sessions connected to their own desktop or CLI history systems.

### Highlights

- Native macOS floating capsule with glass-style panels.
- Always-on-top chat surface that expands on demand and collapses when focus leaves.
- Switch between multiple agents from one floating capsule.
- Built-in adapters for Codex app-server, OpenCode run sessions, and generic CLI agents.
- GUI model pickers for model, reasoning effort, or provider-specific variant.
- Conversation history picker that can load recent local transcripts.
- Manual screenshot capture and optional timed screen watching.
- Attachment support for pasted, dragged, or manually selected files and images.
- Status bar menu for opening, hiding, resetting position, starting a new conversation, screen watch, settings, and quit.
- Customizable global shortcut for showing or hiding FloatScope.

### GUI Workflow

All common actions are available from the capsule and the status bar menu.

- **Status bar bubble**: open or hide FloatScope, reset the capsule position, open history, start a new conversation, toggle screen watch, open settings, or quit.
- **Capsule `+` button**: add images or files.
- **Colored agent dot**: choose the active agent or auto routing.
- **Sparkle button**: choose model, effort, or variant for the active agent.
- **History button**: choose a previous transcript and continue from it.
- **Expand button**: manually show or hide the conversation panel.
- **Camera button**: capture the current screen and send it to the selected agent.
- **Send button**: send the current text and pending attachments.

Screen watch uses the interval configured in Settings and can be toggled from the status bar menu.

### Requirements

- macOS 15 or newer.
- Apple Silicon is the primary target.
- Xcode command line tools or a Swift toolchain.
- Optional local agent CLIs, depending on your configuration.

### Run From Source

```sh
swift run FloatScope
```

On first launch, FloatScope creates:

```text
~/Library/Application Support/FloatScope/agents.json
```

Open Settings from the status bar bubble and configure each agent before sending messages.

### Build An App Bundle

```sh
./script/build_and_run.sh --no-launch
```

The built app is written to:

```text
dist/FloatScope.app
```

### Agent Configuration

FloatScope ships with a neutral example file, `FloatScopeAgents.json`. Runtime settings live in Application Support and can be edited from Settings or directly as JSON.

```json
{
  "version": 1,
  "conversationRoot": "~/Documents/FloatScope Conversations",
  "agents": [
    {
      "id": "agent1",
      "kind": "codex-app-server",
      "displayName": "Agent 1",
      "color": "#FF6FB7",
      "executablePath": "/path/to/codex",
      "model": "gpt-5.4-mini",
      "effort": "medium"
    },
    {
      "id": "agent2",
      "kind": "opencode-run",
      "displayName": "Agent 2",
      "color": "#A85BFF",
      "executablePath": "/path/to/opencode",
      "model": "opencode/deepseek-v4-flash-free",
      "variant": "auto"
    }
  ]
}
```

Supported adapter kinds:

- `codex-app-server`: starts `codex app-server --listen stdio://` and sends turns through JSON-RPC.
- `opencode-run`: starts `opencode run --format json` and resumes the captured session id.
- `generic-cli`: sends text to a long-running CLI process through stdin and displays stdout.

You can add more agents from Settings and connect simple command-line tools through `generic-cli`.

### Screen Awareness

FloatScope supports three screen-related flows:

- Press the **camera button** to capture and send the current screen immediately.
- Enable **Screen Replay Cache** in Settings if you want FloatScope to keep a short local screenshot cache for late “look at this” moments.
- Use **Toggle Screen Watch** in the status bar menu to start or stop timed screen captures.

The first screen capture may trigger the macOS Screen Recording permission prompt. After granting permission, restart FloatScope if macOS asks for a fresh app launch.

### Repository Notes

```sh
swift build
swift run FloatScope
```

Generated build products live in `.build/`. App bundles created by the helper script are written to `dist/`.

---

## 简体中文

FloatScope 是一个轻量的 macOS 原生浮窗 hub。它会在桌面上常驻一个置顶的小胶囊聊天栏，可以连接一个或多个本地 AI agent，展开最近对话，发送截图或附件，并尽量把会话交给对应 agent 自己的桌面端或 CLI 历史系统管理。

### 主要功能

- macOS 原生置顶胶囊浮窗，使用毛玻璃风格面板。
- 需要时展开聊天记录，失焦后自动收回。
- 在同一个浮窗里切换多个 agent。
- 内置 Codex app-server、OpenCode run、通用 CLI 三类桥接方式。
- 图形化选择模型、推理强度或 provider variant。
- 聊天记录选择器，可读取最近本地转写并继续对话。
- 手动截图、可选定时读屏。
- 支持粘贴、拖入、手动添加图片和文件。
- 状态栏菜单负责打开、隐藏、重置位置、新建对话、读屏开关、设置和退出。
- 可自定义全局快捷键，用来显示或隐藏浮窗。

### 纯 GUI 操作

常用操作都在胶囊和状态栏菜单里。

- **状态栏气泡图标**：打开或隐藏浮窗、重置位置、打开历史、新建对话、开启或关闭定时读屏、打开设置、退出。
- **胶囊里的 `+`**：添加图片或文件。
- **彩色 agent 小球**：选择当前 agent 或自动路由。
- **小星星按钮**：选择模型、推理强度或 variant。
- **历史按钮**：选择旧聊天记录并接着聊。
- **展开按钮**：手动展开或收起聊天面板。
- **相机按钮**：立即截取当前屏幕并发送给当前 agent。
- **发送按钮**：发送输入内容和待发送附件。

定时读屏使用设置页里的默认间隔，并可从状态栏菜单开启或关闭。

### 环境要求

- macOS 15 或更新版本。
- 主要面向 Apple Silicon。
- Xcode Command Line Tools 或 Swift 工具链。
- 根据配置可选安装本地 agent CLI。

### 从源码运行

```sh
swift run FloatScope
```

首次启动会创建：

```text
~/Library/Application Support/FloatScope/agents.json
```

从状态栏气泡图标打开 Settings，配置每个 agent 后再发送消息。

### 构建 App

```sh
./script/build_and_run.sh --no-launch
```

构建结果位于：

```text
dist/FloatScope.app
```

### Agent 配置

仓库里提供了中性的示例配置 `FloatScopeAgents.json`。实际运行配置保存在 Application Support，可以在设置页编辑，也可以直接修改 JSON。

```json
{
  "version": 1,
  "conversationRoot": "~/Documents/FloatScope Conversations",
  "agents": [
    {
      "id": "agent1",
      "kind": "codex-app-server",
      "displayName": "Agent 1",
      "color": "#FF6FB7",
      "executablePath": "/path/to/codex",
      "model": "gpt-5.4-mini",
      "effort": "medium"
    },
    {
      "id": "agent2",
      "kind": "opencode-run",
      "displayName": "Agent 2",
      "color": "#A85BFF",
      "executablePath": "/path/to/opencode",
      "model": "opencode/deepseek-v4-flash-free",
      "variant": "auto"
    }
  ]
}
```

支持的 adapter：

- `codex-app-server`：启动 `codex app-server --listen stdio://`，通过 JSON-RPC 发送消息。
- `opencode-run`：启动 `opencode run --format json`，并复用捕获到的 session id。
- `generic-cli`：向长期运行的 CLI 进程 stdin 发送文本，并显示 stdout。

设置页可以继续添加更多 agent，也可以用 `generic-cli` 连接普通命令行工具。

### 屏幕感知

FloatScope 提供三种和屏幕相关的能力：

- 点击 **相机按钮**：立刻截取当前屏幕并发送。
- 在 Settings 里开启 **Screen Replay Cache**：保留短时间本地截图缓存，用于画面已经闪过去的场景。
- 在状态栏菜单点击 **Toggle Screen Watch**：开启或关闭定时读屏。

第一次截图可能会触发 macOS 的屏幕录制权限提示。授权后，如果系统要求重新启动应用，重启 FloatScope 即可。

### 仓库说明

```sh
swift build
swift run FloatScope
```

`.build/` 里保存 SwiftPM 构建产物。脚本生成的 app bundle 位于 `dist/`。

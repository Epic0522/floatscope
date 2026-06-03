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
- Switch between single-agent chat and Group chat from one floating capsule.
- Group chat fans one message out to every configured agent and shares a short rolling context between them.
- Built-in adapters for Codex app-server, lightweight resumable Codex CLI sessions, OpenCode run sessions, and generic CLI agents.
- GUI model pickers for model, reasoning effort, or provider-specific variant.
- Conversation history picker that can load, continue, or hide local project conversations.
- Manual screenshot capture and optional timed screen watching.
- Attachment support for pasted, dragged, or manually selected files and images.
- Long-text editor for larger drafts, plus right-click **Rollback** on user messages.
- Breathing status dots show active thinking, speaking, watching, or error states.
- Status bar menu for opening, hiding, resetting position, starting a new conversation, screen watch, settings, and quit.
- Customizable global shortcut for showing or hiding FloatScope.
- Language selector for English, Simplified Chinese, or system language.
- Replies automatically open the conversation panel, then collapse after the configured delay once every selected agent has finished.
- Long histories render progressively from the latest messages, and image previews load asynchronously to keep expansion responsive.

### GUI Workflow

All common actions are available from the capsule and the status bar menu.

- **Status bar bubble**: open or hide FloatScope, reset the capsule position, open history, start a new conversation, toggle screen watch, open settings, or quit.
- **Capsule `+` button**: add images or files.
- **Colored agent dot**: choose one agent or Group chat.
- **Codex mode buttons**: choose App mode for native Codex app-server integration or CLI mode for a lighter background session.
- **Sparkle button**: choose model, effort, or variant for the active agent.
- **History button**: choose a previous transcript, continue from it, or hide it from FloatScope history.
- **Expand button**: manually show or hide the conversation panel.
- **Camera button**: capture the current screen and send it to the selected agent.
- **Send button**: send the current text and pending attachments.

Screen watch uses the interval configured in Settings and can be toggled from the status bar menu.

If an agent accepts a message but never starts streaming a reply, FloatScope surfaces a timeout message instead of leaving the capsule in a silent waiting state. For transient network or provider problems, right-click a user bubble, choose **Rollback**, adjust the text, and send it again.

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

Open Settings from the status bar bubble, choose a language if needed, and configure each agent before sending messages.

### Build An App Bundle

```sh
./script/build_and_run.sh --no-launch
```

The built app is written to:

```text
dist/FloatScope.app
```

To launch an isolated clean preview without sharing the normal app's settings or Application Support data:

```sh
./script/build_and_run.sh --preview
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
      "appBundlePath": "/Applications/Codex.app",
      "model": "gpt-5.4-mini",
      "effort": "medium"
    },
    {
      "id": "agent2",
      "kind": "opencode-run",
      "displayName": "Agent 2",
      "color": "#A85BFF",
      "executablePath": "/path/to/opencode",
      "appBundlePath": "/Applications/OpenCode.app",
      "model": "opencode/deepseek-v4-flash-free",
      "variant": "auto"
    }
  ]
}
```

Supported adapter kinds:

- `codex-app-server`: starts `codex app-server --listen stdio://` and sends turns through JSON-RPC.
- `codex-cli-resume`: uses `codex exec --json` and resumes the captured session id without requiring the Codex app to remain open.
- `opencode-run`: starts `opencode run --format json` and resumes the captured session id.
- `generic-cli`: sends text to a long-running CLI process through stdin and displays stdout.

You can add more agents from Settings and connect simple command-line tools through `generic-cli`.

`appBundlePath` is optional. Codex App mode may use it to bring the configured desktop app online when a turn is sent. OpenCode run remains CLI-first and does not launch the OpenCode desktop app when sending a message.

Codex CLI conversations are registered into Codex's local history index when possible. Their timestamp titles use a `CLI` prefix, and Group conversations use a `群聊 CLI` prefix so they remain distinguishable from app-server sessions. OpenCode run sessions stay CLI-first and do not launch the OpenCode desktop app when sending a message.

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

If FloatScope becomes unresponsive, stop only the FloatScope process with:

```sh
./script/force_quit_floatscope.sh
```

---

## 简体中文

FloatScope 是一个轻量的 macOS 原生浮窗 hub。它会在桌面上常驻一个置顶的小胶囊聊天栏，可以连接一个或多个本地 AI agent，展开最近对话，发送截图或附件，并尽量把会话交给对应 agent 自己的桌面端或 CLI 历史系统管理。

### 主要功能

- macOS 原生置顶胶囊浮窗，使用毛玻璃风格面板。
- 需要时展开聊天记录，失焦后自动收回。
- 在同一个浮窗里切换单人聊天和 Group 群聊。
- Group 群聊会把同一条消息发送给所有已配置 agent，并在它们之间共享短滚动上下文。
- 内置 Codex app-server、可续接的轻量 Codex CLI、OpenCode run、通用 CLI 桥接方式。
- 图形化选择模型、推理强度或 provider variant。
- 聊天记录选择器，可读取、继续或隐藏本地项目会话。
- 手动截图、可选定时读屏。
- 支持粘贴、拖入、手动添加图片和文件。
- 长文本编辑器适合大段输入；用户消息可右键 **回退** 后修改再发送。
- 呼吸小球显示思考、输出、读屏和错误状态。
- 状态栏菜单负责打开、隐藏、重置位置、新建对话、读屏开关、设置和退出。
- 可自定义全局快捷键，用来显示或隐藏浮窗。
- 可在设置里选择 English、简体中文或跟随系统语言。
- 收到回复时自动展开聊天面板，所选 agent 全部回复完成后，再按设置的延迟自动收回。
- 长聊天记录会从最新消息开始渐进渲染，图片预览异步加载，减少展开卡顿。

### 纯 GUI 操作

常用操作都在胶囊和状态栏菜单里。

- **状态栏气泡图标**：打开或隐藏浮窗、重置位置、打开历史、新建对话、开启或关闭定时读屏、打开设置、退出。
- **胶囊里的 `+`**：添加图片或文件。
- **彩色 agent 小球**：选择单个 agent 或 Group 群聊。
- **Codex 模式按钮**：可选择原生 app-server 的 App 模式，或更轻量的 CLI 模式。
- **小星星按钮**：选择模型、推理强度或 variant。
- **历史按钮**：选择旧聊天记录并接着聊，也可以隐藏记录。
- **展开按钮**：手动展开或收起聊天面板。
- **相机按钮**：立即截取当前屏幕并发送给当前 agent。
- **发送按钮**：发送输入内容和待发送附件。

定时读屏使用设置页里的默认间隔，并可从状态栏菜单开启或关闭。

如果某个 agent 接收了消息但迟迟没有开始输出，FloatScope 会显示超时提示，而不是让浮窗静默等待。遇到临时网络或 provider 问题时，可以右键用户气泡，选择 **回退**，改完后再发送。

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

从状态栏气泡图标打开设置，按需选择语言，并配置每个 agent 后再发送消息。

### 构建 App

```sh
./script/build_and_run.sh --no-launch
```

构建结果位于：

```text
dist/FloatScope.app
```

如需启动一个不共享正式版设置和 Application Support 数据的干净预览包：

```sh
./script/build_and_run.sh --preview
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
      "appBundlePath": "/Applications/Codex.app",
      "model": "gpt-5.4-mini",
      "effort": "medium"
    },
    {
      "id": "agent2",
      "kind": "opencode-run",
      "displayName": "Agent 2",
      "color": "#A85BFF",
      "executablePath": "/path/to/opencode",
      "appBundlePath": "/Applications/OpenCode.app",
      "model": "opencode/deepseek-v4-flash-free",
      "variant": "auto"
    }
  ]
}
```

支持的 adapter：

- `codex-app-server`：启动 `codex app-server --listen stdio://`，通过 JSON-RPC 发送消息。
- `codex-cli-resume`：使用 `codex exec --json`，并复用捕获到的 session id，不要求 Codex App 持续打开。
- `opencode-run`：启动 `opencode run --format json`，并复用捕获到的 session id。
- `generic-cli`：向长期运行的 CLI 进程 stdin 发送文本，并显示 stdout。

设置页可以继续添加更多 agent，也可以用 `generic-cli` 连接普通命令行工具。

`appBundlePath` 是可选配置。Codex App 模式可以用它在发送消息时拉起对应桌面 App；OpenCode run 保持 CLI 优先，发送消息时不会自动拉起 OpenCode 桌面 App。

Codex CLI 会话会尽可能注册到 Codex 的本地历史索引。普通 CLI 会话标题带有 `CLI` 前缀，群聊 CLI 会话带有 `群聊 CLI` 前缀，便于和 app-server 会话区分。OpenCode run 保持 CLI 优先，发送消息时不会自动拉起 OpenCode 桌面 App。

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

# FloatScope

FloatScope is a lightweight native macOS floating hub for local AI agent workflows. It provides a small always-on-top capsule chat bar, expands into recent conversation when active, and can send manual or scheduled screen captures to configured agents.

The app is intentionally minimal: no character rendering, no Live2D or VRM layer, and no long-term memory system of its own. Conversation history is delegated to the underlying agent applications or CLIs whenever possible.

## Features

- Borderless floating capsule that stays above other windows.
- Manual expand/collapse and auto expand on send or reply.
- Configurable agents loaded from a user editable JSON config.
- Built-in adapters for Codex app-server and OpenCode run sessions.
- Generic CLI agent slots for future adapters.
- Agent color dots with lightweight activity animation.
- Model and effort/variant selectors.
- Manual screen capture prompt with natural phrases such as `look at this`.
- Timed screen watching with fixed or random intervals.
- Attachment support for images and files.
- Status bar menu for settings and quitting.

## Requirements

- macOS 15 or newer.
- Apple Silicon is the primary target.
- Xcode command line tools or a Swift toolchain.
- Optional: local agent CLIs such as Codex or OpenCode.

## Run From Source

```sh
swift run FloatScope
```

The first launch creates a user config at:

```text
~/Library/Application Support/FloatScope/agents.json
```

Open FloatScope settings from the menu bar icon and configure each agent path before sending messages. The public defaults intentionally leave executable paths blank.

## Agent Config

FloatScope ships with a neutral example config in `FloatScopeAgents.json`. The runtime config is stored in Application Support and has this shape:

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

- `codex-app-server`: starts `codex app-server --listen stdio://` and sends turns through the app-server JSON-RPC protocol.
- `opencode-run`: starts `opencode run --format json` and resumes the captured session id.
- `generic-cli`: sends text to a long-running CLI process through stdin and displays stdout.

## Commands

```text
/agent agent1
/agent agent2
/agent auto
/watch 60s
/watch random 45-90s
/watch off
/new
look at this
check screen
```

Screen capture uses macOS ScreenCaptureKit. The first capture may trigger the system Screen Recording permission prompt. After granting permission, restart FloatScope if macOS does not immediately allow capture.

## History Model

FloatScope keeps only recent UI messages and lightweight local preferences. It does not implement a memory database. Native session history belongs to the configured agent tools.

For Codex and OpenCode integrations, FloatScope makes a best-effort attempt to keep sessions associated with the configured conversation project root so they can appear in the corresponding desktop app sidebars.

## Build Notes

```sh
swift build
swift run FloatScope
```

Generated build products live in `.build/` and are not tracked. User transcripts, screenshots, and local agent configs are also excluded from git.

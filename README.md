# CodeBoss

Orchestrates [Claude Code](https://docs.anthropic.com/en/docs/claude-code) headless from [Cowork](https://claude.ai). Cowork acts as the supervisor with full UI access; Claude Code runs silently and messages back when done.

## Problem It Solves

In Cowork you can be working on project and dialing-in requirements, and the session context will have a lot of understanding. 
At that point, why can't *Cowork* just talk back and forth with Claude Code and get it done? It can now with this plugin.
Plus, while the Cowork session is "waiting" for a Code dispatch to complete, you can still chat with that same Cowork session.

The magic: CodeBoss uses low-level OS accessibility API's to asynchronously inject messages from a headless Claude Code right into session's input UI. 
Some would call that a bit if a hack, so if you are not cool with that, don't use. 
On the other hand, if you need to schedule intensive work while away (or while sleeping...)

## Platform Support

| Platform | Status | Scripts |
|----------|--------|---------|
| Windows  | Available | PowerShell + Windows UI Automation |
| macOS    | Available | bash + macOS Accessibility API (AppleScript) |

## How It Works

CodeBoss uses a supervisor pattern: Cowork dispatches tasks to Claude Code via platform-specific scripts, and Claude Code communicates results back through the OS's UI automation layer.

On Windows, PowerShell scripts launch Claude Code in a hidden window and use Windows UI Automation to relay messages back to Claude Desktop. On macOS, bash scripts launch Claude Code in the background and use AppleScript with the macOS Accessibility framework to relay messages.

## Repository Structure

```
codeboss/
  LICENSE
  README.md
  plugin/
    .claude-plugin/plugin.json    # Plugin metadata
    CONNECTORS.md                 # Required MCP connectors
    README.md                     # Plugin documentation
    skills/
      codeboss/
        SKILL.md                  # Main skill (platform-aware)
        references/               # Architecture and troubleshooting docs
        scripts/
          windows/                # PowerShell scripts (dispatch, runner, pipe)
            dispatch.ps1
            run-phase.ps1
            Send-ClaudeMessage.ps1
          macos/                  # bash scripts (dispatch, runner, pipe)
            dispatch.sh
            run-phase.sh
            send-claude-message.sh
```

## Installation

Install as a Cowork plugin. The plugin handles bootstrap automatically on first use -- it deploys the platform-specific scripts to the appropriate location and verifies prerequisites.

### Prerequisites

Both platforms:
- Claude Desktop with Cowork mode
- Claude Code installed globally: `npm install -g @anthropic-ai/claude-code`

Windows:
- A Windows MCP connector (e.g., Windows-MCP)

macOS:
- Accessibility permissions granted to your terminal app (System Settings > Privacy & Security > Accessibility)

## Usage

Once installed, tell Cowork to dispatch a task:

- "CodeBoss: build a REST API in my project"
- "run CC on ~/projects/site -- add dark mode"
- "dispatch to Claude Code: refactor auth in my backend"

See the plugin README for detailed usage, sync vs async modes, and session management.

## Contributing

Testing feedback welcome, especially from macOS users. File issues for any Accessibility API quirks or Electron-specific behavior.

## License

MIT

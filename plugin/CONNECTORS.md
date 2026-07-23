# Connectors

CodeBoss's connector requirements differ by platform. Windows drives the OS
through an MCP connector; macOS uses Claude Code's built-in shell plus the
system Accessibility API, so no MCP connector is required.

## Windows: Required ~~windows-os Connector

CodeBoss requires the **~~windows-os** connector for all operations. This is the Windows MCP connector that provides:

- **PowerShell execution**: Running dispatch.ps1, checking script installation, reading output
- **FileSystem access**: Deploying scripts to `%APPDATA%\codeboss\`, reading SESSION_ID, writing handoff files
- **App control**: Bootstrap checks, process management

| Category   | Placeholder    | Purpose                                                             |
|------------|----------------|---------------------------------------------------------------------|
| Windows OS | `~~windows-os` | PowerShell execution, file system access, UI automation via scripts |

### Installation

Install the Windows MCP connector before using CodeBoss. Without it, none of the dispatch, bootstrap, or monitoring operations will work.

The connector provides these tools used by CodeBoss:
- `PowerShell` - Execute PS1 scripts and inline commands
- `FileSystem` - Read/write files on the Windows file system (for script deployment and log access)
- `App` - Launch and manage applications

### How `~~windows-os` References Work

In the SKILL.md and reference files, `~~windows-os` refers to whichever Windows MCP connector the user has installed. The connector is tool-agnostic at the category level.

## macOS: No Connector Required

macOS does **not** need an MCP OS connector. Everything CodeBoss does on macOS
runs through capabilities Cowork already has:

- **Shell execution**: the `dispatch.sh` / `run-phase.sh` / `send-claude-message.sh`
  scripts run via the built-in Bash tool. This deploys scripts to
  `~/Library/Application Support/codeboss/`, reads `SESSION_ID`, and launches the
  headless `claude` CLI.
- **Report-back ("the pipe")**: `send-claude-message.sh` uses the macOS
  Accessibility API through `osascript` (AppleScript) to type Claude Code's
  DONE / QUESTION / PROGRESS messages back into the Claude Desktop composer.

The one prerequisite is an OS permission, not a connector: the terminal app (or
Claude Desktop) must be granted **Accessibility** access in System Settings >
Privacy & Security > Accessibility. The scripts detect and report this if it is
missing. Do not install a Windows MCP connector on macOS -- it is neither needed
nor available.

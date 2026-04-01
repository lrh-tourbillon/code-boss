# Connectors

## Required: Windows OS Connector

CodeBoss requires the **~~windows-os** connector for all operations. This is the Windows MCP connector that provides:

- **PowerShell execution**: Running dispatch.ps1, checking script installation, reading output
- **FileSystem access**: Deploying scripts to `%APPDATA%\codeboss\`, reading SESSION_ID, writing handoff files
- **App control**: Bootstrap checks, process management

| Category   | Placeholder    | Purpose                                                             |
|------------|----------------|---------------------------------------------------------------------|
| Windows OS | `~~windows-os` | PowerShell execution, file system access, UI automation via scripts |

## Installation

Install the Windows MCP connector before using CodeBoss. Without it, none of the dispatch, bootstrap, or monitoring operations will work.

The connector provides these tools used by CodeBoss:
- `PowerShell` - Execute PS1 scripts and inline commands
- `FileSystem` - Read/write files on the Windows file system (for script deployment and log access)
- `App` - Launch and manage applications

## How `~~windows-os` References Work

In the SKILL.md and reference files, `~~windows-os` refers to whichever Windows MCP connector the user has installed. The connector is tool-agnostic at the category level.

# Connectors

CodeBoss's connector requirements differ by platform. Both platforms need a
host-execution bridge so the supervisor can drive the OS: Windows uses the
~~windows-os MCP connector; macOS uses the bundled `codeboss-host` MCP connector
(plus the system Accessibility API for report-back).

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

## macOS: CodeBoss Host Connector

On macOS the Cowork supervisor runs in a sandboxed environment: its built-in
tools cannot reach your real filesystem or drive the local Claude Desktop UI. So
macOS needs a host-execution bridge -- the counterpart to the Windows OS
connector above. CodeBoss ships one: **`codeboss-host`**, a small local MCP
server (`skills/codeboss/scripts/macos/codeboss-host.py`, Python 3 standard
library only, no third-party packages) that Claude Desktop launches on the host.
Cowork calls its tools; it runs the CodeBoss scripts on your machine and returns
the results.

It exposes only scoped CodeBoss operations -- never a general shell:

| Tool | Purpose |
|------|---------|
| `codeboss_dispatch` | Run a headless Claude Code task (async or sync) |
| `codeboss_status`   | Health check: scripts installed, claude found, auth detected |
| `codeboss_read_ops` | Tail the latest runner log for troubleshooting |

### One-time setup

Run once in a terminal (Terminal or iTerm). If Claude Desktop is running, quit it
first (Cmd+Q) so it cannot overwrite the change when it exits. The installer
deploys the scripts and registers the connector in your Claude Desktop config,
**discovering the config directory automatically** so no path is hardcoded:

```bash
python3 /path/to/plugin/skills/codeboss/scripts/macos/codeboss-host.py --install
```

Then:
1. Open Claude Desktop (it reads this config at launch). If it was running during
   install, fully quit (Cmd+Q) and reopen; if `codeboss-host` is still missing,
   quit it first and re-run `--install`.
2. Grant **Accessibility** to Claude Desktop (System Settings > Privacy & Security >
   Accessibility) -- required for the report-back step, which types Claude Code's
   messages into the Cowork composer via the Accessibility API.
3. In Cowork, run the `codeboss_status` tool to verify (expect `claude auth: detected`).

`--uninstall` reverses the config change; `--status` prints the health check.

### Notes

- If your Claude Desktop config lives in a nonstandard location, set
  `CODEBOSS_CLAUDE_CONFIG_DIR` before running `--install` and the installer uses it.
- If the `claude` CLI is authenticated via shell-exported variables (for example
  `ANTHROPIC_*` set in `~/.zshrc`), the connector recovers them by sourcing your
  login shell, so headless dispatches authenticate correctly even though Claude
  Desktop launches the connector with a minimal environment. Users whose CLI has
  on-disk credentials need no special handling.
- Security model: `codeboss_dispatch` runs Claude Code with
  `--dangerously-skip-permissions` in the project directory you pass, so within a
  dispatch CC can read/write broadly, bounded only by its system prompt -- the
  same trust model as the Windows dispatcher. The connector adds no general-shell
  surface, but it is **not** a filesystem sandbox around CC; only dispatch to
  directories you trust.
- Do not install the Windows MCP connector on macOS -- it is neither needed nor
  available; the `codeboss-host` connector is the macOS bridge.

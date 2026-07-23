#!/usr/bin/env python3
"""codeboss-host.py - macOS host connector for CodeBoss (MCP server).

Cowork runs in a sandboxed VM and cannot touch the host Mac or the local
Claude Desktop UI. This is the macOS analog of the Windows ~~windows-os
connector: a small MCP server that Claude Desktop launches ON THE HOST
(outside the sandbox), giving the Cowork supervisor a controlled bridge to the
local CodeBoss scripts.

It is deliberately SCOPED. It exposes only CodeBoss operations -- never a
general "run any shell command" tool -- so the supervisor cannot execute
arbitrary host commands:
  - codeboss_dispatch : run the deployed dispatch.sh (async or sync)
  - codeboss_status   : health check (scripts installed? claude found?)
  - codeboss_read_ops : tail the latest runner log for troubleshooting

Trust boundary: codeboss_dispatch runs Claude Code with
--dangerously-skip-permissions in the given project_dir, so within a dispatch CC
can read/write broadly, bounded only by its system prompt -- the same trust model
as the Windows dispatcher. "Scoped" here means the connector's own tool surface
(no arbitrary shell), NOT a filesystem sandbox around CC. Only dispatch to
directories you trust. (The prompt-only boundary is a pre-existing CodeBoss design
limitation flagged upstream, not specific to macOS.)

Transport: MCP over stdio, newline-delimited JSON-RPC 2.0. stdlib only -- no
third-party packages, no network. Runs on the stock /usr/bin/python3 (3.9+).

stdout carries ONLY JSON-RPC messages. All logging goes to stderr.
"""

import glob
import json
import os
import shutil
import subprocess
import sys
import time

SERVER_NAME = "codeboss-host"
SERVER_VERSION = "0.1.0"
DEFAULT_PROTOCOL = "2025-06-18"

SUPPORT_DIR = os.path.expanduser("~/Library/Application Support/codeboss")
SCRIPTS = {
    "dispatch.sh": os.path.join(SUPPORT_DIR, "dispatch.sh"),
    "run-phase.sh": os.path.join(SUPPORT_DIR, "run-phase.sh"),
    "send-claude-message.sh": os.path.join(SUPPORT_DIR, "send-claude-message.sh"),
}
DISPATCH = SCRIPTS["dispatch.sh"]

# Common claude CLI locations, so status can confirm CC is reachable even when
# Claude Desktop launches us with a minimal PATH. (run-phase.sh does its own,
# more thorough lookup at dispatch time; this is just for the health check.)
CLAUDE_CANDIDATES = [
    "/opt/homebrew/bin/claude",
    "/usr/local/bin/claude",
    os.path.expanduser("~/.local/bin/claude"),
    os.path.expanduser("~/.npm-global/bin/claude"),
]

# A sane host PATH prepended for child scripts, in case Claude Desktop launches
# this server with only a minimal environment (the same GUI-launch problem the
# run-phase.sh CF1 fix addresses).
HOST_PATH = ":".join([
    "/opt/homebrew/bin", "/usr/local/bin", os.path.expanduser("~/.local/bin"),
    "/usr/bin", "/bin", "/usr/sbin", "/sbin",
])


def log(*args):
    print("[%s]" % SERVER_NAME, *args, file=sys.stderr, flush=True)


_LOGIN_ENV = None


def _parse_env_json(text):
    try:
        return json.loads(text)
    except ValueError:
        pass
    # Tolerate shell startup noise printed before/after the JSON object.
    for line in reversed((text or "").splitlines()):
        line = line.strip()
        if line.startswith("{") and line.endswith("}"):
            try:
                return json.loads(line)
            except ValueError:
                continue
    return None


def login_env():
    """Return the user's real login-shell environment (cached).

    Claude Desktop launches this server with a minimal GUI environment, so the
    user's shell-exported variables are absent. That includes PATH additions
    (Homebrew) and, when the claude CLI is authenticated through shell-exported
    variables (e.g. ANTHROPIC_* set in ~/.zshrc), those vars -- without which
    the CLI reports "Not logged in". Recover them by running the user's login
    shell INTERACTIVELY (-i, so ~/.zshrc is sourced) and dumping its environment.
    Falls back to the bare environment if capture fails. Cached for the process
    lifetime: a mid-session credential/env change is not seen until Claude Desktop
    relaunches the connector.
    """
    global _LOGIN_ENV
    if _LOGIN_ENV is not None:
        return _LOGIN_ENV
    shell = os.environ.get("SHELL") or "/bin/zsh"
    dump = ('/usr/bin/python3 -c '
            '"import os,json,sys;sys.stdout.write(json.dumps(dict(os.environ)))"')
    # Interactive login first (sources ~/.zshrc, where many setups export vars);
    # then non-interactive login, then plain, as fallbacks.
    for flags in (["-i", "-l", "-c"], ["-l", "-c"], ["-c"]):
        try:
            proc = subprocess.run(
                [shell] + flags + [dump],
                capture_output=True, text=True, timeout=12,
                stdin=subprocess.DEVNULL,
            )
        except Exception as exc:  # noqa: BLE001 - fall through to next strategy
            log("login env capture (%s) failed: %s" % (" ".join(flags), exc))
            continue
        parsed = _parse_env_json((proc.stdout or "").strip())
        if parsed:
            log("recovered login-shell env via '%s %s' (%d vars)"
                % (shell, " ".join(flags), len(parsed)))
            _LOGIN_ENV = parsed
            return _LOGIN_ENV
    log("could not capture login-shell env; using bare environment")
    _LOGIN_ENV = dict(os.environ)
    return _LOGIN_ENV


def _run(cmd_args, timeout):
    """Run a fixed argument list (never a shell string) and capture output."""
    env = dict(login_env())  # user's real shell env: auth vars, PATH, locale, ...
    env["PATH"] = HOST_PATH + ":" + env.get("PATH", "")
    try:
        proc = subprocess.run(
            cmd_args, capture_output=True, text=True, timeout=timeout, env=env
        )
        return proc.returncode, proc.stdout or "", proc.stderr or ""
    except subprocess.TimeoutExpired:
        return 124, "", "timed out after %ss" % timeout
    except Exception as exc:  # noqa: BLE001 - surface any spawn failure as text
        return 1, "", "failed to run: %s" % exc


# --- Tool definitions (advertised to the client) ---

TOOLS = [
    {
        "name": "codeboss_dispatch",
        "description": (
            "Dispatch a task to Claude Code (headless) on the host Mac via CodeBoss. "
            "mode=async (default) fires and returns a security 'Code=' immediately; "
            "Claude Code reports back into the Cowork composer when it finishes. "
            "mode=sync blocks until Claude Code exits and returns its output directly. "
            "This is the only way to run Claude Code; it does not expose a general shell."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_dir": {
                    "type": "string",
                    "description": "Absolute path to the project directory Claude Code works in.",
                },
                "prompt": {
                    "type": "string",
                    "description": "The task description for Claude Code.",
                },
                "max_turns": {
                    "type": "integer",
                    "description": "Max agentic turns before CC exits (default 50).",
                    "default": 50,
                },
                "mode": {
                    "type": "string",
                    "enum": ["async", "sync"],
                    "description": "async (default) or sync.",
                    "default": "async",
                },
                "continue_session": {
                    "type": "boolean",
                    "description": "Resume the most recent CC session for this project.",
                    "default": False,
                },
                "resume": {
                    "type": "string",
                    "description": "Resume a specific CC session by id.",
                },
                "extra_system_prompt": {
                    "type": "string",
                    "description": "Extra task-specific system prompt appended for CC.",
                },
            },
            "required": ["project_dir", "prompt"],
        },
    },
    {
        "name": "codeboss_status",
        "description": (
            "Health check for the CodeBoss host install: confirms the dispatch/runner/"
            "send scripts are present and executable, locates the claude CLI, and reports paths."
        ),
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "codeboss_read_ops",
        "description": (
            "Tail the latest CodeBoss runner log for a project, to troubleshoot a dispatch "
            "(status, DONE/ERROR, send-claude-message trace)."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_dir": {"type": "string", "description": "Absolute project path."},
                "lines": {"type": "integer", "description": "Log lines to tail (default 40).", "default": 40},
            },
            "required": ["project_dir"],
        },
    },
]


# --- Tool implementations. Each returns (is_error: bool, text: str). ---

def tool_dispatch(args):
    project_dir = args.get("project_dir")
    prompt = args.get("prompt")
    if not project_dir or not prompt:
        return True, "project_dir and prompt are both required."
    if not os.path.isabs(project_dir):
        return True, (
            "project_dir must be an absolute path (got %r). The connector runs on "
            "the host with its own working directory, so relative paths are ambiguous."
            % project_dir
        )
    if not os.path.isfile(DISPATCH):
        return True, (
            "dispatch.sh not found at %s. Run the CodeBoss macOS install/bootstrap first."
            % DISPATCH
        )

    mode = args.get("mode", "async")
    try:
        max_turns = int(args.get("max_turns", 50) or 50)
    except (TypeError, ValueError):
        max_turns = 50

    # Build a fixed argument list -- prompt is passed as a single argv element,
    # so there is no shell and no injection surface.
    cmd = [
        "/bin/bash", DISPATCH,
        "--project-dir", str(project_dir),
        "--prompt", str(prompt),
        "--max-turns", str(max_turns),
    ]
    if mode == "sync":
        cmd.append("--sync")
    if args.get("continue_session"):
        cmd.append("--continue")
    if args.get("resume"):
        cmd += ["--resume", str(args["resume"])]
    if args.get("extra_system_prompt"):
        cmd += ["--extra-system-prompt", str(args["extra_system_prompt"])]

    # async: dispatch.sh backgrounds the runner and returns at once.
    # sync: it blocks this (single-threaded) server until CC exits AND must
    # return within the MCP client's request timeout, so cap it below the
    # documented <60s sync window. Longer work should use async (the default).
    timeout = 55 if mode == "sync" else 30
    rc, out, err = _run(cmd, timeout)
    text = out.strip()
    if err.strip():
        text = (text + "\n[stderr] " + err.strip()).strip()
    if rc != 0:
        return True, "dispatch.sh exited %s.\n%s" % (rc, text or "(no output)")
    return False, text or "(dispatch produced no output)"


def tool_status(args):
    lines = []
    all_ok = True
    for name, path in SCRIPTS.items():
        present = os.path.isfile(path)
        execable = present and os.access(path, os.X_OK)
        all_ok = all_ok and execable
        state = "present" if present else "MISSING"
        if present and not execable:
            state += " (NOT executable)"
        lines.append("  %-24s %s" % (name + ":", state))

    claude = next((c for c in CLAUDE_CANDIDATES if os.access(c, os.X_OK)), None)
    le = login_env()
    authed = bool(le.get("ANTHROPIC_API_KEY")) or os.path.isfile(
        os.path.expanduser("~/.claude/.credentials.json")
    )
    lines.append("  %-24s %s" % ("claude CLI:", claude or "not found in common locations"))
    lines.append("  %-24s %s" % (
        "claude auth:",
        "detected" if authed else "NOT DETECTED (dispatches will report 'Not logged in')",
    ))
    lines.append("  %-24s %s" % ("support_dir:", SUPPORT_DIR))
    ok = all_ok and (claude is not None) and authed
    header = "CodeBoss host connector OK" if ok else "CodeBoss host connector: NEEDS ATTENTION"
    return (not ok), header + "\n" + "\n".join(lines)


def tool_read_ops(args):
    project_dir = args.get("project_dir")
    if not project_dir:
        return True, "project_dir is required."
    if not os.path.isabs(project_dir):
        return True, "project_dir must be an absolute path (got %r)." % project_dir
    ops_dir = os.path.join(os.path.realpath(project_dir), ".codeboss", "ops")
    logs = sorted(glob.glob(os.path.join(ops_dir, "runner-*.log")), key=os.path.getmtime)
    if not logs:
        return True, "No runner logs found under %s" % ops_dir
    latest = logs[-1]
    # Defense in depth: only read a regular file that really lives inside the
    # project's ops dir -- never follow a symlink out to an arbitrary file.
    real = os.path.realpath(latest)
    if os.path.islink(latest) or not real.startswith(ops_dir + os.sep) or not os.path.isfile(real):
        return True, "Refusing to read %s: not a regular file inside the ops directory." % latest
    try:
        n = int(args.get("lines", 40) or 40)
    except (TypeError, ValueError):
        n = 40
    try:
        with open(real, "r", errors="replace") as fh:
            tail = "".join(fh.readlines()[-n:])
    except OSError as exc:
        return True, "Could not read %s: %s" % (latest, exc)
    return False, "== %s ==\n%s" % (latest, tail)


TOOL_FUNCS = {
    "codeboss_dispatch": tool_dispatch,
    "codeboss_status": tool_status,
    "codeboss_read_ops": tool_read_ops,
}


# --- JSON-RPC / MCP plumbing ---

def _send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def _result(msg_id, result):
    _send({"jsonrpc": "2.0", "id": msg_id, "result": result})


def _error(msg_id, code, message):
    _send({"jsonrpc": "2.0", "id": msg_id, "error": {"code": code, "message": message}})


def handle(req):
    if not isinstance(req, dict):
        _error(None, -32600, "Invalid Request: expected a JSON object")
        return
    method = req.get("method")
    msg_id = req.get("id")

    if method == "initialize":
        params = req.get("params") or {}
        # Echo the client's requested protocol version (lenient, for compatibility
        # across Claude Desktop versions); the tool surface is simple enough that
        # version-specific framing differences do not apply here.
        proto = params.get("protocolVersion") or DEFAULT_PROTOCOL
        _result(msg_id, {
            "protocolVersion": proto,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
        })
    elif method == "notifications/initialized":
        pass  # notification; no response
    elif method == "ping":
        _result(msg_id, {})
    elif method == "tools/list":
        _result(msg_id, {"tools": TOOLS})
    elif method == "tools/call":
        params = req.get("params") or {}
        name = params.get("name")
        args = params.get("arguments") or {}
        func = TOOL_FUNCS.get(name)
        if func is None:
            _error(msg_id, -32602, "Unknown tool: %s" % name)
            return
        try:
            is_error, text = func(args)
        except Exception as exc:  # noqa: BLE001 - report tool failures as content
            is_error, text = True, "tool error: %s" % exc
        _result(msg_id, {"content": [{"type": "text", "text": text}], "isError": bool(is_error)})
    elif method in ("resources/list",):
        _result(msg_id, {"resources": []})
    elif method in ("prompts/list",):
        _result(msg_id, {"prompts": []})
    elif msg_id is not None:
        _error(msg_id, -32601, "Method not found: %s" % method)
    # else: unknown notification -> ignore


def serve():
    """Run the MCP stdio server loop (default mode; launched by Claude Desktop)."""
    log("starting", SERVER_VERSION, "support_dir=%s" % SUPPORT_DIR)
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except ValueError as exc:
            log("ignoring non-JSON line:", exc)
            continue
        try:
            if isinstance(req, list):
                for item in req:
                    handle(item)
            else:
                handle(req)
        except Exception as exc:  # never let one bad message kill the server
            log("handler error:", exc)
    log("stdin closed; exiting")


# --- Installer (run once from a terminal: python3 codeboss-host.py --install) ---
#
# The install step exists because Cowork is sandboxed and cannot register the
# connector itself -- a host-side terminal run does it. It is location-agnostic:
# it discovers the Claude Desktop config directory rather than hardcoding a path.

BUNDLE = ["dispatch.sh", "run-phase.sh", "send-claude-message.sh", "codeboss-host.py"]


def _chmod_x(path):
    os.chmod(path, os.stat(path).st_mode | 0o111)


def discover_config_dirs():
    """Return the Claude Desktop config directory/directories to install into.

    CODEBOSS_CLAUDE_CONFIG_DIR (if set) takes precedence -- an explicit escape
    hatch if the location is nonstandard or the app dir is renamed in future.
    Otherwise auto-discover directories under ~/Library/Application Support whose
    name begins with "Claude" and that contain a Claude Desktop config file.
    Nothing is hardcoded to a single path.
    """
    override = os.environ.get("CODEBOSS_CLAUDE_CONFIG_DIR")
    if override:
        d = os.path.expanduser(override)
        return [d] if os.path.isdir(d) else []
    base = os.path.expanduser("~/Library/Application Support")
    dirs = []
    try:
        for name in sorted(os.listdir(base)):
            if not name.lower().startswith("claude"):
                continue
            d = os.path.join(base, name)
            if os.path.isdir(d) and (
                os.path.isfile(os.path.join(d, "claude_desktop_config.json"))
                or os.path.isfile(os.path.join(d, "config.json"))
            ):
                dirs.append(d)
    except OSError:
        pass
    return dirs


def _deploy_bundle():
    """Copy the CodeBoss macOS scripts + this connector into the support dir."""
    src_dir = os.path.dirname(os.path.abspath(__file__))
    os.makedirs(SUPPORT_DIR, exist_ok=True)
    done = []
    for fn in BUNDLE:
        src = os.path.join(src_dir, fn)
        dst = os.path.join(SUPPORT_DIR, fn)
        if os.path.abspath(src) != os.path.abspath(dst) and os.path.isfile(src):
            shutil.copy2(src, dst)
        if os.path.isfile(dst):
            _chmod_x(dst)
            done.append(fn)
    return done


def _register(cfg_dir):
    """Merge the codeboss-host entry into a config dir's mcpServers (backs up).

    mcpServers always belongs in claude_desktop_config.json (config.json is
    separate app state), so we write/create that file even when the directory was
    discovered via config.json.
    """
    cfg_path = os.path.join(cfg_dir, "claude_desktop_config.json")
    cfg = {}
    if os.path.isfile(cfg_path):
        shutil.copy2(cfg_path, "%s.codeboss-bak-%d" % (cfg_path, int(time.time())))
        try:
            with open(cfg_path) as f:
                cfg = json.load(f)
        except ValueError:
            cfg = {}
    cfg.setdefault("mcpServers", {})["codeboss-host"] = {
        "command": "/usr/bin/python3",
        "args": [os.path.join(SUPPORT_DIR, "codeboss-host.py")],
    }
    with open(cfg_path, "w") as f:
        json.dump(cfg, f, indent=2)
    return cfg_path


def _unregister(cfg_dir):
    cfg_path = os.path.join(cfg_dir, "claude_desktop_config.json")
    if not os.path.isfile(cfg_path):
        return None
    try:
        with open(cfg_path) as f:
            cfg = json.load(f)
    except ValueError:
        return None
    if "codeboss-host" not in cfg.get("mcpServers", {}):
        return None
    shutil.copy2(cfg_path, "%s.codeboss-bak-%d" % (cfg_path, int(time.time())))
    del cfg["mcpServers"]["codeboss-host"]
    if not cfg["mcpServers"]:
        cfg.pop("mcpServers", None)
    with open(cfg_path, "w") as f:
        json.dump(cfg, f, indent=2)
    return cfg_path


def cli(mode):
    if mode in ("--help", "-h"):
        print("Usage: codeboss-host.py [--install | --uninstall | --status]")
        print("  (no args)   run as the MCP server (how Claude Desktop launches it)")
        return 0
    if mode == "--status":
        is_error, text = tool_status({})
        print(text)
        return 1 if is_error else 0

    dirs = discover_config_dirs()
    if not dirs:
        override = os.environ.get("CODEBOSS_CLAUDE_CONFIG_DIR")
        if override:
            print("CODEBOSS_CLAUDE_CONFIG_DIR is set to %r but that directory does "
                  "not exist. Fix the path and re-run." % os.path.expanduser(override))
        else:
            print("No Claude Desktop config directory found under "
                  "~/Library/Application Support/Claude*.")
            print("If yours is in a nonstandard location, set CODEBOSS_CLAUDE_CONFIG_DIR "
                  "to it and re-run.")
        return 1

    if mode == "--install":
        print("Deployed to %s:\n  %s" % (SUPPORT_DIR, ", ".join(_deploy_bundle())))
        for d in dirs:
            print("Registered codeboss-host in %s" % _register(d))
        print("\nNext steps:")
        print("  1. Open Claude Desktop (it reads this config at launch). If it was")
        print("     running during install, fully quit (Cmd+Q) and reopen; if codeboss-host")
        print("     is still missing, quit Claude Desktop first and re-run --install.")
        print("  2. Grant Accessibility to Claude: System Settings > Privacy & "
              "Security > Accessibility.")
        print("  3. In Cowork, run the codeboss_status tool "
              "(expect 'claude auth: detected').")
        return 0

    if mode == "--uninstall":
        for d in dirs:
            path = _unregister(d)
            print("Removed codeboss-host from %s" % path if path else
                  "codeboss-host not present in %s"
                  % os.path.join(d, "claude_desktop_config.json"))
        print("Deployed scripts left in %s (remove manually if desired). "
              "Restart Claude Desktop." % SUPPORT_DIR)
        return 0

    print("Unknown option: %s (try --help)" % mode)
    return 2


def main():
    if len(sys.argv) > 1 and sys.argv[1].startswith("-"):
        return cli(sys.argv[1])
    serve()
    return 0


if __name__ == "__main__":
    sys.exit(main())

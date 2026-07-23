#!/usr/bin/env python3
"""codeboss-host.py - macOS host connector for CodeBoss (MCP server).

Cowork runs in a sandboxed VM and cannot touch the host Mac or the local
Claude Desktop UI. This is the macOS analog of the Windows OS connector
(~~windows-os): a small MCP server that Claude Desktop launches ON THE HOST
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
import re
import shutil
import signal
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


def _dedupe_path(path):
    """Collapse duplicate PATH entries (the login PATH usually already has the
    HOST_PATH dirs, so a naive prepend would double them)."""
    seen = set()
    out = []
    for part in path.split(":"):
        if part and part not in seen:
            seen.add(part)
            out.append(part)
    return ":".join(out)


def _kill_group(proc):
    """Terminate a child's whole process group (SIGTERM, then SIGKILL)."""
    try:
        pgid = os.getpgid(proc.pid)
    except OSError:
        return
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(pgid, sig)
        except OSError:
            return
        try:
            proc.communicate(timeout=5)
            return
        except subprocess.TimeoutExpired:
            continue


def _run(cmd_args, timeout):
    """Run a fixed argument list (never a shell string) and capture output.

    Runs in its own process group so a sync-mode timeout can terminate the WHOLE
    tree. subprocess would otherwise kill only the immediate bash child, orphaning
    the grandchild claude CLI (running with --dangerously-skip-permissions) to keep
    executing unmonitored after we have already returned an error to the supervisor.
    """
    env = dict(login_env())  # user's real shell env: auth vars, PATH, locale, ...
    env["PATH"] = _dedupe_path(HOST_PATH + ":" + env.get("PATH", ""))
    try:
        proc = subprocess.Popen(
            cmd_args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            env=env, stdin=subprocess.DEVNULL, start_new_session=True,
        )
    except Exception as exc:  # noqa: BLE001 - surface any spawn failure as text
        return 1, "", "failed to run: %s" % exc
    try:
        out, err = proc.communicate(timeout=timeout)
        return proc.returncode, out or "", err or ""
    except subprocess.TimeoutExpired:
        _kill_group(proc)
        return 124, "", "timed out after %ss (process group terminated)" % timeout


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
        "inputSchema": {
            "type": "object",
            "properties": {
                "refresh": {
                    "type": "boolean",
                    "description": "Re-capture the login-shell environment before checking "
                                   "(use after logging in or editing your shell rc file).",
                    "default": False,
                },
            },
        },
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
    if not os.path.isdir(project_dir):
        return True, "project_dir does not exist or is not a directory: %r" % project_dir
    if not os.path.isfile(DISPATCH):
        return True, (
            "dispatch.sh not found at %s. Run the CodeBoss macOS install/bootstrap first."
            % DISPATCH
        )

    mode = args.get("mode", "async")
    if not isinstance(mode, str) or mode.lower() not in ("async", "sync"):
        return True, "mode must be 'async' or 'sync' (got %r)." % mode
    mode = mode.lower()
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
    if args.get("refresh"):
        global _LOGIN_ENV
        _LOGIN_ENV = None
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

    le = login_env()
    # Resolve claude the way run-phase.sh does: the recovered login PATH first
    # (covers nvm/volta/asdf/custom installs), then the common fallback dirs.
    search_path = HOST_PATH + ":" + le.get("PATH", "")
    claude = shutil.which("claude", path=search_path) or next(
        (c for c in CLAUDE_CANDIDATES if os.access(c, os.X_OK)), None)
    if not claude:
        # Final fallback, matching run-phase.sh: $(npm config get prefix)/bin/claude.
        try:
            # Minimal env for the probe: do not hand the user's full shell
            # environment (which may hold unrelated secrets) to npm. npm only
            # needs PATH (to be found) and HOME / npm_config_* (to resolve prefix).
            npm_env = {
                "PATH": search_path,
                "HOME": le.get("HOME", os.path.expanduser("~")),
            }
            for k, v in le.items():
                if k.lower().startswith("npm_config"):
                    npm_env[k] = v
            prefix = subprocess.run(
                ["npm", "config", "get", "prefix"],
                capture_output=True, text=True, timeout=10, env=npm_env,
                stdin=subprocess.DEVNULL,
            ).stdout.strip()
            cand = os.path.join(prefix, "bin", "claude") if prefix else ""
            if cand and os.access(cand, os.X_OK):
                claude = cand
        except Exception:  # noqa: BLE001 - fallback only; ignore npm failures
            pass
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
    # Only consider real regular files that stay inside the ops dir. Skip symlinks
    # and broken/irregular entries up front -- never follow one out, and never let
    # a planted broken symlink turn this into an error instead of a clean tail.
    candidates = []
    for p in glob.glob(os.path.join(ops_dir, "runner-*.log")):
        try:
            if os.path.islink(p):
                continue
            real = os.path.realpath(p)
            if real.startswith(ops_dir + os.sep) and os.path.isfile(real):
                candidates.append((os.path.getmtime(real), real))
        except OSError:
            continue
    if not candidates:
        return True, "No readable runner logs found under %s" % ops_dir
    candidates.sort()
    latest = candidates[-1][1]
    try:
        n = int(args.get("lines", 40) or 40)
    except (TypeError, ValueError):
        n = 40
    try:
        with open(latest, "r", errors="replace") as fh:
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
    if not isinstance(method, str):
        _error(msg_id, -32600, "Invalid Request: missing or non-string 'method'")
        return
    params = req.get("params")
    if params is not None and not isinstance(params, dict):
        _error(msg_id, -32602, "Invalid params: expected an object")
        return

    # Notifications (no id) must never receive a response. This server acts on none
    # of them (notifications/initialized is a no-op), so ignore them silently.
    if msg_id is None:
        return

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
            log("parse error:", exc)
            _error(None, -32700, "Parse error")
            continue
        try:
            if isinstance(req, list):
                if not req:
                    _error(None, -32600, "Invalid Request: empty batch")
                else:
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
    Otherwise auto-discover directories under ~/Library/Application Support named
    exactly "Claude" or "Claude-<variant>" (e.g. a beta build) that already contain
    a claude_desktop_config.json. We deliberately do NOT match on config.json alone
    or on arbitrary "Claude*" names, to avoid wiring the connector into an unrelated
    app or creating a config file in a directory that never had one. Nothing is
    hardcoded to a single path.
    """
    override = os.environ.get("CODEBOSS_CLAUDE_CONFIG_DIR")
    if override:
        d = os.path.expanduser(override)
        return [d] if os.path.isdir(d) else []
    base = os.path.expanduser("~/Library/Application Support")
    dirs = []
    try:
        for name in sorted(os.listdir(base)):
            if not re.match(r"^Claude(-[A-Za-z0-9._-]+)?$", name):
                continue
            d = os.path.join(base, name)
            if os.path.isdir(d) and os.path.isfile(
                os.path.join(d, "claude_desktop_config.json")
            ):
                dirs.append(d)
    except OSError:
        pass
    return dirs


def _deploy_bundle():
    """Copy the CodeBoss macOS scripts + this connector into the support dir.

    Returns (deployed, problems): deployed lists files now present + executable in
    the support dir; problems notes any bundle file whose source was missing, so a
    stale pre-existing copy is not falsely reported as freshly deployed.
    """
    src_dir = os.path.dirname(os.path.abspath(__file__))
    os.makedirs(SUPPORT_DIR, exist_ok=True)
    deployed = []
    problems = []
    for fn in BUNDLE:
        src = os.path.join(src_dir, fn)
        dst = os.path.join(SUPPORT_DIR, fn)
        if os.path.abspath(src) != os.path.abspath(dst):
            if os.path.isfile(src):
                shutil.copy2(src, dst)
            elif os.path.isfile(dst):
                problems.append("%s (source missing; kept existing copy)" % fn)
            else:
                problems.append("%s (source missing; NOT deployed)" % fn)
                continue
        if os.path.isfile(dst):
            _chmod_x(dst)
            deployed.append(fn)
    return deployed, problems


def _register(cfg_dir):
    """Merge the codeboss-host entry into a config dir's mcpServers (backs up).

    mcpServers always belongs in claude_desktop_config.json (config.json is
    separate app state), so we write/create that file even when the directory was
    discovered via config.json.
    """
    cfg_path = os.path.join(cfg_dir, "claude_desktop_config.json")
    cfg = {}
    if os.path.isfile(cfg_path):
        with open(cfg_path) as f:
            raw = f.read()
        if raw.strip():
            try:
                cfg = json.loads(raw)
            except ValueError as exc:
                raise RuntimeError(
                    "%s is not valid JSON (%s). Left untouched; fix or remove it, "
                    "then re-run --install." % (cfg_path, exc))
            if not isinstance(cfg, dict):
                raise RuntimeError(
                    "%s does not contain a JSON object; left untouched." % cfg_path)
        existing = cfg.get("mcpServers")
        if existing is not None and not isinstance(existing, dict):
            raise RuntimeError(
                "%s has a non-object 'mcpServers'; left untouched." % cfg_path)
        # Back up only after we know the existing file parses and is safe to edit.
        shutil.copy2(cfg_path, "%s.codeboss-bak-%d" % (cfg_path, int(time.time())))
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
    if not isinstance(cfg, dict):
        return None
    servers = cfg.get("mcpServers")
    if not isinstance(servers, dict) or "codeboss-host" not in servers:
        return None
    shutil.copy2(cfg_path, "%s.codeboss-bak-%d" % (cfg_path, int(time.time())))
    del servers["codeboss-host"]
    if not servers:
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
        if len(dirs) > 1 and not os.environ.get("CODEBOSS_CLAUDE_CONFIG_DIR"):
            print("Multiple Claude Desktop config directories were found:")
            for d in dirs:
                print("  " + d)
            print("Refusing to register into all of them. Set CODEBOSS_CLAUDE_CONFIG_DIR "
                  "to the one your Claude Desktop uses, then re-run --install.")
            return 1
        deployed, problems = _deploy_bundle()
        print("Deployed to %s:\n  %s" % (SUPPORT_DIR, ", ".join(deployed)))
        for p in problems:
            print("  WARNING: %s" % p)
        failed = False
        for d in dirs:
            try:
                print("Registered codeboss-host in %s" % _register(d))
            except RuntimeError as exc:
                print("SKIPPED %s: %s" % (d, exc))
                failed = True
        print("\nNext steps:")
        print("  1. Open Claude Desktop (it reads this config at launch). If it was")
        print("     running during install, fully quit (Cmd+Q) and reopen; if codeboss-host")
        print("     is still missing, quit Claude Desktop first and re-run --install.")
        print("  2. Grant Accessibility to Claude: System Settings > Privacy & "
              "Security > Accessibility.")
        print("  3. In Cowork, run the codeboss_status tool "
              "(expect 'claude auth: detected').")
        return 1 if failed else 0

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

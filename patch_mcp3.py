#!/usr/bin/env python3
"""Fall back to the HTTP User-Agent when MCP-level client info is unavailable.

Observed: this client opens a fresh session per tool call and never re-sends
clientInfo, so events outside initialize had no client at all. The User-Agent
header rides on every HTTP message and is independent of MCP session state.
"""
import sys
from pathlib import Path

p = Path("agent/mcp_server.py")
if not p.exists():
    print("!! run from the repo root"); sys.exit(1)
s = p.read_text(encoding="utf-8")

OLD = '''    if info is None:
        return None
    try:
        if isinstance(info, dict):
            name, version = info.get("name"), info.get("version")
        else:
            name, version = getattr(info, "name", None), getattr(info, "version", None)
        return "{}/{}".format(name or "unknown", version or "?")
    except Exception:
        return None
'''

NEW = '''    if info is None:
        # No MCP-level identity on this message. The User-Agent is on every
        # HTTP request regardless of session state, so use it rather than
        # recording nothing.
        try:
            ua = ctx.request.headers.get("user-agent")
            if ua:
                return "ua:{}".format(ua[:80])
        except Exception:
            pass
        return None
    try:
        if isinstance(info, dict):
            name, version = info.get("name"), info.get("version")
        else:
            name, version = getattr(info, "name", None), getattr(info, "version", None)
        return "{}/{}".format(name or "unknown", version or "?")
    except Exception:
        return None
'''

if OLD not in s:
    print("!! could not find the client fallback block; file left untouched"); sys.exit(1)

bak = Path("agent/mcp_server.py.patchbak3")
if not bak.exists():
    bak.write_text(s, encoding="utf-8"); print(f"backup -> {bak}")

p.write_text(s.replace(OLD, NEW, 1), encoding="utf-8")
print("agent/mcp_server.py patched")

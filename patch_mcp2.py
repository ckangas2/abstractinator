#!/usr/bin/env python3
"""Attribute every event in a session, even when the client omits the header.

Observed: this client re-initializes per tool call and sends no Mcp-Session-Id
on tools/call, so the header is absent and ctx.session.client_params is empty
there. The ServerSession object itself is stable for the life of the session,
so remember identity against it and fill in whatever the request did not carry.
"""
import sys
from pathlib import Path

p = Path("agent/mcp_server.py")
if not p.exists():
    print("!! run from the repo root"); sys.exit(1)
s = p.read_text(encoding="utf-8")

ANCHOR = '''EVENT_NAMES = {'''
NEW = '''# Identity remembered against the ServerSession object. A client may omit the
# Mcp-Session-Id header on some messages (and client_params is only populated
# after initialize), so the first message that does carry a value fills in for
# the rest of that session. Bounded so a long-lived process cannot grow without
# limit.
_SESSION_CACHE_MAX = 4096
_session_cache = {}


def _identity(ctx):
    """(session, client) for this message, filled in from the session cache."""
    sid = _session_from(ctx)
    cli = _client_from(ctx)

    key = None
    try:
        key = id(ctx.session)
    except Exception:
        key = None

    if key is not None:
        if len(_session_cache) > _SESSION_CACHE_MAX:
            _session_cache.clear()
        rec = _session_cache.setdefault(key, {"session": None, "client": None})
        if sid:
            rec["session"] = sid
        if cli:
            rec["client"] = cli
        sid = sid or rec["session"]
        cli = cli or rec["client"]
        # No header anywhere in this session: derive a stable handle from the
        # session object so distinct sessions remain countable.
        if sid is None:
            sid = _hash_session("obj-{}".format(key))
            rec["session"] = sid

    return sid, cli


EVENT_NAMES = {'''

OLD_CALL = '''    method = session = client = None
    try:
        method = getattr(ctx, "method", None)
        session = _session_from(ctx)
        client = _client_from(ctx)
    except Exception:
        if CTX_DEBUG:
            traceback.print_exc()
'''
NEW_CALL = '''    method = session = client = None
    try:
        method = getattr(ctx, "method", None)
        session, client = _identity(ctx)
    except Exception:
        if CTX_DEBUG:
            traceback.print_exc()
'''

for label, needle in (("EVENT_NAMES anchor", ANCHOR), ("middleware body", OLD_CALL)):
    if needle not in s:
        print(f"!! could not find {label}; file left untouched"); sys.exit(1)

bak = Path("agent/mcp_server.py.patchbak2")
if not bak.exists():
    bak.write_text(s, encoding="utf-8"); print(f"backup -> {bak}")

s = s.replace(ANCHOR, NEW, 1)
s = s.replace(OLD_CALL, NEW_CALL, 1)
p.write_text(s, encoding="utf-8")
print("agent/mcp_server.py patched")

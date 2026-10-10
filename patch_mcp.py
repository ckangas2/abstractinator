#!/usr/bin/env python3
"""Correct the MCP usage middleware now that the real ctx shape is known.

Two fixes:
  1. Session id comes from the Mcp-Session-Id header on ctx.request; the client
     comes from ctx.session.client_params. The previous version guessed at
     attribute names and found neither.
  2. Identity is carried in contextvars set BEFORE the handler runs. The
     previous version set module globals AFTER it, so a search was attributed
     to whichever client connected most recently - real usage was being logged
     as probe traffic.
"""
import sys
from pathlib import Path

p = Path("agent/mcp_server.py")
if not p.exists():
    print("!! agent/mcp_server.py not found - run from the repo root"); sys.exit(1)
s = p.read_text(encoding="utf-8")

OLD_IMPORTS = "import hashlib\nimport json\nimport os\n"
NEW_IMPORTS = "import contextlib\nimport contextvars\nimport hashlib\nimport json\nimport os\n"

NEW_BLOCK = '''# The middleware context is mcp.server.context.ServerRequestContext:
#
#   ctx.method                     e.g. "tools/call"
#   ctx.params                     plain dict of the request params
#   ctx.request                    starlette Request -> .headers
#   ctx.session.client_params      the initialize params, for the whole session
#
# The session id is a transport concern and lives in the Mcp-Session-Id header.
# It is absent on the initialize request itself, because the server assigns it
# in that response - so initialize events carry no session, and every later
# message in the same session does.
SESSION_HEADER = "mcp-session-id"


def _session_from(ctx):
    try:
        return _hash_session(ctx.request.headers.get(SESSION_HEADER))
    except Exception:
        return None


def _client_from(ctx):
    """'name/version' of the connected client, or None.

    Preferred source is ctx.session.client_params, which the SDK keeps for the
    life of the session. On the initialize message itself that is not populated
    yet, so fall back to the request's own params.
    """
    info = None
    try:
        info = ctx.session.client_params.clientInfo
    except Exception:
        info = None
    if info is None:
        try:
            params = ctx.params or {}
            info = params.get("clientInfo") or params.get("client_info")
        except Exception:
            info = None
    if info is None:
        return None
    try:
        if isinstance(info, dict):
            name, version = info.get("name"), info.get("version")
        else:
            name, version = getattr(info, "name", None), getattr(info, "version", None)
        return "{}/{}".format(name or "unknown", version or "?")
    except Exception:
        return None


def _debug_dump(ctx):
    global _ctx_debug_done
    if not CTX_DEBUG or _ctx_debug_done:
        return
    _ctx_debug_done = True
    try:
        print("[mcp-log] ctx type:", type(ctx), flush=True)
        print("[mcp-log] ctx attrs:",
              sorted(a for a in dir(ctx) if not a.startswith("_")), flush=True)
        for probe in ("message", "request", "params", "session", "scope"):
            sub = getattr(ctx, probe, None)
            if sub is not None:
                print("[mcp-log]  .{}: {} -> {}".format(
                    probe, type(sub),
                    sorted(a for a in dir(sub) if not a.startswith("_"))[:40]),
                    flush=True)
    except Exception:
        traceback.print_exc()


# Per-task storage, so a concurrent request cannot read another's identity.
# An earlier version used module-level globals set *after* the handler ran,
# which attributed one client's search to whichever client connected last -
# real usage was being logged as probe traffic.
_ctx_session: contextvars.ContextVar = contextvars.ContextVar(
    "abstractinator_session", default=None)
_ctx_client: contextvars.ContextVar = contextvars.ContextVar(
    "abstractinator_client", default=None)

EVENT_NAMES = {
    "initialize": "initialize",
    "tools/list": "tools_list",
    "tools/call": "tools_call",
    "notifications/initialized": "initialized",
    "ping": "ping",
}


async def usage_logging_middleware(ctx, call_next):
    """Log one event per inbound MCP message, then pass it through untouched."""
    _debug_dump(ctx)

    method = session = client = None
    try:
        method = getattr(ctx, "method", None)
        session = _session_from(ctx)
        client = _client_from(ctx)
    except Exception:
        if CTX_DEBUG:
            traceback.print_exc()

    # Set BEFORE the handler runs, so search_literature sees this request's
    # identity rather than the previous message's.
    tok_s = _ctx_session.set(session)
    tok_c = _ctx_client.set(client)

    t0 = time.perf_counter()
    try:
        try:
            result = await call_next(ctx)
        except Exception:
            _safe_log_event(method, session, client, t0, "error")
            raise
        _safe_log_event(method, session, client, t0, "ok")
        return result
    finally:
        with contextlib.suppress(Exception):
            _ctx_session.reset(tok_s)
            _ctx_client.reset(tok_c)


def _safe_log_event(method, session, client, t0, status):
    try:
        event = EVENT_NAMES.get(method, method or "other")

        # Keep-alive chatter would otherwise swamp the funnel: ~2,000 /mcp
        # requests produced 5 real searches, mostly pings and reconnects.
        if event == "ping":
            return

        _write_event(
            event=event,
            channel=_channel_for(client),
            session=session,
            client=client,
            duration=round(time.perf_counter() - t0, 3),
            status=status,
        )
    except Exception:
        if CTX_DEBUG:
            traceback.print_exc()


'''

OLD_HDR = '''    headers = {}
    try:
        if _current_session.get("session"):
            headers["X-Session-Id"] = _current_session["session"]
        if _current_session.get("client"):
            headers["X-Client-Name"] = _current_session["client"]
    except Exception:
        pass
'''

NEW_HDR = '''    headers = {}
    try:
        sess, cli = _ctx_session.get(), _ctx_client.get()
        if sess:
            headers["X-Session-Id"] = sess
        if cli:
            headers["X-Client-Name"] = cli
    except Exception:
        pass
'''

MARK_START = "def _first_attr(obj, *names):"
MARK_END = "# --------------------------------------------------------------------------- #\n# server"

for label, needle in (("imports", OLD_IMPORTS), ("extraction block", MARK_START),
                      ("server marker", MARK_END), ("header block", OLD_HDR)):
    if needle not in s:
        print(f"!! could not find {label}; file left untouched"); sys.exit(1)

bak = Path("agent/mcp_server.py.patchbak")
if not bak.exists():
    bak.write_text(s, encoding="utf-8"); print(f"backup -> {bak}")

s = s.replace(OLD_IMPORTS, NEW_IMPORTS, 1)
a, b = s.index(MARK_START), s.index(MARK_END)
s = s[:a] + NEW_BLOCK + s[b:]
s = s.replace(OLD_HDR, NEW_HDR, 1)

for gone in ("_current_session", "_session_clients", "_first_attr", "_extract("):
    if gone in s:
        print(f"!! {gone} still present after patch; not writing"); sys.exit(1)

p.write_text(s, encoding="utf-8")
print("agent/mcp_server.py patched")

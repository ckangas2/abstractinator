"""
agent/mcp_server.py  (MCP Python SDK 2.x)
MCP server exposing The Abstractinator as tools for AI agents.
Talks to the local REST API (agent/api.R) and serves MCP over streamable HTTP
at http://127.0.0.1:8200/mcp (published via Cloudflare as https://mcp.abstractinator.me/mcp).
Only open-access sources are used here, so no one's API keys are ever spent.

Usage logging
-------------
A middleware records one JSON event per inbound MCP message into the same log
store the R side reads (R/log_utils_local.R), so the funnel is visible:

    initialize   a client connected
    tools_list   it asked what tools exist
    tools_call   it actually called one

A wide gap between tools_list and tools_call points at the tool description,
not at discovery. Completed searches are logged separately by agent/api.R; the
session id is forwarded to it so the two can be joined.

Nothing identifying is stored: the session id comes from the MCP transport, and
no IP address is ever recorded (see SECURITY.md).

Logging must never break serving. Every logging path is wrapped, and a failure
degrades to missing analytics rather than a failed request. The middleware API
is marked provisional in SDK 2.x, so attribute lookups are defensive.
"""
import hashlib
import json
import os
import time
import traceback
import uuid
from datetime import datetime, timezone
from pathlib import Path

import httpx2
from mcp.server.mcpserver import MCPServer
from mcp.types import ToolAnnotations
from mcp.server.transport_security import TransportSecuritySettings

API_URL = os.environ.get("ABSTRACTINATOR_API", "http://127.0.0.1:8100")
PORT = int(os.environ.get("MCP_PORT", "8200"))
PUBLIC_HOST = os.environ.get("MCP_PUBLIC_HOST", "mcp.abstractinator.me")

LOG_DIR = Path(
    os.environ.get(
        "ABSTRACTINATOR_LOG_DIR",
        "/srv/shiny-server/abstractinator/.cache/s3_mimic/logs",
    )
)

# Set MCP_LOG_CTX_DEBUG=1 to dump the middleware context's attributes once, so
# the extraction below can be corrected if a future SDK release moves things.
CTX_DEBUG = os.environ.get("MCP_LOG_CTX_DEBUG", "") == "1"
_ctx_debug_done = False

# Client names we treat as our own traffic rather than real usage.
OUR_CLIENTS = ("uptime-probe", "abstractinator-probe", "curl", "python-httpx")


# --------------------------------------------------------------------------- #
# logging
# --------------------------------------------------------------------------- #
def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _hash_session(raw):
    """Short, stable, non-reversible handle for a session id.

    The raw transport session id is not stored: it is a bearer-ish value and we
    only need to count distinct sessions and join a search to its connection.
    """
    if not raw:
        return None
    return hashlib.sha256(str(raw).encode("utf-8")).hexdigest()[:16]


def _channel_for(client_name) -> str:
    name = (client_name or "").lower()
    if any(tag in name for tag in OUR_CLIENTS):
        return "probe"
    return "agent"


def _write_event(**fields) -> None:
    """Append one JSON event. Mirrors the schema in R/log_utils_local.R."""
    try:
        record = {
            "timestamp": _now_iso(),
            "event": None,
            "channel": None,
            "session": None,
            "client": None,
            "term": None,
            "deep": None,
            "max_results": None,
            "abstract_chars": None,
            "total_found": None,
            "returned": None,
            "n_results": None,
            "from_cache": None,
            "duration": None,
            "sources": None,
            "source": "MCP",
            "status": "ok",
            "has_elsevier": False,
            "has_uspto": False,
            "has_core": False,
        }
        record.update(fields)

        day = LOG_DIR / datetime.now(timezone.utc).strftime("%Y-%m-%d")
        day.mkdir(parents=True, exist_ok=True)
        path = day / "{}_{}_{}.json".format(
            record.get("event") or "event", time.time(), uuid.uuid4()
        )
        path.write_text(json.dumps(record, indent=2), encoding="utf-8")
    except Exception:
        # Never let logging break a request.
        if CTX_DEBUG:
            traceback.print_exc()


# --------------------------------------------------------------------------- #
# middleware
# --------------------------------------------------------------------------- #
def _first_attr(obj, *names):
    """Return the first present, non-empty attribute (or mapping key)."""
    for name in names:
        try:
            if obj is None:
                return None
            if isinstance(obj, dict):
                if obj.get(name) not in (None, ""):
                    return obj.get(name)
                continue
            val = getattr(obj, name, None)
            if val not in (None, ""):
                return val
        except Exception:
            continue
    return None


def _extract(ctx) -> dict:
    """Pull method / session / client out of the middleware context.

    The middleware signature is provisional, so every lookup is a best effort
    across the shapes the SDK has plausibly used. Unknown values log as None
    rather than raising.
    """
    global _ctx_debug_done
    if CTX_DEBUG and not _ctx_debug_done:
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

    method = _first_attr(ctx, "method")
    if method is None:
        msg = _first_attr(ctx, "message", "request", "req")
        method = _first_attr(msg, "method")
        if method is None:
            root = _first_attr(msg, "root")
            method = _first_attr(root, "method")

    session_raw = _first_attr(ctx, "session_id", "sessionId")
    if session_raw is None:
        sess = _first_attr(ctx, "session")
        session_raw = _first_attr(sess, "session_id", "sessionId", "id")

    # clientInfo only arrives on initialize; remember it for the session.
    client = None
    params = _first_attr(ctx, "params")
    if params is None:
        msg = _first_attr(ctx, "message", "request", "req")
        params = _first_attr(msg, "params")
        if params is None:
            params = _first_attr(_first_attr(msg, "root"), "params")
    ci = _first_attr(params, "clientInfo", "client_info")
    if ci is not None:
        cname = _first_attr(ci, "name") or "unknown"
        cver = _first_attr(ci, "version") or "?"
        client = "{}/{}".format(cname, cver)

    return {
        "method": str(method) if method else None,
        "session": _hash_session(session_raw),
        "client": client,
    }


# Maps hashed session -> "name/version", so tools_call events and the forwarded
# search can be attributed to the client that introduced itself at initialize.
_session_clients = {}

EVENT_NAMES = {
    "initialize": "initialize",
    "tools/list": "tools_list",
    "tools/call": "tools_call",
    "notifications/initialized": "initialized",
    "ping": "ping",
}


async def usage_logging_middleware(ctx, call_next):
    """Log one event per inbound MCP message, then pass it through untouched."""
    info = {}
    try:
        info = _extract(ctx)
        if info.get("session") and info.get("client"):
            _session_clients[info["session"]] = info["client"]
    except Exception:
        if CTX_DEBUG:
            traceback.print_exc()

    t0 = time.perf_counter()
    try:
        result = await call_next(ctx)
    except Exception:
        _safe_log_event(info, t0, status="error")
        raise
    _safe_log_event(info, t0, status="ok")
    return result


def _safe_log_event(info, t0, status):
    try:
        method = info.get("method")
        session = info.get("session")
        client = info.get("client") or (_session_clients.get(session) if session else None)
        event = EVENT_NAMES.get(method, method or "other")

        # Keep-alive chatter would otherwise swamp the funnel: ~2,000 /mcp
        # requests produced 5 real searches, mostly pings and reconnects.
        if event in ("ping",):
            return

        # Expose the session to the request-scoped tool call below.
        _current_session.update({"session": session, "client": client})

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


# Last-seen session/client, used to tag the outgoing API call. Requests are
# handled one message at a time per connection, so this is adequate for
# attribution; it is not relied on for correctness.
_current_session = {"session": None, "client": None}


# --------------------------------------------------------------------------- #
# server
# --------------------------------------------------------------------------- #
mcp = MCPServer(
    "Abstractinator",
    instructions=(
        "Searches immunology and virology literature across Europe PMC, OpenAlex, "
        "ClinicalTrials.gov, bioRxiv/medRxiv, NIH RePORTER grants and NSF awards, "
        "deduplicated and tagged by immune cell type, virus and bacterium."
    ),
    version="1.0.0",
)

# Outermost-first: appending puts us inside the SDK's own OpenTelemetry and
# request-state middleware, which is where we want to be - we observe messages
# that have already passed the transport's security checks.
mcp.middleware.append(usage_logging_middleware)


# Annotations are behavioural hints for the client: a read-only search can be
# auto-approved instead of prompting on every call. open_world_hint is True
# because this queries external databases, not a fixed local set.
# (destructive_hint / idempotent_hint are only defined for tools that write.)
@mcp.tool(
    annotations=ToolAnnotations(
        title="Search immunology & virology literature",
        read_only_hint=True,
        open_world_hint=True,
    )
)
async def search_literature(
    query: str, max_results: int = 25, abstract_chars: int = 1500, deep: bool = False
) -> dict:
    """Search immunology/virology literature across several databases at once.

    Queries Europe PMC, OpenAlex, ClinicalTrials.gov, bioRxiv/medRxiv preprints,
    NIH RePORTER grants and NSF awards in parallel, removes duplicates, and tags each
    record with its most prominent immune cell type (primary_cell), virus
    (primary_virus) and bacterium (primary_bacteria). Results are balanced across
    sources. A fresh search takes roughly 5-10 seconds; repeat searches within
    7 days are instant.

    Args:
        query: Search term, e.g. "oncolytic virus", "T-VEC", "NK cell exhaustion".
        max_results: How many records to return (1-100). Default 25.
        abstract_chars: Truncate abstracts to this length; 0 omits them to save space.
        deep: Search more broadly (up to 250 records per database instead of 50).
            Slower (often 20-60 seconds); use for broad topics or when a standard
            search seems to miss relevant work.

    Returns a dict with total_found, returned, source_counts and a results list of
    records (title, abstract, authors, publication_date, doi, url, source,
    primary_cell, primary_virus, is_bioinformatics).
    """
    params = {"q": query, "limit": max_results, "abstract_chars": abstract_chars,
              "deep": "true" if deep else "false"}

    # Forward who is asking so agent/api.R can log the search against this
    # session. Headers, not query params, so the search term stays the only
    # thing in the URL.
    headers = {}
    try:
        if _current_session.get("session"):
            headers["X-Session-Id"] = _current_session["session"]
        if _current_session.get("client"):
            headers["X-Client-Name"] = _current_session["client"]
    except Exception:
        pass

    try:
        async with httpx2.AsyncClient(timeout=180) as client:
            r = await client.get(f"{API_URL}/search", params=params, headers=headers)
    except httpx2.HTTPError as e:
        return {"error": f"The Abstractinator API is unreachable: {e}"}
    if r.status_code == 429:
        return {"error": "Rate limit reached on The Abstractinator. Wait a minute and retry."}
    if r.status_code >= 400:
        return {"error": f"Search failed (HTTP {r.status_code}).", "detail": r.text[:500]}
    return r.json()


if __name__ == "__main__":
    # stateless_http is False so the transport issues real session ids. Without
    # them every request looks like a new client and "N searches across M
    # sessions" cannot be measured - Cloudflare cannot help here either, because
    # Anthropic's egress pool rotates the source IP per request.
    #
    # Bound to localhost; DNS-rebinding protection allows only these Host headers,
    # so requests arriving through the Cloudflare tunnel need our public hostname listed.
    mcp.run(
        transport="streamable-http",
        host="127.0.0.1",
        port=PORT,
        stateless_http=False,
        transport_security=TransportSecuritySettings(
            enable_dns_rebinding_protection=True,
            allowed_hosts=["127.0.0.1:*", "localhost:*", PUBLIC_HOST],
            allowed_origins=["http://127.0.0.1:*", "http://localhost:*", f"https://{PUBLIC_HOST}"],
        ),
    )

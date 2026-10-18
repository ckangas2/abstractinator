#!/usr/bin/env python3
"""Chunk 2b: expose full text over MCP, and document it.

  agent/mcp_server.py
    - get_fulltext tool, forwarding session/client like search does
    - log the TOOL NAME on tools_call; with two tools the funnel is otherwise
      unable to say which one was used
  www/llms.txt
    - document the second tool, and correct the record field list (it omitted
      primary_bacteria, pmcid and is_open_access)
  www/mcp-server-card.json
    - add the tool so discovery reflects reality

Run from the repo root.  --check reports without writing.
"""
import json
import re
import sys
from pathlib import Path

CHECK = "--check" in sys.argv


def tolerant(anchor):
    return re.compile(
        r"[ \t]*\n".join(re.escape(l.rstrip()) for l in anchor.split("\n")) + r"[ \t]*"
    )


# =========================================================== mcp_server.py == #
mcp_path = Path("agent/mcp_server.py")

MCP_EDITS = []

# 1. capture the tool name in the middleware
MCP_EDITS.append((
    "middleware tool name",
    '''    method = session = client = None
    try:
        method = getattr(ctx, "method", None)
        session, client = _identity(ctx)
    except Exception:
        if CTX_DEBUG:
            traceback.print_exc()''',
    '''    method = session = client = tool = None
    try:
        method = getattr(ctx, "method", None)
        session, client = _identity(ctx)
        # Which tool was called. With more than one tool, "tools_call" alone
        # cannot tell search from full text in the funnel.
        if method == "tools/call":
            params = getattr(ctx, "params", None) or {}
            tool = params.get("name") if isinstance(params, dict) else None
    except Exception:
        if CTX_DEBUG:
            traceback.print_exc()''',
))

MCP_EDITS.append((
    "middleware log calls",
    '''    t0 = time.perf_counter()
    try:
        try:
            result = await call_next(ctx)
        except Exception:
            _safe_log_event(method, session, client, t0, "error")
            raise
        _safe_log_event(method, session, client, t0, "ok")
        return result''',
    '''    t0 = time.perf_counter()
    try:
        try:
            result = await call_next(ctx)
        except Exception:
            _safe_log_event(method, session, client, t0, "error", tool)
            raise
        _safe_log_event(method, session, client, t0, "ok", tool)
        return result''',
))

MCP_EDITS.append((
    "log event signature",
    '''def _safe_log_event(method, session, client, t0, status):
    try:
        event = EVENT_NAMES.get(method, method or "other")''',
    '''def _safe_log_event(method, session, client, t0, status, tool=None):
    try:
        event = EVENT_NAMES.get(method, method or "other")''',
))

MCP_EDITS.append((
    "log event body",
    '''        _write_event(
            event=event,
            channel=_channel_for(client),
            session=session,
            client=client,
            duration=round(time.perf_counter() - t0, 3),
            status=status,
        )''',
    '''        _write_event(
            event=event,
            channel=_channel_for(client),
            session=session,
            client=client,
            term=tool,
            duration=round(time.perf_counter() - t0, 3),
            status=status,
        )''',
))

# 2. the tool itself, appended before __main__
MCP_EDITS.append((
    "fulltext tool",
    '''if __name__ == "__main__":''',
    '''@mcp.tool(
    annotations=ToolAnnotations(
        title="Read open-access full text",
        read_only_hint=True,
        open_world_hint=True,
    )
)
async def get_fulltext(
    pmcid: str = "", doi: str = "", max_chars: int = 20000
) -> dict:
    """Read the full text of ONE open-access article from Europe PMC.

    Use this after search_literature, on a result that has a pmcid (or whose
    is_open_access is "Y"). Only the open-access subset can be served: for a
    paywalled article this returns status "not_open_access" rather than an
    error, and the DOI should be followed by hand instead.

    Prefer this over fetching the publisher's page: Europe PMC returns clean
    JATS text, already split into sections, with no navigation or paywall
    interstitials to work around.

    Args:
        pmcid: PMC identifier from a search result, e.g. "PMC5334499".
        doi: DOI, used to look up the PMCID when pmcid is not supplied. Slower
            by one request, and only works if the article is in Europe PMC.
        max_chars: Truncate the returned text. Default 20000, maximum 100000.
            The whole text is cached server-side either way, so asking for more
            later costs nothing.

    Returns a dict with pmcid, status, chars, total_chars, truncated,
    from_cache and full_text. total_chars is the length of the whole article,
    so a truncated response says how much was left unread.
    """
    params = {"max_chars": max_chars}
    if pmcid:
        params["pmcid"] = pmcid
    if doi:
        params["doi"] = doi
    if not pmcid and not doi:
        return {"error": "Supply either pmcid (e.g. PMC5334499) or doi."}

    headers = {}
    try:
        sess, cli = _ctx_session.get(), _ctx_client.get()
        if sess:
            headers["X-Session-Id"] = sess
        if cli:
            headers["X-Client-Name"] = cli
    except Exception:
        pass

    try:
        async with httpx2.AsyncClient(timeout=180) as client:
            r = await client.get(f"{API_URL}/fulltext", params=params, headers=headers)
    except httpx2.HTTPError as e:
        return {"error": f"The Abstractinator API is unreachable: {e}"}
    if r.status_code == 429:
        return {"error": "Full-text rate limit reached. Wait a minute and retry."}
    if r.status_code >= 500:
        # The API returns 502 when Europe PMC itself failed; the body explains.
        try:
            return r.json()
        except Exception:
            return {"error": f"Full-text fetch failed (HTTP {r.status_code})."}
    if r.status_code >= 400:
        return {"error": f"Full-text fetch failed (HTTP {r.status_code}).",
                "detail": r.text[:500]}
    return r.json()


if __name__ == "__main__":''',
))

# ============================================================== llms.txt === #
llms_path = Path("www/llms.txt")

LLMS_EDITS = []

LLMS_EDITS.append((
    "record field list",
    '''Returns: total_found, returned, source_counts, and a results list. Each record
carries title, abstract, authors, publication_date, doi, url, source,
primary_cell, primary_virus and is_bioinformatics.''',
    '''Returns: total_found, returned, source_counts, and a results list. Each record
carries title, abstract, authors, publication_date, doi, url, source,
primary_cell, primary_virus, primary_bacteria, is_bioinformatics, and - for
open-access articles in Europe PMC - pmcid and is_open_access. A record with a
pmcid can be read in full with get_fulltext.

Records with no abstract are kept rather than dropped: a grant award or a trial
registration with no abstract is still a real result, and removing them would
make the per-source counts misleading. They are listed after records that do
have one.

### Tool: get_fulltext

    get_fulltext(pmcid, doi, max_chars=20000)

Reads the full text of ONE open-access article from Europe PMC.

- pmcid: from a search result, e.g. "PMC5334499". Preferred.
- doi: used to look up the PMCID when pmcid is not supplied. One extra request,
  and only works for articles Europe PMC indexes.
- max_chars: truncate the response. Default 20000, maximum 100000. The whole
  text is cached server-side, so reading more later costs nothing.

Only the open-access subset can be served. A paywalled article returns status
"not_open_access" rather than an error; follow its DOI by hand instead. Use
this in preference to fetching a publisher page: the text comes back as clean
JATS sections, with no navigation or paywall interstitials.

Returns pmcid, status, chars, total_chars, truncated, from_cache and full_text.
total_chars is the length of the whole article, so a truncated response says
how much was left unread.

Full-text requests are rate limited separately from searches. The limit exists
to stay within Europe PMC's tolerance - please do not use this to mirror the
open-access corpus; EBI offer bulk downloads for that.''',
))

LLMS_EDITS.append((
    "tool list intro",
    '''### Tool: search_literature''',
    '''Two tools: search_literature to find records, get_fulltext to read one.

### Tool: search_literature''',
))

# ====================================================== mcp-server-card === #
card_path = Path("www/mcp-server-card.json")

NEW_TOOL = {
    "name": "get_fulltext",
    "description": (
        "Read the full text of one open-access article from Europe PMC, given a "
        "pmcid from a search result (or a DOI). Returns clean JATS section text. "
        "Paywalled articles return status not_open_access rather than an error."
    ),
    "annotations": {"readOnlyHint": True, "openWorldHint": True},
}

# ================================================================= apply === #
if not Path("app.R").exists():
    print("!! run from the repo root"); sys.exit(1)

problems = []
for path, edit_list in ((mcp_path, MCP_EDITS), (llms_path, LLMS_EDITS)):
    if not path.exists():
        problems.append(f"{path}: missing"); continue
    src = path.read_text(encoding="utf-8")
    for label, old, _ in edit_list:
        n = len(tolerant(old).findall(src))
        if n != 1:
            problems.append(f"{path}: '{label}' found {n} times, expected 1")

if not card_path.exists():
    problems.append(f"{card_path}: missing")
else:
    try:
        card = json.loads(card_path.read_text(encoding="utf-8"))
        if not isinstance(card.get("tools"), list):
            problems.append(f"{card_path}: no 'tools' array")
        elif any(t.get("name") == "get_fulltext" for t in card["tools"]):
            problems.append(f"{card_path}: get_fulltext already present")
    except Exception as e:
        problems.append(f"{card_path}: not valid JSON ({e})")

if problems:
    print("\n".join("  !! " + p for p in problems))
    print("\nNothing written.")
    sys.exit(1)

print("  ok agent/mcp_server.py: 5 block(s) matched")
print("  ok www/llms.txt: 2 block(s) matched")
print("  ok www/mcp-server-card.json: tools array ready")

if CHECK:
    print("\nAll blocks matched (check only, nothing written).")
    sys.exit(0)

for path, edit_list in ((mcp_path, MCP_EDITS), (llms_path, LLMS_EDITS)):
    src = path.read_text(encoding="utf-8")
    bak = path.with_suffix(path.suffix + ".ft2bak")
    if not bak.exists():
        bak.write_text(src, encoding="utf-8")
    for label, old, new in edit_list:
        src = tolerant(old).sub(lambda _m, _n=new: _n, src, count=1)
    path.write_text(src, encoding="utf-8")
    print(f"  wrote {path}")

card = json.loads(card_path.read_text(encoding="utf-8"))
bak = card_path.with_suffix(".json.ft2bak")
if not bak.exists():
    bak.write_text(json.dumps(card, indent=2) + "\n", encoding="utf-8")
card["tools"].append(NEW_TOOL)
card_path.write_text(json.dumps(card, indent=2) + "\n", encoding="utf-8")
print(f"  wrote {card_path}")

print("\nDone.")

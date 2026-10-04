"""
agent/mcp_server.py  (MCP Python SDK 2.x)
MCP server exposing The Abstractinator as tools for AI agents.
Talks to the local REST API (agent/api.R) and serves MCP over streamable HTTP
at http://127.0.0.1:8200/mcp (published via Cloudflare as https://mcp.abstractinator.me/mcp).
Only open-access sources are used here, so no one's API keys are ever spent.
"""
import os

import httpx2
from mcp.server.mcpserver import MCPServer
from mcp.server.transport_security import TransportSecuritySettings

API_URL = os.environ.get("ABSTRACTINATOR_API", "http://127.0.0.1:8100")
PORT = int(os.environ.get("MCP_PORT", "8200"))
PUBLIC_HOST = os.environ.get("MCP_PUBLIC_HOST", "mcp.abstractinator.me")

mcp = MCPServer(
    "Abstractinator",
    instructions=(
        "Searches immunology and virology literature across Europe PMC, OpenAlex, "
        "ClinicalTrials.gov, bioRxiv/medRxiv, NIH RePORTER grants and NSF awards, "
        "deduplicated and tagged by immune cell type and virus."
    ),
    version="1.0.0",
)


@mcp.tool()
async def search_literature(query: str, max_results: int = 25, abstract_chars: int = 1500) -> dict:
    """Search immunology/virology literature across several databases at once.

    Queries Europe PMC, OpenAlex, ClinicalTrials.gov, bioRxiv/medRxiv preprints,
    NIH RePORTER grants and NSF awards in parallel, removes duplicates, and tags each
    record with its most prominent immune cell type (primary_cell) and virus
    (primary_virus). Results are balanced across sources. A fresh search takes
    roughly 5-10 seconds; repeat searches within 7 days are instant.

    Args:
        query: Search term, e.g. "oncolytic virus", "T-VEC", "NK cell exhaustion".
        max_results: How many records to return (1-100). Default 25.
        abstract_chars: Truncate abstracts to this length; 0 omits them to save space.

    Returns a dict with total_found, returned, source_counts and a results list of
    records (title, abstract, authors, publication_date, doi, url, source,
    primary_cell, primary_virus, is_bioinformatics).
    """
    params = {"q": query, "limit": max_results, "abstract_chars": abstract_chars}
    try:
        async with httpx2.AsyncClient(timeout=180) as client:
            r = await client.get(f"{API_URL}/search", params=params)
    except httpx2.HTTPError as e:
        return {"error": f"The Abstractinator API is unreachable: {e}"}
    if r.status_code == 429:
        return {"error": "Rate limit reached on The Abstractinator. Wait a minute and retry."}
    if r.status_code >= 400:
        return {"error": f"Search failed (HTTP {r.status_code}).", "detail": r.text[:500]}
    return r.json()


if __name__ == "__main__":
    # Bound to localhost; DNS-rebinding protection allows only these Host headers,
    # so requests arriving through the Cloudflare tunnel need our public hostname listed.
    mcp.run(
        transport="streamable-http",
        host="127.0.0.1",
        port=PORT,
        stateless_http=True,
        transport_security=TransportSecuritySettings(
            enable_dns_rebinding_protection=True,
            allowed_hosts=["127.0.0.1:*", "localhost:*", PUBLIC_HOST],
            allowed_origins=["http://127.0.0.1:*", "http://localhost:*", f"https://{PUBLIC_HOST}"],
        ),
    )

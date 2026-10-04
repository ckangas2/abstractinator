<p align="center">
  <img src="www/icon-192.png" alt="The Abstractinator narwhal" width="120">
</p>

<h1 align="center">The Abstractinator</h1>

<p align="center">
  <b>Immunology & virology literature, searched across databases at once.</b><br>
  <a href="https://abstractinator.me">abstractinator.me</a> ·
  <a href="#-use-it-with-ai">Connect your AI</a> ·
  <a href="#-self-hosting">Self-host it</a>
</p>

---

The Abstractinator turns a literature sweep into one search. It queries Europe PMC, OpenAlex,
ClinicalTrials.gov, bioRxiv/medRxiv, NIH RePORTER and NSF Awards in parallel, removes
duplicates across sources, and tags every record with its most prominent **immune cell type**
and **virus** using a weighted title/abstract scoring matrix.

A new search takes about **5–10 seconds**; repeat searches within 7 days are instant.

## ✨ Features

| | |
| :--- | :--- |
| **Searchinator** | Queries every source simultaneously; the slowest source sets the pace, not the sum of all of them. |
| **Deep search** | Optional mode that pulls up to 250 results per source instead of 50 (~4× the coverage, ~15–30 s). |
| **Deduplicatinator** | Merges records across sources by DOI (including preprint → published DOI links), then by title, preferring the best-curated source. |
| **Plotinator** | Interactive charts of viral–immune trends over time. |
| **Readinator** | Build a reading list and export it to Zotero or EndNote. |
| **Agentinator** | An MCP server so AI assistants (Claude and others) can search The Abstractinator directly. |

## 📚 Data sources

| Source | Access | Coverage |
| :--- | :--- | :--- |
| **Europe PMC** | Open | Biomedical literature (incl. PubMed) |
| **OpenAlex** | Open | Global scholarly graph |
| **ClinicalTrials.gov** | Open | Human clinical study registrations |
| **bioRxiv / medRxiv** | Open (local copy) | Preprints, searched from a local Parquet store refreshed daily |
| **NIH RePORTER** | Open | US federal grants |
| **NSF Awards** | Open | Fundamental research grants |
| **CORE** | Your API key | Open-access full-text aggregation |
| **USPTO (PatentsView)** | Your API key | Patents |
| **Scopus / Embase** | Your API key, off by default | Abstract retrieval only works from a subscribing institution's network, so it's disabled unless `ENABLE_SCOPUS=1` |

Keyed sources are **bring-your-own-key**: enter keys in Settings (☰). They're held only in your
browser session, never logged or written to disk, and never shared with other visitors.

## 🤖 Use it with AI

The Abstractinator is available as a remote **MCP server**, the open standard AI assistants use
to connect to tools.

```
https://mcp.abstractinator.me/mcp
```

**In Claude:** Settings → Connectors → *Add custom connector* → paste the URL above, and choose
**No sign-in** for authentication. Then just ask, e.g. *"Search the Abstractinator for oncolytic
virus trials in melanoma."* Any MCP client that supports remote (streamable HTTP) servers works too.

The server exposes one tool:

**`search_literature(query, max_results=25, abstract_chars=1500, deep=False)`**
returns `total_found`, `source_counts`, and a source-balanced list of records with `title`,
`abstract`, `authors`, `publication_date`, `doi`, `url`, `source`, `primary_cell`,
`primary_virus` and `is_bioinformatics`.

The AI connector uses open-access sources only (no keys needed or spent) and is rate-limited
to keep the service available for everyone.

## 🏗️ How it works

```
Browser ──► Cloudflare ──► abstractinator.me      ──► Shiny Server :3838 (app.R) ─────────┐
                                                                                          ├─► search engine ──► shared cache
AI      ──► Cloudflare ──► mcp.abstractinator.me ──► MCP server :8200 (agent/mcp_server.py)│     (orchestrate_extraction.R)
                                                         └──► REST API :8100 (agent/api.R) ┘
```

- **One search engine, two front doors.** `orchestrate_extraction.R` checks the cache, starts
  every source as a background job (`future`), then combines, deduplicates and tags the results.
  The website calls it asynchronously through Shiny's `ExtendedTask`, so one visitor's search
  never freezes the page for anyone else. The REST API calls the same code synchronously.
- **Shared cache.** Results are cached for 7 days in `.cache/s3_mimic/` (one `.rds` per search,
  keyed by term, depth and which keyed sources were used). A search by a person makes the same
  search instant for an AI, and vice versa.
- **Local preprints.** bioRxiv/medRxiv are searched from `biorxiv_local_db/` (one Parquet file
  per year) via Arrow, instead of hitting their API on every search.
- **Hit detection.** Titles and abstracts are matched against immune-cell and virus alias lists
  (`aliases.R`); title hits weigh 20, abstract hits 3, and the top scorer becomes
  `primary_cell` / `primary_virus`.
- **Logging.** Website searches write a small JSON record (term, duration, result count, cache
  hit, and *whether* keys were present, never the keys) to `.cache/s3_mimic/logs/`. Feedback
  submitted through the app is saved to `.cache/s3_mimic/feedback/` and, if
  `DATA_WEBHOOK_URL` is set, forwarded to Discord.
- **Display safety.** Text from external databases is HTML-escaped before display, with only
  basic formatting tags (italics, bold, sub/superscript, line breaks) allowed through, and links
  restricted to plain `http(s)` URLs.

## 🖥️ Self-hosting

### Requirements

- Linux (tested on Ubuntu), R ≥ 4.1, Python ≥ 3.10 (for the MCP server)
- System libraries:
  ```bash
  sudo apt install -y r-base r-base-dev libcurl4-openssl-dev libssl-dev libxml2-dev \
    libsqlite3-dev libfontconfig1-dev libharfbuzz-dev libfribidi-dev libfreetype6-dev \
    libpng-dev libtiff5-dev libjpeg-dev libglpk-dev libgmp3-dev libsodium-dev cmake gfortran
  ```
- R packages (install into the system library so Shiny Server can see them):
  ```bash
  sudo /usr/bin/Rscript -e 'install.packages(c("shiny","bslib","shinyjs","shinythemes","shinyWidgets",
    "tidyverse","DT","plotly","htmltools","htmlwidgets","htmlTable","jsonlite","digest","future",
    "promises","parallelly","arrow","httr","httr2","RSQLite","DBI","uuid","lubridate","ggbeeswarm",
    "plumber"), repos = "https://cloud.r-project.org", Ncpus = 8)'
  ```

> **Using conda?** Shiny Server and the services use the system R at `/usr/bin/R`. Install
> packages with `/usr/bin/Rscript` (or `conda deactivate` first) so they land in the right place.

### 1. Get the code and configure

```bash
git clone https://github.com/ckangas2/abstractinator.git
cd abstractinator
```

Optional `.Renviron` in the project root:

```text
INTEGRATE_NIH_NSF=1      # include NIH & NSF grants (the app also sets this)
USER_EMAIL=you@example.org  # sent to OpenAlex for its "polite pool"
ENABLE_SCOPUS=0          # set to 1 only on a subscribing institution's network
DATA_WEBHOOK_URL=        # optional Discord webhook for updater notifications
```

No API keys are needed on the server: the website is strictly bring-your-own-key and never
uses keys from `.Renviron`, and the AI connector uses open-access sources only. (Keys in
`.Renviron` are only read by command-line scripts you run yourself.)

### 2. Build the preprint store (once, takes several hours)

```bash
tmux new -s biorxiv
Rscript write_parquet_bioRxiV.R      # resumable: finished years are skipped on rerun
```

Detach with `Ctrl+B, D`. Searches pick up each year as soon as it's written.

### 3. Run locally

```bash
/usr/bin/Rscript -e 'shiny::runApp(port = 4000)'   # website
/usr/bin/Rscript agent/run_api.R                   # REST API on 127.0.0.1:8100 (run from repo root)
```

### 4. Production setup (what abstractinator.me runs)

**Shiny Server**, serving the app at the root and only on localhost
(`/etc/shiny-server/shiny-server.conf`):

```
run_as shiny;
server {
  listen 3838 127.0.0.1;
  location / {
    app_dir /srv/shiny-server/abstractinator;
    log_dir /var/log/shiny-server;
    app_idle_timeout 0;
  }
}
```

**API and MCP services** (run as the `shiny` user):

```bash
sudo /usr/bin/python3 -m venv /opt/abstractinator-mcp
sudo /opt/abstractinator-mcp/bin/pip install "mcp[cli]"   # MCP Python SDK 2.x
sudo cp agent/abstractinator-api.service agent/abstractinator-mcp.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now abstractinator-api abstractinator-mcp
```

**Daily preprint updates** (after the initial build finishes):

```bash
sudo -u shiny mkdir -p logs
sudo cp deploy/abstractinator.cron /etc/cron.d/abstractinator   # runs update_biorxiv_db.R at 4:15am
```

**Public access** via a [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
(no open ports): route `abstractinator.me` → `http://localhost:3838` and
`mcp.abstractinator.me` → `http://localhost:8200`. The REST API stays private.

### Updating the live site

```bash
cd /srv/shiny-server/abstractinator
sudo -u shiny git pull
sudo systemctl restart shiny-server            # app.R, www/, search scripts
sudo systemctl restart abstractinator-api      # agent/api.R, search scripts
sudo systemctl restart abstractinator-mcp      # agent/mcp_server.py
```

### Running tests

```bash
# Fast offline tests (these also run on GitHub with every push)
Rscript -e 'testthat::test_dir("tests/testthat")'

# Plus live end-to-end searches against the real databases (needs internet, ~1-2 min)
ABSTRACTINATOR_LIVE_TESTS=1 Rscript -e 'testthat::test_dir("tests/testthat")'
```

### Usage logs

Every search, from the website or an AI agent, is logged without personal data.
Searches per day, split by channel:

```bash
cd /srv/shiny-server/abstractinator
sudo -u shiny /usr/bin/Rscript -e 'source("R/log_utils_local.R"); print(summarize_search_logs())'
```

### REST API reference (local only)

`GET /search?q=<term>&limit=25&abstract_chars=1500&deep=false`

- `limit`: results returned (1–100), picked round-robin across sources
- `abstract_chars`: truncate abstracts; `0` omits them
- `deep`: `true` for up to 250 results per source
- Optional headers `X-CORE-Key` and `X-USPTO-Key` enable those sources for the request
- Server-wide limit of 20 searches/minute (HTTP 429 when exceeded)

`GET /health` returns `{"status":"ok"}`.

## 🗂️ Repository layout

| Path | What it is |
| :--- | :--- |
| `app.R` | The Shiny web app |
| `orchestrate_extraction.R` | The search engine: cache → parallel sources → dedup → hit detection |
| `*_extraction.R` | One extractor per source (EPMC, OpenAlex, CORE, ClinicalTrials.gov, bioRxiv, NIH, NSF, PatentsView, Scopus) |
| `deduplication.R`, `aliases.R` | Cross-source deduplication; immune cell & virus alias lists |
| `R/db_utils_local.R`, `R/log_utils_local.R` | Search cache and search logging (website and agent searches) |
| `R/display_utils.R` | HTML sanitizing, export text cleanup and stable result IDs for the app |
| `tests/` | Offline unit tests and opt-in live search tests (testthat); run on GitHub Actions |
| `agent/` | REST API (`api.R`, `run_api.R`), MCP server (`mcp_server.py`), systemd units |
| `deploy/` | Cron schedule |
| `write_parquet_bioRxiV.R`, `update_biorxiv_db.R` | Build and refresh the local preprint store |
| `www/` | Styles, scripts, icons and mascot art |
| `agent_api.R`, `cli_engine.R`, `abstractinator_bridge.py` | Older local agent interface (knowledge-base functions are being reworked) |

## 🛣️ Roadmap

- Relevance ranking (best match first, using hit scores and recency)
- Skip caching searches where a source failed
- Log AI-agent searches alongside website searches
- Smarter agent tools backed by a relational knowledge base (gap analysis, "what's under-studied")

## ⚖️ License & branding

The **code** is open source under the [MIT License](LICENSE): you're welcome to use, modify
and build on it, as long as the copyright notice comes along.

The **name and branding** are not part of that license. "The Abstractinator", the *-inator*
feature names (Searchinator, Deduplicatinator, Plotinator, Readinator, Agentinator) and the
look of the site identify the official project at [abstractinator.me](https://abstractinator.me).
If you run your own copy or fork, please give it **your own name and branding**, and don't
present it as the official Abstractinator. A "based on The Abstractinator" credit with a link
back is appreciated.

Third-party icons in `www/` belong to their creators and are used under the Flaticon license
(see [CREDITS.md](CREDITS.md)); they aren't covered by the MIT License.

## 🙏 Credits

Mascot and icons from Flaticon (narwhal by Smashicons, dinosaur by imaginationlol, frog prince
by Magnific); line-art animations from the Noun Project. Details in [CREDITS.md](CREDITS.md).

## 📜 Citation

If you use The Abstractinator in your research, please cite:

> Kangas, C. (2026). The Abstractinator: Automated Boolean Search Tool for Rapid Acquisition, Classification, and Triage of Immuno-Networks And Therapeutic Oncolytic Research (Version 2.0.0) [Computer software]. https://abstractinator.me

```bibtex
@software{TheAbstractinator2026,
  author  = {Kangas, Chase},
  title   = {The Abstractinator: Automated Boolean Search Tool for Rapid Acquisition, Classification, and Triage of Immuno-Networks And Therapeutic Oncolytic Research},
  year    = {2026},
  url     = {https://abstractinator.me},
  version = {2.0.0}
}
```

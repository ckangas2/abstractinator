# archive/

Earlier generations of The Abstractinator, kept for reference. Nothing here is
loaded by the website, the API or the MCP server, and none of it is in
`renv.lock`. Paths inside these files still assume they sit in the repo root.

| Files | What they were |
| :--- | :--- |
| `abstractinator.sh`, `cli_engine.R`, `agent_api.R`, `abstractinator_bridge.py`, `db_utils_local_cache.R` | The command-line agent interface and its SQLite cache, replaced by `agent/api.R` and the MCP server |
| `_targets.R`, `triangulation_engine.R` | A `targets` pipeline whose scheduled runs never fired; replaced by `/etc/cron.d/abstractinator` |
| `build_master_db.R`, `other_sources.R`, `build_abstractinator_db.R` | One-off database builds |
| `batch_rename_png.R` | A one-off image renaming utility |

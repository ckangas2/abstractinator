#!/bin/bash

# Abstractinator CLI Wrapper
# This script provides a clean entry point for the R engine.

# FIXED: Aligned path to the current production ecosystem
ABSTRACTINATOR_DIR="/home/viridaex/.openclaw/workspace/workspace-code-team/ABSTRACTINATOR_FINAL"
CLI_ENGINE="${ABSTRACTINATOR_DIR}/cli_engine.R"

if [ "$#" -eq 0 ]; then
    echo "Usage: abstractinator [options]"
    echo "Options:"
    echo "  -s, --search TERM   Search literature"
    echo "  -q, --query SQL     Query the SQLite KB"
    echo "  -t, --top KEYWORD   Find top abstracts"
    echo "  -g, --gap TOPIC     Analyze knowledge gap"
    echo "  -n, --limit NUM     Limit results (default: 10)"
    echo "  -f, --format FMT    Format: md, csv, json (default: md)"
    echo "  --help              Show this help"
    exit 1
fi

# Execute Rscript directly against the absolute path
/usr/bin/Rscript "$CLI_ENGINE" "$@"
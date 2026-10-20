#!/bin/bash
# Semantic Finder — quick commands (Python engine)
cd "$(dirname "$0")"

case "${1:-help}" in
  index)
    echo "Indexing folders from config.json (first run downloads models)..."
    .venv/bin/python -m finder_search.cli index
    ;;
  search)
    shift
    .venv/bin/python -m finder_search.cli search "$@"
    ;;
  serve)
    .venv/bin/python -m finder_search.cli serve
    ;;
  stats)
    .venv/bin/python -m finder_search.cli stats
    ;;
  *)
    echo "Usage: ./run.sh {index|search|serve|stats}"
    echo ""
    echo "  ./run.sh index                 Scan & index all folders in config.json"
    echo "  ./run.sh search \"your query\"   Semantic search from the terminal"
    echo "  ./run.sh search \"query\" --reveal   ...and open top hit in Finder"
    echo "  ./run.sh serve                 Start the web UI (http://127.0.0.1:7862)"
    echo "  ./run.sh stats                 What's in the index"
    ;;
esac

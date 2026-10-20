"""CLI entry point: index / search / serve."""

import argparse
import json
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser(
        prog="finder_search",
        description="Local semantic search for documents, photos and videos.",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_index = sub.add_parser("index", help="Scan and index configured folders")
    p_index.add_argument("--folders", nargs="*", help="Override folders from config.json")

    p_search = sub.add_parser("search", help="Semantic search")
    p_search.add_argument("query")
    p_search.add_argument("-k", type=int, default=8, help="Results per section")
    p_search.add_argument("--reveal", action="store_true",
                          help="Reveal the top result in Finder")
    p_search.add_argument("--json", action="store_true", dest="as_json")

    p_serve = sub.add_parser("serve", help="Start the web UI / API server")
    p_serve.add_argument("--port", type=int, default=7862)
    p_serve.add_argument("--no-browser", action="store_true")

    p_stats = sub.add_parser("stats", help="Show index statistics")

    args = parser.parse_args()

    if args.cmd == "index":
        from .indexer import index_folders

        t0 = time.time()
        print("Loading models & indexing (first run downloads models)...")
        stats = index_folders(args.folders)
        stats["seconds"] = round(time.time() - t0, 1)
        print(json.dumps(stats, indent=2))

    elif args.cmd == "search":
        from .search import search

        t0 = time.time()
        results = search(args.query, k=args.k)
        dt = (time.time() - t0) * 1000

        if args.as_json:
            print(json.dumps(results, indent=2))
        else:
            docs, media = results["documents"], results["media"]
            if not docs and not media:
                print(f"No results for: {args.query!r} ({dt:.0f} ms)")
            if docs:
                print(f"\n📄 DOCUMENTS ({dt:.0f} ms)")
                for r in docs:
                    print(f"  {r['score']:.3f}  {r['path']}")
                    print(f"         {r['snippet'][:110]}")
            if media:
                print(f"\n🖼️  PHOTOS & VIDEOS ({dt:.0f} ms)")
                for r in media:
                    icon = "🎬" if r["kind"] == "video" else "📷"
                    print(f"  {icon} {r['score']:.3f}  {r['path']}")
            if args.reveal and (docs or media):
                top = (docs + media)[0]
                subprocess.run(["open", "-R", top["path"]])
        sys.exit(0)

    elif args.cmd == "stats":
        from .indexer import get_db

        conn = get_db()
        for row in conn.execute(
            """SELECT kind, COUNT(*) AS n,
                      (SELECT COUNT(*) FROM chunks c WHERE c.file_id IN
                        (SELECT id FROM files f2 WHERE f2.kind = files.kind)) AS extra
               FROM files GROUP BY kind"""
        ):
            print(f"{row[0]:>6}: {row[1]} files, {row[2]} chunks")
        conn.close()

    elif args.cmd == "serve":
        from .server import run

        run(port=args.port, open_browser=not args.no_browser)


if __name__ == "__main__":
    main()

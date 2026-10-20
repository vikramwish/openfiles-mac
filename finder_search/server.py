"""Local web UI + JSON API for the native OpenFiles app (stdlib only).

Endpoints:
  GET  /                    — single-page web UI
  GET  /health              — lightweight liveness probe (no model loading)
  GET  /api/search?q=...    — JSON results {documents: [...], media: [...]}
  GET  /api/status          — index statistics
  POST /api/index           — kick off (incremental) indexing in the background
  GET  /thumb?path=...      — resized thumbnail for images / video poster
  POST /api/reveal          — reveal a file in Finder
"""

import io
import json
import sqlite3
import subprocess
import threading
import urllib.parse
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from .config import DB_PATH
from .search import search

_thumb_lock = threading.Lock()
_index_lock = threading.Lock()
_index_running = False


def _index_stats() -> dict:
    try:
        conn = sqlite3.connect(DB_PATH)
        rows = conn.execute("SELECT kind, COUNT(*) FROM files GROUP BY kind").fetchall()
        chunks = conn.execute("SELECT COUNT(*) FROM chunks").fetchone()[0]
        conn.close()
        kinds = {k: n for k, n in rows}
        return {"files": sum(kinds.values()), "documents": kinds.get("text", 0),
                "photos": kinds.get("image", 0), "videos": kinds.get("video", 0),
                "chunks": chunks, "indexing": _index_running}
    except sqlite3.Error:
        return {"files": 0, "documents": 0, "photos": 0, "videos": 0,
                "chunks": 0, "indexing": _index_running}


def _run_index():
    global _index_running
    with _index_lock:
        if _index_running:
            return
        _index_running = True
    try:
        from .indexer import index_folders

        index_folders(None, verbose=False)
    finally:
        _index_running = False


HTML = """<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Semantic Finder</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", Helvetica, Arial, sans-serif;
    background: #16161a; color: #eee; min-height: 100vh; padding: 48px 16px;
  }
  .wrap { max-width: 860px; margin: 0 auto; }
  h1 { font-size: 22px; font-weight: 600; margin-bottom: 4px; }
  .sub { color: #888; font-size: 13px; margin-bottom: 28px; }
  .searchbox {
    display: flex; align-items: center; gap: 12px; background: #232329;
    border: 1px solid #34343c; border-radius: 14px; padding: 14px 18px;
  }
  .searchbox:focus-within { border-color: #6aa1ff; }
  .searchbox svg { flex: none; opacity: .6; }
  input {
    flex: 1; background: none; border: none; outline: none; color: #eee;
    font-size: 18px;
  }
  .meta { color: #777; font-size: 12px; }
  h2 { font-size: 13px; text-transform: uppercase; letter-spacing: .08em;
       color: #888; margin: 32px 0 12px; }
  .card {
    display: flex; gap: 14px; align-items: flex-start; background: #1e1e24;
    border: 1px solid #2c2c33; border-radius: 12px; padding: 14px;
    margin-bottom: 10px; cursor: pointer; transition: border-color .12s;
  }
  .card:hover { border-color: #55565f; }
  .thumb { width: 76px; height: 76px; border-radius: 8px; object-fit: cover;
           flex: none; background: #101014; }
  .icon { width: 76px; height: 76px; border-radius: 8px; flex: none;
          display: flex; align-items: center; justify-content: center;
          background: #26262e; font-size: 30px; }
  .body { min-width: 0; flex: 1; }
  .path { font-size: 13px; color: #9ec1ff; word-break: break-all; }
  .snippet { font-size: 13px; color: #b9b9c2; margin-top: 6px;
             display: -webkit-box; -webkit-line-clamp: 3; -webkit-box-orient: vertical;
             overflow: hidden; line-height: 1.45; }
  .score { font-size: 11px; color: #6e6e78; margin-top: 6px; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(180px, 1fr));
          gap: 10px; }
  .mcard { background: #1e1e24; border: 1px solid #2c2c33; border-radius: 12px;
           overflow: hidden; cursor: pointer; transition: border-color .12s; }
  .mcard:hover { border-color: #55565f; }
  .mcard img { width: 100%; aspect-ratio: 1; object-fit: cover; display: block;
               background: #101014; }
  .mlabel { padding: 8px 10px; font-size: 11.5px; color: #b9b9c2;
            white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .empty { color: #777; margin-top: 24px; font-size: 14px; }
</style>
</head><body>
<div class="wrap">
  <h1>Semantic Finder</h1>
  <div class="sub">Local semantic search — documents, photos &amp; videos · 100% on-device</div>
  <div class="searchbox">
    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#999" stroke-width="2">
      <circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>
    </svg>
    <input id="q" placeholder="Describe what you're looking for…" autofocus autocomplete="off">
    <span class="meta" id="timing"></span>
  </div>
  <div id="results"></div>
</div>
<script>
const input = document.getElementById('q');
const resultsEl = document.getElementById('results');
const timingEl = document.getElementById('timing');
let timer = null, seq = 0;

function esc(s) {
  const d = document.createElement('div'); d.textContent = s; return d.innerHTML;
}

function reveal(path) {
  fetch('/api/reveal', {method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({path})});
}

async function run() {
  const q = input.value.trim();
  const mySeq = ++seq;
  if (!q) { resultsEl.innerHTML = ''; timingEl.textContent = ''; return; }
  const t0 = performance.now();
  const r = await fetch('/api/search?q=' + encodeURIComponent(q));
  const data = await r.json();
  if (mySeq !== seq) return;   // stale response
  const ms = (performance.now() - t0).toFixed(0);
  timingEl.textContent = ms + ' ms';

  if (!data.documents.length && !data.media.length) {
    resultsEl.innerHTML = '<div class="empty">No results. Try different words — this is semantic, not keyword, search.</div>';
    return;
  }
  let html = '';
  if (data.documents.length) {
    html += '<h2>Documents</h2>';
    for (const d of data.documents) {
      html += `<div class="card" data-path="${esc(d.path)}">
        <div class="icon">📄</div>
        <div class="body">
          <div class="path">${esc(d.path)}</div>
          <div class="snippet">${esc(d.snippet)}</div>
          <div class="score">relevance ${(d.score*100).toFixed(0)}%</div>
        </div></div>`;
    }
  }
  if (data.media.length) {
    html += '<h2>Photos &amp; Videos</h2><div class="grid">';
    for (const m of data.media) {
      const isVideo = m.kind === 'video';
      html += `<div class="mcard" data-path="${esc(m.path)}">
        <img loading="lazy" src="/thumb?path=${encodeURIComponent(m.path)}">
        <div class="mlabel">${isVideo ? '🎬 ' : ''}${esc(m.path.split('/').pop())}
          <span class="score"> · ${(m.score*100).toFixed(0)}%</span></div></div>`;
    }
    html += '</div>';
  }
  resultsEl.innerHTML = html;
  resultsEl.querySelectorAll('[data-path]').forEach(el =>
    el.addEventListener('click', () => reveal(el.dataset.path)));
}

input.addEventListener('input', () => {
  clearTimeout(timer);
  timer = setTimeout(run, 200);
});
</script>
</body></html>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):  # quiet
        pass

    def _send(self, code: int, body: bytes, ctype: str):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/":
            self._send(200, HTML.encode(), "text/html; charset=utf-8")

        elif parsed.path == "/health":
            # lightweight: no model loading, no search
            self._send(200, json.dumps({"ok": True, **_index_stats()}).encode(),
                       "application/json")

        elif parsed.path == "/api/status":
            self._send(200, json.dumps(_index_stats()).encode(), "application/json")

        elif parsed.path == "/api/search":
            q = urllib.parse.parse_qs(parsed.query).get("q", [""])[0].strip()
            if not q:
                self._send(200, b'{"documents":[],"media":[]}', "application/json")
                return
            try:
                res = search(q, k=8)
            except Exception as e:
                self._send(200, json.dumps(
                    {"error": str(e), "documents": [], "media": []}).encode(),
                    "application/json")
                return
            self._send(200, json.dumps(res).encode(), "application/json")

        elif parsed.path == "/thumb":
            p = urllib.parse.parse_qs(parsed.query).get("path", [""])[0]
            self._send_thumb(Path(p))

        else:
            self._send(404, b"not found", "text/plain")

    def _send_thumb(self, path: Path):
        try:
            from PIL import Image

            with _thumb_lock:
                img = Image.open(path)
                img = img.convert("RGB")
            img.thumbnail((320, 320))
            buf = io.BytesIO()
            img.save(buf, "JPEG", quality=75)
            self._send(200, buf.getvalue(), "image/jpeg")
        except Exception:
            # videos / unreadable -> poster placeholder
            svg = ('<svg xmlns="http://www.w3.org/2000/svg" width="320" height="320">'
                   '<rect width="320" height="320" fill="#26262e"/>'
                   '<text x="160" y="170" font-size="60" text-anchor="middle">🎬</text>'
                   '</svg>').encode()
            self._send(200, svg, "image/svg+xml")

    def do_POST(self):
        if self.path == "/api/reveal":
            try:
                length = int(self.headers.get("Content-Length", 0))
                body = json.loads(self.rfile.read(length))
                p = str(Path(body["path"]).resolve())
                subprocess.Popen(["open", "-R", p])
                self._send(200, b'{"ok": true}', "application/json")
            except Exception as e:
                self._send(400, str(e).encode(), "text/plain")
        elif self.path == "/api/index":
            if _index_running:
                self._send(202, b'{"ok": true, "already": true}', "application/json")
            else:
                threading.Thread(target=_run_index, daemon=True).start()
                self._send(202, b'{"ok": true, "started": true}', "application/json")
        else:
            self._send(404, b"not found", "text/plain")


def run(port: int = 7862, open_browser: bool = True):
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    url = f"http://127.0.0.1:{port}"
    print(f"Semantic Finder running at {url}")
    # keep the index fresh in the background (incremental — cheap after the
    # first run). Searches work immediately over whatever is indexed so far.
    threading.Timer(1.0, lambda: threading.Thread(
        target=_run_index, daemon=True).start()).start()
    if open_browser:
        threading.Timer(0.5, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nbye")

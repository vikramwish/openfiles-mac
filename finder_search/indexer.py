"""Incremental indexer: walks configured folders and embeds new/changed files.

Three kinds of content land in SQLite:
  - text chunks (BGE-small embeddings)   -> documents
  - images  (SigLIP2 vision embeddings)  -> photos
  - videos  (mean-pooled SigLIP2 frame embeddings) -> video files
"""

import shutil
import sqlite3
import subprocess
import tempfile
from pathlib import Path

import numpy as np

from . import models
from .config import (
    DB_PATH,
    IMAGE_EXTENSIONS,
    TEXT_EXTENSIONS,
    VIDEO_EXTENSIONS,
    expand_folder,
    load_config,
)
from .extract import chunk_text, extract_text

SCHEMA = """
CREATE TABLE IF NOT EXISTS files (
    id INTEGER PRIMARY KEY,
    path TEXT UNIQUE,
    kind TEXT NOT NULL,          -- text | image | video
    mtime REAL NOT NULL,
    size INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS chunks (
    id INTEGER PRIMARY KEY,
    file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    idx INTEGER NOT NULL,
    text TEXT NOT NULL,
    embedding BLOB NOT NULL
);
CREATE TABLE IF NOT EXISTS media (
    id INTEGER PRIMARY KEY,
    file_id INTEGER NOT NULL UNIQUE REFERENCES files(id) ON DELETE CASCADE,
    embedding BLOB NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_chunks_file ON chunks(file_id);
"""


def get_db() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.executescript(SCHEMA)
    return conn


def classify(path: Path) -> str | None:
    suf = path.suffix.lower()
    if suf in TEXT_EXTENSIONS:
        return "text"
    if suf in IMAGE_EXTENSIONS:
        return "image"
    if suf in VIDEO_EXTENSIONS:
        return "video"
    return None


def heic_to_jpeg(path: Path, tmpdir: Path) -> str | None:
    """Convert HEIC using macOS built-in sips."""
    out = tmpdir / (path.stem + ".jpg")
    try:
        r = subprocess.run(
            ["sips", "-s", "format", "jpeg", str(path), "--out", str(out)],
            capture_output=True, timeout=30,
        )
        if r.returncode == 0 and out.exists():
            return str(out)
    except Exception:
        pass
    return None


def video_duration(path: Path) -> float | None:
    try:
        r = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", str(path)],
            capture_output=True, text=True, timeout=30,
        )
        return float(r.stdout.strip())
    except Exception:
        return None


def sample_video_frames(path: Path, n_frames: int, tmpdir: Path) -> list[str]:
    """Extract n evenly-spaced frames as JPEGs; returns paths (may be < n)."""
    frames: list[str] = []
    duration = video_duration(path)
    if duration and duration > 0.5:
        for i in range(n_frames):
            t = duration * (i + 0.5) / n_frames
            out = tmpdir / f"frame_{i:03d}.jpg"
            try:
                r = subprocess.run(
                    ["ffmpeg", "-loglevel", "error", "-ss", f"{t:.2f}", "-i", str(path),
                     "-frames:v", "1", "-vf", "scale='min(512,iw)':-2",
                     "-q:v", "4", str(out)],
                    capture_output=True, timeout=60,
                )
                if r.returncode == 0 and out.exists():
                    frames.append(str(out))
            except Exception:
                continue
    if not frames:
        # fallback: just grab the first few frames sequentially
        try:
            subprocess.run(
                ["ffmpeg", "-loglevel", "error", "-i", str(path), "-vf",
                 f"fps=1/2,scale='min(512,iw)':-2", "-frames:v", str(n_frames),
                 str(tmpdir / "seq_%02d.jpg")],
                capture_output=True, timeout=120,
            )
            frames = [str(p) for p in sorted(tmpdir.glob("seq_*.jpg"))][:n_frames]
        except Exception:
            pass
    return frames


def index_folders(folders: list[str] | None = None, verbose: bool = True) -> dict:
    cfg = load_config()
    folders = folders or cfg["folders"]
    skip_dirs = set(cfg["skip_dirs"])
    max_bytes = cfg["max_file_mb"] * 1024 * 1024

    conn = get_db()
    stats = {"scanned": 0, "indexed": 0, "skipped": 0, "removed": 0, "errors": 0,
             "text_files": 0, "image_files": 0, "video_files": 0, "chunks": 0}

    # existing file states
    existing: dict[str, tuple[float, int, int]] = {}
    for fid, path, mtime, size in conn.execute("SELECT id, path, mtime, size FROM files"):
        existing[path] = (fid, mtime, size)
    seen_paths: set[str] = set()

    def log(msg: str):
        if verbose:
            print(msg, end="\r", flush=True)

    for folder in folders:
        root = expand_folder(folder)
        if not root.exists():
            continue
        for path in root.rglob("*"):
            if any(part in skip_dirs or part.startswith(".") and part != "."
                   for part in path.relative_to(root).parts):
                continue
            if not path.is_file():
                continue
            stats["scanned"] += 1
            spath = str(path)
            seen_paths.add(spath)
            kind = classify(path)
            if kind is None:
                continue
            try:
                st = path.stat()
            except OSError:
                continue
            if st.st_size > max_bytes or st.st_size == 0:
                stats["skipped"] += 1
                continue
            prev = existing.get(spath)
            if prev and abs(prev[1] - st.st_mtime) < 1 and prev[2] == st.st_size:
                stats["skipped"] += 1
                continue

            # (re)index this file
            if prev:
                conn.execute("DELETE FROM files WHERE id=?", (prev[0],))
            log(f"[index] {spath[:80]}")
            try:
                if kind == "text":
                    n = index_text_file(conn, path, cfg)
                    stats["text_files"] += 1
                    stats["chunks"] += n
                elif kind == "image":
                    index_image_file(conn, path)
                    stats["image_files"] += 1
                elif kind == "video":
                    index_video_file(conn, path, cfg)
                    stats["video_files"] += 1
                stats["indexed"] += 1
                conn.commit()
            except Exception as e:
                stats["errors"] += 1
                if verbose:
                    print(f"\n[error] {spath}: {e}")

    # purge rows for files that no longer exist
    for spath, (fid, _, _) in existing.items():
        if spath not in seen_paths and not Path(spath).exists():
            conn.execute("DELETE FROM files WHERE id=?", (fid,))
            stats["removed"] += 1
    conn.commit()
    conn.close()
    if verbose:
        print("\n" + " " * 100)
    return stats


def index_text_file(conn: sqlite3.Connection, path: Path, cfg: dict) -> int:
    raw = extract_text(path)
    chunks = chunk_text(raw, cfg["chunk_chars"], cfg["chunk_overlap"])
    if not chunks:
        return 0
    # prefix the filename into the first chunk so filenames are searchable too
    name_hint = f"File: {path.name}. "
    chunks[0] = name_hint + chunks[0]
    embs = models.embed_documents(chunks)
    st = path.stat()
    cur = conn.execute(
        "INSERT INTO files (path, kind, mtime, size) VALUES (?,?,?,?)",
        (str(path), "text", st.st_mtime, st.st_size),
    )
    fid = cur.lastrowid
    conn.executemany(
        "INSERT INTO chunks (file_id, idx, text, embedding) VALUES (?,?,?,?)",
        [(fid, i, c, e.astype(np.float32).tobytes())
         for i, (c, e) in enumerate(zip(chunks, embs))],
    )
    return len(chunks)


def index_image_file(conn: sqlite3.Connection, path: Path) -> None:
    tmpdir = None
    p = str(path)
    if path.suffix.lower() == ".heic":
        tmpdir = tempfile.mkdtemp(prefix="fs_heic_")
        p = heic_to_jpeg(path, Path(tmpdir))
        if not p:
            return
    try:
        emb = models.embed_images([p])[0]
        st = path.stat()
        cur = conn.execute(
            "INSERT INTO files (path, kind, mtime, size) VALUES (?,?,?,?)",
            (str(path), "image", st.st_mtime, st.st_size),
        )
        conn.execute(
            "INSERT INTO media (file_id, embedding) VALUES (?,?)",
            (cur.lastrowid, emb.astype(np.float32).tobytes()),
        )
    finally:
        if tmpdir:
            shutil.rmtree(tmpdir, ignore_errors=True)


def index_video_file(conn: sqlite3.Connection, path: Path, cfg: dict) -> None:
    tmpdir = Path(tempfile.mkdtemp(prefix="fs_vid_"))
    try:
        frames = sample_video_frames(path, cfg["video_frames"], tmpdir)
        if not frames:
            return
        embs = models.embed_images(frames)
        mean = np.mean(np.stack(embs), axis=0)
        mean = mean / (np.linalg.norm(mean) + 1e-10)
        st = path.stat()
        cur = conn.execute(
            "INSERT INTO files (path, kind, mtime, size) VALUES (?,?,?,?)",
            (str(path), "video", st.st_mtime, st.st_size),
        )
        conn.execute(
            "INSERT INTO media (file_id, embedding) VALUES (?,?)",
            (cur.lastrowid, mean.astype(np.float32).tobytes()),
        )
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

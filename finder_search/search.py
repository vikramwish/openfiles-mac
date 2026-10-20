"""Query engine: embed the query in both spaces and rank results."""

import sqlite3

import numpy as np

from . import models
from .config import DB_PATH


def _to_vec(blob: bytes) -> np.ndarray:
    return np.frombuffer(blob, dtype=np.float32)


def search(query: str, k: int = 8) -> dict:
    """Returns {'documents': [...], 'media': [...]} ranked lists."""
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row

    documents, media = [], []

    # --- document space (BGE) ---
    rows = conn.execute(
        """SELECT c.text, c.embedding, f.path
           FROM chunks c JOIN files f ON f.id = c.file_id"""
    ).fetchall()
    if rows:
        q = models.embed_query(query)
        mat = np.stack([_to_vec(r["embedding"]) for r in rows])
        mat = mat / (np.linalg.norm(mat, axis=1, keepdims=True) + 1e-10)
        scores = mat @ q
        top = np.argsort(-scores)[:k]
        for i in top:
            if scores[i] < 0.15:
                break
            documents.append({
                "path": rows[i]["path"],
                "score": round(float(scores[i]), 4),
                "snippet": rows[i]["text"][:300].replace("\n", " "),
                "kind": "document",
            })

    # --- joint image/video space (SigLIP2) ---
    mrows = conn.execute(
        """SELECT m.embedding, f.path, f.kind
           FROM media m JOIN files f ON f.id = m.file_id"""
    ).fetchall()
    if mrows:
        q = models.embed_mm_query(query)
        mat = np.stack([_to_vec(r["embedding"]) for r in mrows])
        mat = mat / (np.linalg.norm(mat, axis=1, keepdims=True) + 1e-10)
        scores = mat @ q
        top = np.argsort(-scores)[:k]
        for i in top:
            # SigLIP2 cosine scores run low (sigmoid-loss training) — a correct
            # top match often lands in 0.05–0.25. Rank order is what matters.
            if scores[i] < 0.05:
                break
            media.append({
                "path": mrows[i]["path"],
                "score": round(float(scores[i]), 4),
                "kind": "photo" if mrows[i]["kind"] == "image" else "video",
            })

    conn.close()
    return {"documents": documents, "media": media}

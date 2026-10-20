"""Lazy singletons for the embedding models.

Two embedding spaces are used:
  1. BGE-small (384-dim)  — for document text chunks and text queries about documents.
  2. SigLIP2 (768-dim)    — a joint text/image space: photos and video frames are
     embedded with the vision tower, queries with the text tower, so a plain-English
     query finds matching images/videos directly.
"""

import numpy as np

from .config import CACHE_DIR, MULTIMODAL_MODEL, TEXT_MODEL

_text_model = None
_mm_model = None
_mm_text_model = None


def get_text_model():
    global _text_model
    if _text_model is None:
        from fastembed import TextEmbedding

        _text_model = TextEmbedding(model_name=TEXT_MODEL, cache_dir=str(CACHE_DIR))
    return _text_model


def get_multimodal_model():
    global _mm_model
    if _mm_model is None:
        from fastembed import ImageEmbedding

        _mm_model = ImageEmbedding(model_name=MULTIMODAL_MODEL, cache_dir=str(CACHE_DIR))
    return _mm_model


def embed_documents(texts: list[str]) -> list[np.ndarray]:
    """Embed document chunks (passage-style, no query prefix)."""
    if not texts:
        return []
    model = get_text_model()
    return [np.asarray(e, dtype=np.float32) for e in model.embed(texts)]


def embed_query(text: str) -> np.ndarray:
    """Embed a text query for the BGE document space (uses query prefix)."""
    model = get_text_model()
    q = np.asarray(next(iter(model.query_embed([text]))), dtype=np.float32)
    return q / (np.linalg.norm(q) + 1e-10)


def embed_images(paths: list[str]) -> list[np.ndarray]:
    """Embed images with the SigLIP2 vision tower (normalized)."""
    if not paths:
        return []
    model = get_multimodal_model()
    out = []
    for e in model.embed(paths):
        v = np.asarray(e, dtype=np.float32)
        out.append(v / (np.linalg.norm(v) + 1e-10))
    return out


def embed_mm_query(text: str) -> np.ndarray:
    """Embed a text query in the SigLIP2 joint space (normalized)."""
    global _mm_text_model
    if _mm_text_model is None:
        from fastembed import TextEmbedding

        _mm_text_model = TextEmbedding(
            model_name=MULTIMODAL_MODEL, cache_dir=str(CACHE_DIR)
        )
    v = np.asarray(next(iter(_mm_text_model.embed([text]))), dtype=np.float32)
    return v / (np.linalg.norm(v) + 1e-10)

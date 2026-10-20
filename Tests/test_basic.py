"""Unit tests for finder_search — no model downloads, no personal folders.

Run:  .venv/bin/python -m unittest discover -s tests -v
"""

import os
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from finder_search import indexer, models  # noqa: E402
from finder_search.config import TEXT_EXTENSIONS  # noqa: E402
from finder_search.extract import chunk_text, extract_text  # noqa: E402


class TestChunking(unittest.TestCase):
    def test_short_text_single_chunk(self):
        self.assertEqual(chunk_text("hello world"), ["hello world"])

    def test_long_text_chunks_with_overlap(self):
        text = " ".join(str(i) for i in range(500))  # ~2890 chars
        chunks = chunk_text(text, chunk_chars=1000, overlap=200)
        self.assertGreater(len(chunks), 1)
        for c in chunks:
            self.assertLessEqual(len(c), 1000)
        # overlap exists between consecutive chunks
        self.assertIn(chunks[0][-100:], chunks[1])

    def test_empty(self):
        self.assertEqual(chunk_text("   "), [])


class TestExtraction(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_txt(self):
        p = self.dir / "note.txt"
        p.write_text("hello extraction")
        self.assertEqual(extract_text(p), "hello extraction")

    def test_missing_pdf_returns_empty(self):
        p = self.dir / "nope.pdf"
        self.assertEqual(extract_text(p), "")


class TestClassify(unittest.TestCase):
    def test_known_extensions(self):
        for ext, kind in [(".pdf", "text"), (".md", "text"), (".py", "text"),
                          (".jpg", "image"), (".heic", "image"),
                          (".mp4", "video"), (".mov", "video")]:
            self.assertEqual(indexer.classify(Path(f"x{ext}")), kind)

    def test_unknown(self):
        self.assertIsNone(indexer.classify(Path("x.xyz")))

    def test_config_text_extensions_covered(self):
        for ext in TEXT_EXTENSIONS:
            self.assertEqual(indexer.classify(Path(f"x{ext}")), "text")


class TestIndexerWithStubs(unittest.TestCase):
    """Index a temp folder using stubbed embedding models."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        # point the index DB at a temp file
        self._orig_db = indexer.DB_PATH
        indexer.DB_PATH = str(self.dir / "test.db")
        # NB: use the resolved path — index_folders rglobs from a resolved root,
        # and /var is a symlink to /private/var on macOS.
        (self.dir.resolve() / "doc.txt").write_text(
            "The capital of France is Paris. " * 50
        )
        # deterministic stub embeddings
        def fake_embed(texts):
            return [models.np.array([float(len(t) % 7), 1.0], dtype="float32")
                    for t in texts]

        self.patch_doc = mock.patch.object(models, "embed_documents", fake_embed)
        self.patch_doc.start()

    def tearDown(self):
        self.patch_doc.stop()
        indexer.DB_PATH = self._orig_db
        self.tmp.cleanup()

    def test_index_and_reindex_incremental(self):
        cfg = {"chunk_chars": 100, "chunk_overlap": 20}
        conn = sqlite3.connect(indexer.DB_PATH)
        conn.executescript(indexer.SCHEMA)

        with mock.patch.object(indexer, "get_db", return_value=conn):
            # index_text_file on its own: creates chunks for the doc
            doc = self.dir.resolve() / "doc.txt"
            with mock.patch.object(indexer.models, "embed_documents",
                                   models.embed_documents):
                n = indexer.index_text_file(conn, doc, cfg)
            self.assertGreaterEqual(n, 1)
            # index_folders sees the file as already indexed -> skips it
            stats = indexer.index_folders([str(self.dir)], verbose=False)
        self.assertEqual(stats["text_files"], 0)
        self.assertEqual(stats["skipped"], 1)
        self.assertEqual(stats["errors"], 0)

        conn = sqlite3.connect(indexer.DB_PATH)  # reopened (index_folders closed it)
        rows = conn.execute(
            "SELECT path, kind FROM files"
        ).fetchall()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0][1], "text")

        # second run: file unchanged -> skipped, no re-embed
        stats2 = indexer.index_folders([str(self.dir)], verbose=False)
        self.assertEqual(stats2["indexed"], 0)
        self.assertEqual(stats2["skipped"], 1)

        # delete the file -> purged from index
        os.remove(self.dir.resolve() / "doc.txt")
        stats3 = indexer.index_folders([str(self.dir)], verbose=False)
        self.assertEqual(stats3["removed"], 1)
        remaining = conn.execute("SELECT COUNT(*) FROM files").fetchone()[0]
        self.assertEqual(remaining, 0)
        conn.close()


class TestSearchWithStubs(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self._orig_db = indexer.DB_PATH
        from finder_search import search as search_mod

        self._orig_search_db = search_mod.DB_PATH
        indexer.DB_PATH = str(self.dir / "s.db")
        search_mod.DB_PATH = str(self.dir / "s.db")

        conn = sqlite3.connect(indexer.DB_PATH)
        conn.executescript(indexer.SCHEMA)
        import numpy as np

        cur = conn.execute(
            "INSERT INTO files (path, kind, mtime, size) VALUES (?,?,?,?)",
            ("/tmp/hello.txt", "text", 0, 0),
        )
        vec = np.array([1.0, 0.0], dtype="float32")
        conn.execute(
            "INSERT INTO chunks (file_id, idx, text, embedding) VALUES (?,?,?,?)",
            (cur.lastrowid, 0, "greeting text", vec.tobytes()),
        )
        conn.commit()
        conn.close()

    def tearDown(self):
        indexer.DB_PATH = self._orig_db
        from finder_search import search as search_mod

        search_mod.DB_PATH = self._orig_search_db
        self.tmp.cleanup()

    def test_search_ranking(self):
        import numpy as np

        from finder_search import search as search_mod

        qvec = np.array([1.0, 0.0], dtype="float32")  # aligns with the chunk
        with mock.patch.object(search_mod.models, "embed_query", return_value=qvec), \
             mock.patch.object(search_mod.models, "embed_mm_query", return_value=qvec):
            res = search_mod.search("hello", k=5)
        self.assertEqual(len(res["documents"]), 1)
        self.assertEqual(res["documents"][0]["path"], "/tmp/hello.txt")
        self.assertGreater(res["documents"][0]["score"], 0.99)


if __name__ == "__main__":
    unittest.main()

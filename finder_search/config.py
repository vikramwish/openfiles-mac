"""Configuration for finder_search."""

import json
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DB_PATH = REPO_ROOT / "index.db"
CACHE_DIR = REPO_ROOT / ".model_cache"
CONFIG_PATH = REPO_ROOT / "config.json"

# Embedding models (validated against current Hugging Face leaderboards):
#   - text/documents: BAAI/bge-small-en-v1.5 (384-dim, CPU-fast, strong retrieval)
#   - photos/video + text queries over them: google/siglip2-base-patch16-224
#     (2025 vision-language encoder, one shared 768-dim space for text<->image)
TEXT_MODEL = "BAAI/bge-small-en-v1.5"
MULTIMODAL_MODEL = "google/siglip2-base-patch16-224"

DEFAULT_CONFIG = {
    "folders": ["~/Documents", "~/Desktop", "~/Downloads"],
    "max_file_mb": 100,
    "chunk_chars": 1000,
    "chunk_overlap": 200,
    "video_frames": 8,
    "skip_dirs": [
        ".git", "node_modules", ".venv", "venv", "__pycache__", ".Trash",
        "Library", ".cache", ".npm", ".cargo", ".rustup", "site-packages",
        "build", ".build", ".github", ".code-review-graph", ".codebase-memory",
        "DerivedData", "Pods",
    ],
}

TEXT_EXTENSIONS = {
    ".txt", ".md", ".markdown", ".rst", ".pdf", ".docx", ".rtf", ".doc",
    ".py", ".js", ".ts", ".tsx", ".jsx", ".json", ".csv", ".tsv", ".yaml",
    ".yml", ".toml", ".html", ".css", ".xml", ".sh", ".zsh", ".bash",
    ".swift", ".c", ".h", ".cpp", ".java", ".go", ".rs", ".sql", ".log",
}
IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".gif", ".tiff", ".tif", ".heic"}
VIDEO_EXTENSIONS = {".mp4", ".mov", ".m4v", ".avi", ".mkv", ".webm"}


def load_config() -> dict:
    cfg = dict(DEFAULT_CONFIG)
    if CONFIG_PATH.exists():
        try:
            cfg.update(json.loads(CONFIG_PATH.read_text()))
        except (json.JSONDecodeError, OSError):
            pass
    else:
        CONFIG_PATH.write_text(json.dumps(cfg, indent=2))
    return cfg


def expand_folder(f: str) -> Path:
    return Path(f).expanduser().resolve()

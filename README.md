# OpenFiles

**A native macOS file assistant that actually understands your files.**

Finder-like browsing, on-device semantic search across documents *and* photos, a reviewed LLM file agent, Google Drive / OneDrive integration, and local version history — one SwiftUI app, zero third-party dependencies, everything on your Mac by default.

![macOS](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple)
![Swift](https://img.shields.io/badge/Swift-5.9%2B-F05138?logo=swift)
![Dependencies](https://img.shields.io/badge/dependencies-none-2ea44f)
![Privacy](https://img.shields.io/badge/processing-on--device-blue)

---

## Quick start

```sh
git clone https://github.com/vikramwish/openfiles-mac.git
cd openfiles-mac
make run        # builds, signs, and opens OpenFiles.app
```

Requires **macOS 14+** and **Swift 5.9+** (Xcode or Command Line Tools). No backend, no package manager, no account. Want the deeper checks?

```sh
make test           # local + mocked-cloud test suites
make release        # optimized build
```

---

## What it does

### 🔎 Search that reads your files
- **Hybrid semantic engine** — filename + full-text Spotlight search fused with on-device embeddings: **BGE-small** for documents and **SigLIP2** for photos *and sampled video frames* (a local Python service, ONNX, runs on your Mac).
- **⌘⇧Space quick search** from any app — type `australian government tax files` or `PDFs in Downloads this month`; results refine as you type.
- **Image-content search** — Apple Vision classifies subjects and OCRs text during indexing, so `zebra` finds the zebra inside `IMG_0042.jpg`.
- **Photo location search** — `photos taken in Sydney` works offline from embedded GPS/IPTC metadata. No geocoding calls.

### 🤖 Ask Hermes — a file agent with a conscience
Open **Ask Hermes** (⌘⇧A), describe what you want in plain English, and the agent proposes **renames, moves, and folders to open**. It is *plan-only*:
- Every action goes through the app's reviewed, verified flows — re-read files, collision checks, sensitive-file refusals, byte-verified renames.
- The model can't invent paths, touch sensitive files, or apply anything itself. You approve each row.
- Speaks any OpenAI-compatible endpoint (OpenRouter by default, LM Studio, local proxies). API keys live in **macOS Keychain**, never in files or logs. Vision-capable models can *look at* images before naming them. One request can rename every file in view.

### ☁️ Cloud storage without the sync apps
- Connect **Google Drive** or **OneDrive** directly — the providers' sync apps are not required. Browse, preview, download, and search across the whole account.
- Optional **two-way sync** with paired folders, conflict comparison, and verified local backups before any replacement. Credentials and OAuth tokens stay in Keychain.

### 🗂 A Finder that helps
- Native browsing of any location, breadcrumbs, Quick Look, multi-window workspaces.
- **Suggested filenames** — content-aware rename suggestions (singles or batches of 50), verified byte-for-byte before anything changes.
- **Collections** — group files from anywhere without moving originals.
- **Document packs** — checklists (rental applications, expense claims, travel) that find matching files and export reviewed copies.

### 🕘 History & safety nets
- **Version history** per file/folder with change selection, cherry-picking, and verified restore — plus a floating **Versions** companion when you open files elsewhere.
- **Automatic versions** — opt any folder into 30-second local snapshots.
- **Encrypted private vault** (AES-256 APFS image).
- **Reviewed cleanup** — duplicate, stale-installer, old-screenshot, and *developer-space* reviews (node_modules, venvs, build dirs…) with full evidence before anything moves to Trash.

---

## Architecture

```
Sources/
├── OpenFiles/        # SwiftUI app: browser, panels, agent UI, cloud views
├── OpenFilesCore/    # search, file rules, versions, vault, organization
├── OpenFilesCloud/   # Drive/OneDrive OAuth, transport, sync engine
├── OpenFilesAgent/   # plan-only LLM agent: client, prompts, vision guard
└── OpenFilesMLX/     # optional EmbeddingGemma 2 local inference (OPENFILES_MLX=1)
finder_search/        # Python hybrid engine: BGE-small + SigLIP2 (ONNX, on-device)
tests/                # dependency-free check runners (no XCTest needed)
```

Module boundaries are strict: UI never touches the filesystem directly; every external integration goes through a mockable transport with its own fixture checks. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

---

## Privacy

**Everything runs on your Mac.** No telemetry, no model downloads, no cloud AI receiving file contents. Optional cloud connections use your own OAuth apps; sensitive-classified files are excluded from embeddings, excerpts, exports, and agent prompts by default. The LLM agent sends only file names, paths, sizes, and (opt-in) 400-char text excerpts — filtered locally first.

---

## Docs

| Doc | Covers |
|---|---|
| [Cloud storage setup](docs/CLOUD_STORAGE.md) | OAuth app registration, permissions, sync behavior |
| [EmbeddingGemma 2 (optional MLX)](docs/EMBEDDINGGEMMA.md) | local model setup & cache compatibility |
| [Indexing](docs/INDEXING.md) | measured performance, caching, coverage |
| [Organization](docs/ORGANIZATION.md) | suggested-move rules and limits |
| [Agent](docs/AGENT.md) | what the Ask Hermes agent can and cannot do |
| [Architecture](docs/ARCHITECTURE.md) | module design & implementation sequence |
| [Contributing](CONTRIBUTING.md) | conventions for collaborators |
| [Detailed guide](docs/DETAILED_GUIDE.md) | the full operational README: every feature, limit, and safety rule |

---

*Built with SwiftUI, AppKit, NaturalLanguage, PDFKit, CryptoKit, Vision, PhotoKit — and a lot of care about not deleting your files.*
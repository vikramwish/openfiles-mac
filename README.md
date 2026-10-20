# OpenFiles

A native macOS file search utility with a Spotlight-style search panel, local document ranking, and optional browsing, organization, and version history. Built with **SwiftUI**, Foundation, NaturalLanguage, PDFKit, and CryptoKit. Search is available over other apps with ⌘⇧Space; the native file browser is available when you need it.

## Run

Requires **macOS 14+** and **Swift 5.9+** (Xcode or Command Line Tools). No npm, API keys, backend, or third-party packages.

```sh
git clone https://github.com/yatinbayya/OpenFiles.git
cd OpenFiles
make run
```

`make run` compiles, assembles, ad-hoc signs, and opens `build/OpenFiles.app`. It stays available in the macOS menu bar after its window closes. Quit from the menu bar or with ⌘Q. Rebuild after changes; quit a running copy before replacing its executable. Open `Package.swift` in Xcode if you prefer its editor and debugger.

```sh
make test       # Core behavior tests; no access to your personal folders
make build      # Build the local .app without launching
make release    # Optimized, locally signed .app
OPENFILES_TEST_VAULT=1 swift run --build-system native OpenFilesChecks
```

Checks use a small dependency-free executable because Command Line Tools do not ship XCTest. They return a nonzero exit code on failure. The scripts select SwiftPM's `native` build engine because the Swift 6.4 Command Line Tools on the initial development machine cannot initialize the default Swift Build engine. This option also works with Swift 5.9. No full Xcode installation is needed to run locally.

## Quick search

OpenFiles launches as a compact floating search panel. Press **⌘⇧Space** from any app to toggle it, or choose **Search files…** from the OpenFiles menu bar item. The shortcut uses a registered system hotkey and does not require Accessibility or Input Monitoring permissions. If another app has reserved that chord, the panel reports the conflict and menu-bar access remains available. Apple's Spotlight shortcut is unchanged.

Type a filename or a request such as `find all my australian government related files`. Results update as you type. Use **↑/↓** to select, **Return** to open, **Escape** to dismiss, and the eye button for Quick Look. Double-click also opens a result. Right-click to reveal it in the full browser; **Browse** opens the browser directly.

Search removes conversational filler and uses grouped terms and aliases across Spotlight and the local index. Filename and document-text evidence determine inclusion; embedding similarity boosts grounded results rather than admitting unrelated files by itself. Generated folders, Python package metadata, and installer records are excluded from search results. A lack of confident matches produces an empty state instead of padding the list with weak similarities.

The panel shows up to 100 merged results. Local ranking reads bounded text/PDF prefixes from up to 240 index candidates per request; Spotlight supplies additional indexed content matches, including formats supported by macOS importers. The local index and Spotlight have separate scope and availability limits. Search uses local services; no cloud language model is connected.

## Browse and search

Choose **Browse files** or a sidebar location to use the Finder-like browser. The initial browser location is your home folder. **No folder connection or import is needed.** Use Home, Desktop, Documents, Downloads, Pictures, Music, Movies, Applications, This Mac, iCloud Drive (when present), and mounted volumes in the sidebar.

- Double-click a folder to browse it inside OpenFiles, or a file to open its default editor. Back/forward, parent-folder navigation, clickable breadcrumbs, and **Go to folder** (⌘⇧G) work without Finder.
- **Search this Mac** searches Spotlight's indexed local volumes by filename and content. You can switch to the current folder. Results arrive while background semantic indexing is running. Search shows up to 1,000 Spotlight matches and the top 100 semantic matches; narrow your query to see other matches.
- English semantic indexing starts automatically for your home folder, prioritizing Downloads, Documents, Desktop, Pictures, Music, and Movies. The prototype embeds up to 2,000 files; **this cap does not limit folder browsing or the scope of Spotlight search**. Apple’s model must be available for semantic results.
- Select an item and press Return to open it or Space for a Quick Look preview. Right-click for preview, enclosing-folder navigation, copy path, or commit. ⌘⇧N creates a folder; ⌘⇧. toggles hidden files.
- macOS still enforces folder permissions. Protected folders may require approval in macOS or Full Disk Access. Spotlight excludes locations the OS or user has excluded from indexing. You can still browse accessible unindexed folders directly.

## Organization, history, and vault

Browsing/search access is separate from permission to rearrange files. In **Organize**, explicitly choose folders that may be organized, review the preview, then apply it. Only top-level files unchanged for 10 seconds are eligible. Automation remains off by default; enabling it applies only to those chosen organization targets, never every folder discovered by search.

Select a file in **Browse files** to see its version history in the right panel, with commit messages, timestamps, and saved-change status. Enter an optional message and choose **Commit saved changes**. Files, folders, and packages are supported; history is scoped to the file’s full path.

Open a file from OpenFiles to launch its default editor (including PowerPoint) and show a floating **Versions** panel. The panel stays accessible over other apps. Save in the editor, then commit from the panel or the OpenFiles menu bar. The panel names the tracked file explicitly; it does not automatically follow documents opened directly in other apps. Reopen it from the menu bar, or use the panel button beside a selected file’s history.

Choose **Restore → Open restored copy…** on a version, then choose a destination. OpenFiles verifies a separate copy and opens it in the default app, with the companion now tracking that copy. Your current file is preserved. **Export copy…** saves a copy and reveals it in OpenFiles. Existing restore destinations are never overwritten.

Create a password-protected **Private vault**, copy a file in, and lock it. Browse its contents inside OpenFiles while unlocked. Import preserves the original; verify the copy and remove the original yourself if needed. Quitting attempts to lock the vault; open files can prevent unmounting.

## What this base implements

| Area | Working now | Extension work |
| --- | --- | --- |
| Browsing | Direct filesystem browser, default locations/volumes, history, breadcrumbs, hidden files, path navigation, Quick Look, new folders | Rename, move/copy, Trash, multi-selection, drag/drop, sorting and view modes |
| Search | System-wide Spotlight search plus automatic local English embeddings; bounded text/PDF extraction | Chunked index, OCR, Office parsers, multilingual models, SQLite/vector index |
| Organization | Extension rules, exact move preview, collision refusal, content verification, optional one-minute automation | Rule editor, undo journal, filesystem events, model-based classification |
| Sensitive files | Filename/content heuristics exclude likely matches from embeddings, snapshots, and organization; encrypted APFS vault | Reviewed sensitive-file migration, richer detection, encrypted metadata |
| Versions | Per-file history inspector, saved-change detection, floating editor companion, full snapshots, verified restore-and-open | Content-addressed deduplication, retention, coordinated editor saves, linked asset tracking |
| Menu bar | Commit tracked file, reopen its history panel, or choose another file while other apps are active | Identify the active document via Accessibility or app adapters; Finder extension and global shortcuts |

**“Works with every app” is the direction, not a completed integration.** The snapshot engine accepts saved binary formats without needing to parse them, including PowerPoint, Excel, Photoshop, CAD, and audio/video projects. It cannot capture unsaved editor memory or guarantee a consistent project while another process writes it. A project may reference assets elsewhere; include those in the chosen project folder. No menu item is injected into other applications. Some apps, including SolidWorks, do not run natively on macOS; OpenFiles can store their saved files but does not provide those editors.

## Indexing performance and visibility

Choose **Indexing activity** in the sidebar, footer, or menu bar for live progress, cache decisions, timings, recent paths, skip reasons, current scope, and coverage limits. Pause/resume or stop indexing without interrupting browsing or Spotlight. Adjust the file limit, parallel workers, and semantic exclusions there.

The index now checks Git-style file signatures before reading content and shares model-versioned, content-addressed embedding objects for duplicate text. Unchanged files skip content extraction and inference. Native workers are bounded; vector math uses Accelerate. Apple's internal tokenization is not exposed: the UI explicitly labels diagnostic counts as word units. See [docs/INDEXING.md](docs/INDEXING.md) for measured results, caching/recovery details, storage disclosures, and the reproducible release benchmark.

## Data and privacy

All application state lives in `~/Library/Application Support/OpenFiles/`:

- `library.json`: organization targets, file metadata, embedding vectors, and version metadata. No extracted document text is retained. This index is **not encrypted**; filenames, paths, and embeddings can reveal information.
- `IndexObjects/<hash>.json`: model-versioned, content-addressed vectors and word-unit/timing metadata; extracted document text is not retained. Objects remain until future cache cleanup.
- `Versions/<id>/`: full copies of committed files/projects. Sensitive-content checks are heuristics, not a confidentiality guarantee. Snapshots are local history, not an off-device backup.
- `Private.sparsebundle`: AES-256 encrypted APFS disk image, 10 GB logical capacity, allocated as needed.
- `vault-mount/`: mount point while unlocked. Vault content is accessible to the logged-in user and their processes while mounted. Passwords are not stored, logged, or passed as process arguments; there is no password recovery.

No telemetry, cloud API, or automatic model download is implemented. Browsing can visit any accessible location. Spotlight search results are not persisted. Automatic semantic indexing excludes hidden files, symbolic links, common generated directories, app data, and vault content. Semantic scans default to 2,000 indexed files with a configurable 10,000/unlimited option; text extraction at 5 MB files / 12,000 characters; PDFs at 20 pages; embeddings at 4,000 characters. Native packages are treated as single projects. Sensitive detection cannot find every secret, especially in opaque binary formats.

This is an unsandboxed, locally signed developer app. macOS may ask for access to protected folders during browsing or automatic indexing. Distribution needs a stable signing identity, hardened runtime/notarization, and a decision about sandboxing and security-scoped bookmarks.

## Work together

- UI and application state: `Sources/OpenFiles/`
- Search, file rules, snapshots, filesystem boundaries, vault: `Sources/OpenFilesCore/`
- Tests: `Tests/OpenFilesChecks/`
- Build/run: `scripts/` and `Makefile`
- Architecture and implementation sequence: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- Collaboration conventions: [CONTRIBUTING.md](CONTRIBUTING.md)

One teammate can own SwiftUI and workflow design while the other extends the core services. Keep the library API as the boundary, and avoid filesystem work on the main actor. CI builds and tests on macOS for pushes and pull requests.

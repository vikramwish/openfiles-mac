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

The panel shows up to 100 merged results. Its primary path uses in-memory inverted postings and cached metadata: no document reads, metadata restats, or model calls are required to display the first results. Debounced embedding refinement and supplemental Spotlight topic results arrive separately. A first indexing pass is needed for content search; existing filename records remain searchable during migration. No cloud language model is connected.

Natural-language navigation supports type, location, relative **modification** dates, recent-first ordering, and grouping: try `PDFs in Downloads this month`, `government files grouped by folder`, or `recent images grouped by month`. Group by folder, kind, or month and select a group chip to narrow the displayed results. The bookmark button saves the query as a live smart group; relative dates are reevaluated when it is opened. Saved groups change the view, not the files.

Filesystem events feed a debounced queue for create/edit/rename/delete reconciliation. Only changed files or affected directory subtrees are processed. Paused indexing queues changes; missed events, wake, launch, and a five-minute reconciliation pass catch gaps. Sync operates while OpenFiles runs, does not download cloud placeholders, and is limited to configured/discovered scopes. New default indexes are unlimited; existing user-selected limits are preserved. The panel reports indexed count and sync state.

## Image-content search

Search the pixels as well as filenames: `zebra`, `images of a zebra`, or `pictures of zebras` can find a recognized zebra in a photo named `IMG_0042.jpg`. Apple Vision classifies subjects/scenes and recognizes text inside images during background indexing. Subject labels, confidence scores, and normalized OCR terms are persisted locally; queries use the same fast inverted index and label visual hits **Image subject match**.

Supported raster formats are JPEG, PNG, HEIC/HEIF, TIFF, GIF (first frame), BMP, and WebP when decodable by macOS. Analysis uses an orientation-correct thumbnail capped at 2,048 pixels, files up to 50 MB, up to 12 subject labels at confidence 0.25 or higher, and bounded OCR text. Unchanged analyses are cached even when the text-embedding model is unavailable. Existing image records are refreshed automatically on a background indexing pass.

This is classifier-based content search, not an unrestricted vision-language model: recognition can miss subjects or produce incorrect labels, and complex spatial/compositional descriptions are not supported. OCR-based sensitivity checks suppress derived content when they flag a file, but cannot detect every sensitive image. No images are uploaded, no source files are changed, and pixels are not reread at query time.

## Browse and search

Choose **Browse files** or a sidebar location to use the Finder-like browser. The initial browser location is your home folder. **No folder connection or import is needed.** Use Home, Desktop, Documents, Downloads, Pictures, Music, Movies, Applications, This Mac, iCloud Drive (when present), and mounted volumes in the sidebar.

- Double-click a folder to browse it inside OpenFiles, or a file to open its default editor. Back/forward, parent-folder navigation, clickable breadcrumbs, and **Go to folder** (⌘⇧G) work without Finder.
- **Search this Mac** searches Spotlight's indexed local volumes by filename and content. You can switch to the current folder. Results arrive while background semantic indexing is running. Search shows up to 1,000 Spotlight matches and the top 100 semantic matches; narrow your query to see other matches.
- English semantic indexing starts automatically for your home folder, prioritizing Downloads, Documents, Desktop, Pictures, Music, and Movies. New indexes have no file-count cap; an optional limit is available in Indexing activity. **Index limits do not limit folder browsing or Spotlight search**. Apple’s model must be available for semantic results.
- Select an item and press Return to open it or Space for a Quick Look preview. Right-click for preview, enclosing-folder navigation, copy path, or commit. ⌘⇧N creates a folder; ⌘⇧. toggles hidden files.
- macOS still enforces folder permissions. Protected folders may require approval in macOS or Full Disk Access. Spotlight excludes locations the OS or user has excluded from indexing. You can still browse accessible unindexed folders directly.

Use **File → New Window** (⌘N) or **New Window** in the OpenFiles menu bar menu to open another workspace. Each window keeps its own folder, selection, search, navigation history, and commit message. Indexing, version history, and vault state are shared; menu commands follow the active window. Closing one window leaves the others open.

## Organization, history, and vault

**Organize → Analyze My Files** compares existing content embeddings across nested personal folders throughout your home and added locations. It suggests content topics (Work, Study, Travel, Home, Creative, Purchases, Events, Cooking) under `~/Organized`, with source/destination paths, similarity scores, and exclusion counts. Review up to 200 suggestions per pass, select individual files, then choose **Move Selected Files**. Analysis never moves files. Filename-only embeddings, uncertain matches, sensitive files, recognized projects, and system/app folders are excluded. Only indexed content can be analyzed; indexing activity shows remaining coverage. [Organization behavior and limits](docs/ORGANIZATION.md).

Select a file in **Browse files** to see **Changes** and **History** in the right panel. Write a commit message, select the changes to include, and choose **Commit selected changes**. Commits use internal storage automatically: there is no destination picker or commit sheet. Unselected edits stay in the working file and remain available for a later commit.

Text files show selectable line changes. Folders and project packages show selectable files, including additions and deletions. PowerPoint and other binary formats use whole-document snapshots; individual slide or object changes are not yet supported. Text diffing is bounded to UTF-8 files up to 1 MB and 10,000 lines; larger files use whole-document snapshots.

In **History**, choose **Cherry-pick…** to review a commit’s changes and apply only the selected ones, with a message. Unrelated working changes are preserved. Conflicts and stale reviews stop the operation before replacement. **Restore** updates the original path without a dialog; current saved work is first retained in an automatic recovery version. You can restore that recovery version to undo. **Export copy…** in the full history screen remains a separate, explicit export action.

Open a file from OpenFiles to launch its default editor (including PowerPoint) and show the floating **Versions** companion. The menu bar’s **Review & commit** action opens the same message composer, rather than making an unnamed commit. History follows the named file, not whichever document happens to be active in another app. Commit captures the bytes already saved on disk; it cannot read unsaved edits in an editor’s memory or force an editor to reload after restoration. Save before committing and reload the document in its editor after restore/cherry-pick if the editor still shows its cached contents.

Create a password-protected **Private vault**, copy a file in, and lock it. Browse its contents inside OpenFiles while unlocked. Import preserves the original; verify the copy and remove the original yourself if needed. Quitting attempts to lock the vault; open files can prevent unmounting.

## What this base implements

| Area | Working now | Extension work |
| --- | --- | --- |
| Browsing | Direct filesystem browser, default locations/volumes, history, breadcrumbs, hidden files, path navigation, Quick Look, new folders | Rename, move/copy, Trash, multi-selection, drag/drop, sorting and view modes |
| Search | System-wide Spotlight search plus automatic local English embeddings; bounded text/PDF extraction | Chunked index, OCR, Office parsers, multilingual models, SQLite/vector index |
| Organization | Extension rules, exact move preview, collision refusal, content verification, optional one-minute automation | Rule editor, undo journal, filesystem events, model-based classification |
| Sensitive files | Filename/content heuristics exclude likely matches from embeddings, snapshots, and organization; encrypted APFS vault | Reviewed sensitive-file migration, richer detection, encrypted metadata |
| Versions | Inline messages and change selection, text/file cherry-pick with conflict checks, automatic recovery, verified in-place restore | Content-addressed deduplication, retention, coordinated editor saves, linked asset tracking |
| Menu bar | Commit tracked file, reopen its history panel, or choose another file while other apps are active | Identify the active document via Accessibility or app adapters; Finder extension and global shortcuts |

**“Works with every app” is the direction, not a completed integration.** The snapshot engine accepts saved binary formats without needing to parse them, including PowerPoint, Excel, Photoshop, CAD, and audio/video projects. It cannot capture unsaved editor memory or guarantee a consistent project while another process writes it. A project may reference assets elsewhere; include those in the chosen project folder. No menu item is injected into other applications. Some apps, including SolidWorks, do not run natively on macOS; OpenFiles can store their saved files but does not provide those editors.

## Indexing performance and visibility

Choose **Indexing activity** in the sidebar, footer, or menu bar for live progress, cache decisions, timings, recent paths, skip reasons, current scope, and coverage limits. Pause/resume or stop indexing without interrupting browsing or Spotlight. Adjust the file limit, parallel workers, and semantic exclusions there.

The index now checks Git-style file signatures before reading content and shares model-versioned, content-addressed embedding objects for duplicate text. Unchanged files skip content extraction and inference. Native workers are bounded; vector math uses Accelerate. Apple's internal tokenization is not exposed: the UI explicitly labels diagnostic counts as word units. See [docs/INDEXING.md](docs/INDEXING.md) for measured results, caching/recovery details, storage disclosures, and the reproducible release benchmark.

## Data and privacy

All application state lives in `~/Library/Application Support/OpenFiles/`:

- `library.json`: organization targets, file metadata, embedding vectors, and version metadata. Normalized unique search terms from bounded document prefixes are persisted for fast lookup; full extracted text is not retained. Sensitive-classified content has no stored terms or embeddings. This index is **not encrypted**; terms, filenames, paths, and embeddings can reveal information.
- `IndexObjects/<hash>.json`: model-versioned, content-addressed vectors and word-unit/timing metadata; extracted document text is not retained. Objects remain until future cache cleanup.
- `Versions/<id>/`: full copies of committed files/projects. Sensitive-content checks are heuristics, not a confidentiality guarantee. Snapshots are local history, not an off-device backup.
- `Private.sparsebundle`: AES-256 encrypted APFS disk image, 10 GB logical capacity, allocated as needed.
- `vault-mount/`: mount point while unlocked. Vault content is accessible to the logged-in user and their processes while mounted. Passwords are not stored, logged, or passed as process arguments; there is no password recovery.

No telemetry, cloud API, or automatic model download is implemented. Browsing can visit any accessible location. Spotlight search results are not persisted. Automatic semantic indexing excludes hidden files, symbolic links, common generated directories, app data, and vault content. New semantic indexes default to unlimited files, with configurable 2,000/10,000 limits; text extraction at 5 MB files / 12,000 characters; PDFs at 20 pages; embeddings at 4,000 characters. Native packages are treated as single projects. Sensitive detection cannot find every secret, especially in opaque binary formats.

This is an unsandboxed, locally signed developer app. macOS may ask for access to protected folders during browsing or automatic indexing. Distribution needs a stable signing identity, hardened runtime/notarization, and a decision about sandboxing and security-scoped bookmarks.

## Search safety and performance

Search, indexing, filesystem sync, and smart groups only read original files. They write derived index data and query definitions inside application support. Query text is never executed as shell commands or file actions. Separate manual organization and version operations retain their previews, collision checks, integrity checks, and recovery behavior. This does not promise zero software or hardware risk; local version snapshots are not an independent backup.

The reproducible search benchmark uses 10,000 synthetic metadata/term records and 120 queries covering topic/prefix lookup, type/date/location filters, and all-files/recent navigation. On the development machine the fast path measured about **6.8 ms median / 25.7 ms p95**, with zero document reads or inference calls per fast query. These are core lookup timings, not end-to-end UI latency or a guarantee for larger personal libraries.

```sh
swift run --build-system native -c release OpenFilesBenchmark --search-only --count 10000
```

## Work together

- UI and application state: `Sources/OpenFiles/`
- Search, file rules, snapshots, filesystem boundaries, vault: `Sources/OpenFilesCore/`
- Tests: `Tests/OpenFilesChecks/`
- Build/run: `scripts/` and `Makefile`
- Architecture and implementation sequence: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- Collaboration conventions: [CONTRIBUTING.md](CONTRIBUTING.md)

One teammate can own SwiftUI and workflow design while the other extends the core services. Keep the library API as the boundary, and avoid filesystem work on the main actor. CI builds and tests on macOS for pushes and pull requests.

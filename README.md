# OpenFiles

A native macOS document assistant with fast local search, reviewable document packs, automatic saved-file history, browsing, and organization. Built with **SwiftUI**, Foundation, NaturalLanguage, PDFKit, and CryptoKit. Search is available over other apps with ⌘⇧Space; the native file browser is available when you need it.

## Run

Requires **macOS 14+** and **Swift 5.9+** (Xcode or Command Line Tools). No npm, backend, or third-party packages. Local features need no credentials; optional Google Drive and OneDrive connections need native OAuth app registrations.

These requirements describe the default Apple search backend. The optional EmbeddingGemma 2 build adds local MLX inference and has the additional requirements below.

```sh
git clone https://github.com/yatinbayya/OpenFiles.git
cd OpenFiles
make run
```

`make run` compiles, assembles, ad-hoc signs, and opens `build/OpenFiles.app`. It stays available in the macOS menu bar after its window closes. Quit from the menu bar or with ⌘Q. Rebuild after changes; quit a running copy before replacing its executable. Open `Package.swift` in Xcode if you prefer its editor and debugger.

```sh
make test       # Local and mocked cloud checks; no personal folders or accounts
make build      # Build the local .app without launching
make release    # Optimized, locally signed .app
OPENFILES_TEST_VAULT=1 swift run --build-system native OpenFilesChecks
swift run --build-system native OpenFilesCloudChecks  # Mocked provider checks; no accounts needed
```

Checks use a small dependency-free executable because Command Line Tools do not ship XCTest. They return a nonzero exit code on failure. The scripts select SwiftPM's `native` build engine because the Swift 6.4 Command Line Tools on the initial development machine cannot initialize the default Swift Build engine. This option also works with Swift 5.9. No full Xcode installation is needed to run locally.

## EmbeddingGemma 2 search (optional)

OpenFiles integrates [Google's EmbeddingGemma 2](https://huggingface.co/google/embeddinggemma-2) with the existing local search pipeline. It requires an **Apple Silicon Mac and full Xcode with Swift 6.3+**. Build with:

```sh
OPENFILES_MLX=1 make test
OPENFILES_MLX=1 make run
```

Download a compatible checkpoint first, then open **Indexing activity → Search model → Use EmbeddingGemma 2…** and select its folder. The app checks and loads the model before saving your selection. Query and document text stays on your Mac; OpenFiles does not download weights or call an inference service. Changing models rebuilds embeddings on the next pass. The Apple model remains available.

See [docs/EMBEDDINGGEMMA.md](docs/EMBEDDINGGEMMA.md) for model download commands, how retrieval works, cache compatibility, and the optional real-model check. Filename/Spotlight search and the existing relevance rules continue to apply: similarity boosts matches with filename/document evidence.

## Home and document packs

OpenFiles opens Home with three starting points: **Find something**, **Prepare documents**, and **Recover a version**. The menu bar and sidebar keep all three available.

**Prepare documents** creates a local checklist from Rental application, Expense claim, Travel documents, or a custom template. Edit the title, requirements, instructions, and search words; comma-separated search words act as alternatives. Suggestions show their matching evidence and never attach files automatically. Choose files manually for sensitive or unindexed documents.

Review each attached file in its preview, then choose **Mark as reviewed**. **Export copies…** creates a new folder with verified copies and a checklist that clearly lists missing required and omitted optional items. Export refuses unreviewed, missing, changed, linked, or cloud-placeholder files and cleans up a failed export. Originals stay in place. Review copies before sharing; exports include whole files without automatic redaction. Templates are editable starting points, not official requirements or checks of legal validity or expiry. Checklist metadata is local, private-permission JSON, not encrypted storage.

## Automatic versions

Choose **Automatic versions → Choose files or folders…** to opt important saved files or small folders into local history. Checks run every 30 seconds while OpenFiles is running, after a brief saving quiet period; unchanged contents are skipped. Use **Check now**, pause individual locations or all protection, or stop protecting a location. Stopping keeps existing versions. Open a location’s versions to review and restore earlier work.

Folders are complete snapshots. Each selection is limited to 100 MB and 2,000 entries; up to 20 locations can be selected. Hidden/generated items, symbolic links, indexing exclusions, cloud placeholders, and potentially sensitive content can prevent a snapshot, with the reason shown beside the location. Automatic history keeps up to 20 automatic versions per location within a shared 1 GB payload allowance; manual versions are preserved. Storage accounting uses the captured payload. Protection captures saved bytes, runs only while the app is open, and provides local history rather than an independent backup.

## Quick search

OpenFiles includes a compact floating search panel. Press **⌘⇧Space** from any app to toggle it, or choose **Search files…** from the OpenFiles menu bar item. The shortcut uses a registered system hotkey and does not require Accessibility or Input Monitoring permissions. If another app has reserved that chord, the panel reports the conflict and menu-bar access remains available. Apple's Spotlight shortcut is unchanged.

Type a filename or a request such as `find all my australian government related files`. Results update as you type. Use **↑/↓** to select, **Return** to open, **Escape** to dismiss, and the eye button for Quick Look. Double-click also opens a result. Right-click to reveal it in the full browser; **Browse** opens the browser directly.

Search removes conversational filler and uses grouped terms and aliases across Spotlight and the local index. Filename and document-text evidence determine inclusion; embedding similarity boosts grounded results rather than admitting unrelated files by itself. Generated folders, Python package metadata, and installer records are excluded from search results. A lack of confident matches produces an empty state instead of padding the list with weak similarities.

The panel shows up to 100 merged results. Its primary path uses in-memory inverted postings and cached metadata: no document reads, metadata restats, or model calls are required to display the first results. Debounced embedding refinement and supplemental Spotlight topic results arrive separately. A first indexing pass is needed for content search; existing filename records remain searchable during migration. No cloud language model is connected.

Natural-language navigation supports type, location, relative **modification** dates, recent-first ordering, and grouping: try `PDFs in Downloads this month`, `government files grouped by folder`, or `recent images grouped by month`. Group by folder, kind, or month and select a group chip to narrow the displayed results. The bookmark button saves the query as a live smart group; relative dates are reevaluated when it is opened. Saved groups change the view, not the files.

Filesystem events feed a debounced queue for create/edit/rename/delete reconciliation. Only changed files or affected directory subtrees are processed. Paused indexing queues changes; missed events, wake, launch, and a five-minute reconciliation pass catch gaps. Sync operates while OpenFiles runs, does not download cloud placeholders, and is limited to configured/discovered scopes. New default indexes are unlimited; existing user-selected limits are preserved. The panel reports indexed count and sync state.

## Photo location search

Use `photos taken in Sydney`, `images near Melbourne`, or `zebra photos in Sydney`. Background indexing reads embedded GPS and IPTC city, sublocation, state/province, and country names. Search uses cached place postings; it performs no geocoding requests or source-file reads. Original images are never rewritten.

GPS-only named-place lookup currently covers Sydney, Melbourne, Brisbane, Perth, Adelaide, Canberra, Hobart, Darwin, Gold Coast, Newcastle, Auckland, Wellington, London, Paris, New York, San Francisco, Los Angeles, Tokyo, and Singapore. These use approximate city-centre radii (20–50 km), not administrative boundaries. Other places work when their exact names are embedded in IPTC metadata. Missing GPS/place metadata cannot be inferred from pixels, and GPS alone does not yet map countries or states. Existing image records refresh on the next indexing pass. Coordinates and place names are persisted locally in the **unencrypted** index; sensitive-classified images retain neither. Folder filters such as `photos in Pictures` retain their existing meaning. Relative dates still refer to file modification time, not EXIF capture time.

## Image-content search

Search the pixels as well as filenames: `zebra`, `images of a zebra`, or `pictures of zebras` can find a recognized zebra in a photo named `IMG_0042.jpg`. Apple Vision classifies subjects/scenes and recognizes text inside images during background indexing. Subject labels, confidence scores, and normalized OCR terms are persisted locally; queries use the same fast inverted index and label visual hits **Image subject match**.

Supported raster formats are JPEG, PNG, HEIC/HEIF, TIFF, GIF (first frame), BMP, and WebP when decodable by macOS. Analysis uses an orientation-correct thumbnail capped at 2,048 pixels, files up to 50 MB, up to 12 subject labels at confidence 0.25 or higher, and bounded OCR text. Unchanged analyses are cached even when the text-embedding model is unavailable. Existing image records are refreshed automatically on a background indexing pass.

This is classifier-based content search, not an unrestricted vision-language model: recognition can miss subjects or produce incorrect labels, and complex spatial/compositional descriptions are not supported. OCR-based sensitivity checks suppress derived content when they flag a file, but cannot detect every sensitive image. No images are uploaded, no source files are changed, and pixels are not reread at query time.

## Browse and search

Choose **Browse files** or a sidebar location to use the Finder-like browser. The initial browser location is your home folder. **No folder connection or import is needed.** Use Home, Desktop, Documents, Downloads, Pictures, Music, Movies, Applications, This Mac, iCloud Drive (when present), and mounted volumes in the sidebar.

- Double-click a folder to browse it inside OpenFiles, or a file to open its default editor. Back/forward, parent-folder navigation, clickable breadcrumbs, and **Go to folder** (⌘⇧G) work without Finder.
- **Search this Mac** searches Spotlight's indexed local volumes by filename and content. You can switch to the current folder. Results arrive while background semantic indexing is running. Search shows up to 1,000 Spotlight matches and the top 100 semantic matches; narrow your query to see other matches.
- English semantic indexing starts automatically for your home folder, prioritizing Downloads, Documents, Desktop, Pictures, Music, and Movies. New indexes have no file-count cap; an optional limit is available in Indexing activity. **Index limits do not limit folder browsing or Spotlight search**. Apple’s model must be available for semantic results.
- Select a file to see its preview, size, and location in the right panel. Switch that panel to **History** for saved versions and changes. Press Return to open it or Space for a larger Quick Look preview. Right-click for preview, enclosing-folder navigation, copy path, or commit. ⌘⇧N creates a folder; ⌘⇧. toggles hidden files.
- macOS still enforces folder permissions. Protected folders may require approval in macOS or Full Disk Access. Spotlight excludes locations the OS or user has excluded from indexing. You can still browse accessible unindexed folders directly.

Use **File → New Window** (⌘N) or **New Window** in the OpenFiles menu bar menu to open another workspace. Each window keeps its own folder, selection, search, navigation history, and commit message. Indexing, version history, and vault state are shared; menu commands follow the active window. Closing one window leaves the others open.

## Google Drive and OneDrive

Use **Cloud storage** to connect directly to Google Drive or Microsoft OneDrive, browse remote folders, and save selected files as local copies. The providers' Mac sync apps are not required. Connections start read-only. Enable **uploads and two-way sync** and reconnect to upload files or pair local/cloud folders. Preview and apply sync, or opt into one-minute passes while the app runs. Conflicts pause automatic sync; deletions remain manual. Google Workspace documents open in the provider's website.

You need a native OAuth app registration for each provider. Registration fields and tokens are stored in macOS Keychain. See [cloud storage setup](docs/CLOUD_STORAGE.md) for registration, permissions, account connection, and validation instructions. Browsing does not automatically download or index remote contents. Explicitly paired folders can transfer contents in both directions; downloaded files can enter normal local indexing. Sync retains local backups before replacements.

Choose **Google Drive** or **OneDrive** in the sidebar to open the provider's files. Signing in loads the root folder automatically; connection settings collapse to leave room for the listing. **Home → Cloud documents** also shows up to eight items from the current cloud folder, with folder navigation, previews, and a link to the full listing. Each remote row shows its provider and folder, and local browsing/search shows a storage-location tag. The main window's storage bar shows used, available, and total space for your current local volume and selected connected cloud account. Google account usage includes Gmail and Photos where applicable. Unknown limits and quota errors are displayed without hiding files.

Select a supported cloud file to preview a temporary copy inline. Preview requires a known size of at most 25 MiB; Google Workspace documents open on the provider's website. Close the preview to remove its temporary copy, or choose **Save copy…** to keep a separate local file. Sync conflicts offer **Compare copies…**, text differences or side-by-side previews, and explicit **Keep local copy** / **Keep cloud copy** actions with verified backups.

Home's **Suggested for cloud storage** uses local index metadata to suggest large files or older files. **Review upload…** shows the source, indexed size, and current cloud destination before sending a copy. Uploads require write consent and keep local originals, so they do not free disk space. Verify the uploaded copy before separately deciding whether to remove a local original.

## Suggested filenames

Select a downloaded file in **Browse files** and choose **Suggest Filename…**, or use its context menu. OpenFiles takes phrases from readable content and ranks them using the active search embedding model, including optional EmbeddingGemma 2. Review up to three alternatives, optionally edit the name, then choose **Rename file**. The extension and folder stay the same. Existing destinations and files changed since preview are refused; bytes are verified before removing the old path.

Suggestions support text, readable PDFs, and readable images up to 5 MB. Sensitive or excluded files, folders, unavailable models, and unsupported content get an explicit explanation. Remote files must first be downloaded or synced to your Mac. This renames the local copy; cloud sync still treats a rename as a new filename and a missing old file, with deletions left for manual review. Existing version history remains associated with its original path.

For a batch, use Command/Shift to select up to 50 files and choose **Suggest Filenames…**. Review alternatives per file, optionally apply a shared prefix and modification date, edit names, then check the rows to apply. All chosen destinations and source fingerprints are validated before the first rename. The report lists each success or failure; unselected files stay unchanged.

## Organization, history, and vault

**Organize → Analyze My Files** compares existing content embeddings across nested personal folders throughout your home and added locations. It suggests content topics (Work, Study, Travel, Home, Creative, Purchases, Events, Cooking) under `~/Organized`, with source/destination paths, similarity scores, and exclusion counts. Review up to 200 suggestions per pass, select individual files, then choose **Move Selected Files**. Analysis never moves files. Filename-only embeddings, uncertain matches, sensitive files, recognized projects, and system/app folders are excluded. Only indexed content can be analyzed; indexing activity shows remaining coverage. [Organization behavior and limits](docs/ORGANIZATION.md).

Select a file in **Browse files** and switch the right panel from **Preview** to **History** to see changes and saved versions. Write a commit message, select the changes to include, and choose **Commit selected changes**. Commits use internal storage automatically: there is no destination picker or commit sheet. Unselected edits stay in the working file and remain available for a later commit.

Text files show selectable line changes. Folders and project packages show selectable files, including additions and deletions. PowerPoint and other binary formats use whole-document snapshots; individual slide or object changes are not yet supported. Text diffing is bounded to UTF-8 files up to 1 MB and 10,000 lines; larger files use whole-document snapshots.

In **History**, choose **Cherry-pick…** to review a commit’s changes and apply only the selected ones, with a message. Unrelated working changes are preserved. Conflicts and stale reviews stop the operation before replacement. **Restore** updates the original path without a dialog; current saved work is first retained in an automatic recovery version. You can restore that recovery version to undo. **Export copy…** in the full history screen remains a separate, explicit export action.

Open a file from OpenFiles to launch its default editor (including PowerPoint) and show the floating **Versions** companion. The menu bar’s **Review & commit** action opens the same message composer, rather than making an unnamed commit. History follows the named file, not whichever document happens to be active in another app. Commit captures the bytes already saved on disk; it cannot read unsaved edits in an editor’s memory or force an editor to reload after restoration. Save before committing and reload the document in its editor after restore/cherry-pick if the editor still shows its cached contents.

Create a password-protected **Private vault**, copy a file in, and lock it. Browse its contents inside OpenFiles while unlocked. Import preserves the original; verify the copy and remove the original yourself if needed. Quitting attempts to lock the vault; open files can prevent unmounting.

## What this base implements

| Area | Working now | Extension work |
| --- | --- | --- |
| Browsing | Direct filesystem browser, default locations/volumes, history, breadcrumbs, hidden files, path navigation, Quick Look, new folders | Rename, move/copy, Trash, multi-selection, drag/drop, sorting and view modes |
| Cloud storage | Google Drive/OneDrive sign-in, browsing, downloads, chunked uploads, paired two-way sync with conflict checks and local backups, Keychain credentials | Deletion propagation, rename inference, multiple accounts per provider, shared drives, Workspace exports, remote search |
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

Local library and vault state lives in `~/Library/Application Support/OpenFiles/`:

- `library.json`: organization targets, file metadata, embedding vectors, and version metadata. Normalized unique search terms from bounded document prefixes are persisted for fast lookup; full extracted text is not retained. Sensitive-classified content has no stored terms or embeddings. This index is **not encrypted**; terms, filenames, paths, and embeddings can reveal information.
- `IndexObjects/<hash>.json`: model-versioned, content-addressed vectors and word-unit/timing metadata; extracted document text is not retained. Objects remain until future cache cleanup.
- `Versions/<id>/`: full copies of committed files/projects. Sensitive-content checks are heuristics, not a confidentiality guarantee. Snapshots are local history, not an off-device backup.
- `CloudSync/`: pairing metadata, SHA-256 fingerprints, remote revisions, and unencrypted backups of local files replaced by sync. Backups have no automatic retention limit; see [sync behavior and limits](docs/CLOUD_STORAGE.md#pair-and-sync-folders).

- `DocumentPacks/<id>.json`: checklist titles, instructions, source paths, and review hashes; no document copies until explicit export. Metadata is not encrypted.
- `automatic-history.json`: opted-in locations, pause/status data, and automatic-version retention receipts. Payloads use the existing `Versions/` storage.
- `Private.sparsebundle`: AES-256 encrypted APFS disk image, 10 GB logical capacity, allocated as needed.
- `vault-mount/`: mount point while unlocked. Vault content is accessible to the logged-in user and their processes while mounted. Passwords are not stored, logged, or passed as process arguments; there is no password recovery.

Optional cloud connections use the Google Drive API and Microsoft Graph. Their OAuth tokens and registration fields live in macOS Keychain; remote listings remain in memory, and manual downloads go to a location you choose; uploads and sync require explicit write consent and folder pairing. See [cloud data and permissions](docs/CLOUD_STORAGE.md#data-and-permissions). Disconnect removes local authorization; provider-side revocation is managed in the provider's account settings.

No telemetry or automatic model download is implemented. Browsing can visit any accessible location. Spotlight search results are not persisted. Automatic semantic indexing excludes hidden files, symbolic links, common generated directories, app data, and vault content. New semantic indexes default to unlimited files, with configurable 2,000/10,000 limits; text extraction at 5 MB files / 12,000 characters; PDFs at 20 pages; embeddings at 4,000 characters. Native packages are treated as single projects. Sensitive detection cannot find every secret, especially in opaque binary formats.

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
- Cloud provider requests, OAuth exchange, refresh, downloads: `Sources/OpenFilesCloud/`
- Tests: `Tests/OpenFilesChecks/` and `Tests/OpenFilesCloudChecks/`
- Build/run: `scripts/` and `Makefile`
- Architecture and implementation sequence: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- Collaboration conventions: [CONTRIBUTING.md](CONTRIBUTING.md)

One teammate can own SwiftUI and workflow design while the other extends the core services. Keep the library API as the boundary, and avoid filesystem work on the main actor. CI builds and tests on macOS for pushes and pull requests.

## Safe UI smoke testing

After `make build`, create a disposable directory under `/private/tmp` and run the executable with `OPENFILES_UI_SMOKE_ROOT` set to that directory. `OPENFILES_UI_SMOKE_SECTION` selects `home`, `packs`, `protection`, or `history`. This mode uses only `<fixture>/app-state`, bypasses default home discovery, search registration, background indexing, and automatic protection polling. Invalid fixture paths fail closed.

```sh
mkdir -p /private/tmp/openfiles-ui-fixture
OPENFILES_UI_SMOKE_ROOT=/private/tmp/openfiles-ui-fixture OPENFILES_UI_SMOKE_SECTION=home build/OpenFiles.app/Contents/MacOS/OpenFiles
```

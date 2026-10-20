# OpenFiles

A native macOS foundation for finding, organizing, and versioning your files. Built with **SwiftUI**, Foundation, NaturalLanguage, PDFKit, and CryptoKit. The interface takes its neutral palette, outlined cards, and sidebar hierarchy from shadcn/ui; it uses native controls throughout.

## Run

Requires **macOS 14+** and **Swift 5.9+** (Xcode or Command Line Tools). No npm, backend, or third-party packages. Local features need no credentials; optional Google Drive and OneDrive connections need native OAuth app registrations.

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

## Browse and search

OpenFiles opens directly into your home folder. **No folder connection or import is needed.** Use Home, Desktop, Documents, Downloads, Pictures, Music, Movies, Applications, This Mac, iCloud Drive (when present), and mounted volumes in the sidebar.

- Double-click a folder to browse it inside OpenFiles, or a file to open its default editor. Back/forward, parent-folder navigation, clickable breadcrumbs, and **Go to folder** (⌘⇧G) work without Finder.
- **Search this Mac** searches Spotlight's indexed local volumes by filename and content. You can switch to the current folder. Results arrive while background semantic indexing is running. Search shows up to 1,000 Spotlight matches and the top 100 semantic matches; narrow your query to see other matches.
- English semantic indexing starts automatically for your home folder, prioritizing Downloads, Documents, Desktop, Pictures, Music, and Movies. The prototype embeds up to 2,000 files; **this cap does not limit folder browsing or the scope of Spotlight search**. Apple’s model must be available for semantic results.
- Select an item and press Return to open it or Space for a Quick Look preview. Right-click for preview, enclosing-folder navigation, copy path, or commit. ⌘⇧N creates a folder; ⌘⇧. toggles hidden files.
- macOS still enforces folder permissions. Protected folders may require approval in macOS or Full Disk Access. Spotlight excludes locations the OS or user has excluded from indexing. You can still browse accessible unindexed folders directly.

## Google Drive and OneDrive

Use **Cloud storage** to connect directly to Google Drive or Microsoft OneDrive, browse remote folders, and save selected files as local copies. The providers' Mac sync apps are not required. Connections start read-only. Enable **uploads and two-way sync** and reconnect to upload files or pair local/cloud folders. Preview and apply sync, or opt into one-minute passes while the app runs. Conflicts pause automatic sync; deletions remain manual. Google Workspace documents open in the provider's website.

You need a native OAuth app registration for each provider. Registration fields and tokens are stored in macOS Keychain. See [cloud storage setup](docs/CLOUD_STORAGE.md) for registration, permissions, account connection, and validation instructions. Browsing does not automatically download or index remote contents. Explicitly paired folders can transfer contents in both directions; downloaded files can enter normal local indexing. Sync retains local backups before replacements.

## Organization, history, and vault

Browsing/search access is separate from permission to rearrange files. In **Organize**, explicitly choose folders that may be organized, review the preview, then apply it. Only top-level files unchanged for 10 seconds are eligible. Automation remains off by default; enabling it applies only to those chosen organization targets, never every folder discovered by search.

Save your work in its editor, then choose **Commit file…** or **Commit project folder…** from the window or menu bar. Add a message. **Restore copy…** exports a verified copy without overwriting your working file and displays its destination inside OpenFiles.

Create a password-protected **Private vault**, copy a file in, and lock it. Browse its contents inside OpenFiles while unlocked. Import preserves the original; verify the copy and remove the original yourself if needed. Quitting attempts to lock the vault; open files can prevent unmounting.

## What this base implements

| Area | Working now | Extension work |
| --- | --- | --- |
| Browsing | Direct filesystem browser, default locations/volumes, history, breadcrumbs, hidden files, path navigation, Quick Look, new folders | Rename, move/copy, Trash, multi-selection, drag/drop, sorting and view modes |
| Cloud storage | Google Drive/OneDrive sign-in, browsing, downloads, chunked uploads, paired two-way sync with conflict checks and local backups, Keychain credentials | Deletion propagation, rename inference, multiple accounts per provider, shared drives, Workspace exports, remote search |
| Search | System-wide Spotlight search plus automatic local English embeddings; bounded text/PDF extraction | Chunked index, OCR, Office parsers, multilingual models, SQLite/vector index |
| Organization | Extension rules, exact move preview, collision refusal, content verification, optional one-minute automation | Rule editor, undo journal, filesystem events, model-based classification |
| Sensitive files | Filename/content heuristics exclude likely matches from embeddings, snapshots, and organization; encrypted APFS vault | Reviewed sensitive-file migration, richer detection, encrypted metadata |
| Versions | Full file/folder/package snapshots, SHA-256 verification, commit messages, non-destructive restore | Content-addressed deduplication, retention, coordinated editor saves, linked asset tracking |
| Menu bar | Commit picker available while other apps are active | Identify the active document via Accessibility or app adapters; Finder extension and global shortcuts |

**“Works with every app” is the direction, not a completed integration.** The snapshot engine accepts saved binary formats without needing to parse them, including PowerPoint, Excel, Photoshop, CAD, and audio/video projects. It cannot capture unsaved editor memory or guarantee a consistent project while another process writes it. A project may reference assets elsewhere; include those in the chosen project folder. No menu item is injected into other applications. Some apps, including SolidWorks, do not run natively on macOS; OpenFiles can store their saved files but does not provide those editors.

## Data and privacy

Local library and vault state lives in `~/Library/Application Support/OpenFiles/`:

- `library.json`: organization targets, file metadata, embedding vectors, and version metadata. No extracted document text is retained. This index is **not encrypted**; filenames, paths, and embeddings can reveal information.
- `Versions/<id>/`: full copies of committed files/projects. Sensitive-content checks are heuristics, not a confidentiality guarantee. Snapshots are local history, not an off-device backup.
- `CloudSync/`: pairing metadata, SHA-256 fingerprints, remote revisions, and unencrypted backups of local files replaced by sync. Backups have no automatic retention limit; see [sync behavior and limits](docs/CLOUD_STORAGE.md#pair-and-sync-folders).
- `Private.sparsebundle`: AES-256 encrypted APFS disk image, 10 GB logical capacity, allocated as needed.
- `vault-mount/`: mount point while unlocked. Vault content is accessible to the logged-in user and their processes while mounted. Passwords are not stored, logged, or passed as process arguments; there is no password recovery.

Optional cloud connections use the Google Drive API and Microsoft Graph. Their OAuth tokens and registration fields live in macOS Keychain; remote listings remain in memory, and manual downloads go to a location you choose; uploads and sync require explicit write consent and folder pairing. See [cloud data and permissions](docs/CLOUD_STORAGE.md#data-and-permissions). Disconnect removes local authorization; provider-side revocation is managed in the provider's account settings.

No telemetry or automatic model download is implemented. Browsing can visit any accessible location. Spotlight search results are not persisted. Automatic semantic indexing excludes hidden files, symbolic links, common generated directories, app data, and vault content. Semantic scans are capped at 2,000 indexed files; text extraction at 5 MB files / 12,000 characters; PDFs at 20 pages; embeddings at 4,000 characters. Native packages are treated as single projects. Sensitive detection cannot find every secret, especially in opaque binary formats.

This is an unsandboxed, locally signed developer app. macOS may ask for access to protected folders during browsing or automatic indexing. Distribution needs a stable signing identity, hardened runtime/notarization, and a decision about sandboxing and security-scoped bookmarks.

## Work together

- UI and application state: `Sources/OpenFiles/`
- Search, file rules, snapshots, filesystem boundaries, vault: `Sources/OpenFilesCore/`
- Cloud provider requests, OAuth exchange, refresh, downloads: `Sources/OpenFilesCloud/`
- Tests: `Tests/OpenFilesChecks/` and `Tests/OpenFilesCloudChecks/`
- Build/run: `scripts/` and `Makefile`
- Architecture and implementation sequence: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- Collaboration conventions: [CONTRIBUTING.md](CONTRIBUTING.md)

One teammate can own SwiftUI and workflow design while the other extends the core services. Keep the library API as the boundary, and avoid filesystem work on the main actor. CI builds and tests on macOS for pushes and pull requests.

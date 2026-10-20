# OpenFiles

A native macOS foundation for finding, organizing, and versioning your files. Built with **SwiftUI**, Foundation, NaturalLanguage, PDFKit, and CryptoKit. The interface takes its neutral palette, outlined cards, and sidebar hierarchy from shadcn/ui; it uses native controls throughout.

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

## Try it

1. Choose **Explore sample files** for disposable examples, or **Add folder** for a real folder you want indexed. No folders are scanned by default. Right-click a folder in the sidebar to remove it from the index.
2. Search by name or describe a topic, such as “travel plans for Japan.” English sentence embeddings run on-device when Apple's model is available. Filename search continues to work when it is unavailable.
3. Open **Organize → Preview organization** to review moves, then apply them. Files must be at a connected folder's top level and unchanged for 10 seconds. Files are sorted under that folder's `Organized/` directory. Automatic organization is an explicit switch and runs every minute while the app is open.
4. **Save your work in its editor**, then choose **Commit file…** or **Commit project folder…** from the OpenFiles window or its menu bar icon. Add a message. **Restore copy…** exports a verified copy to a chosen folder and refuses to overwrite an existing copy.
5. Create a password-protected **Private vault**, copy a file in, and lock it. Vault import preserves the original. Verify the encrypted copy and remove the original yourself if needed. The app attempts to lock the vault on quit; an open file can prevent unmounting.

## What this base implements

| Area | Working now | Extension work |
| --- | --- | --- |
| Search | Local English embeddings, cosine ranking, filename matching, persistent index; bounded text and PDF extraction | Chunked index, OCR, Office parsers, multilingual models, SQLite/vector index |
| Organization | Extension rules, exact move preview, collision refusal, content verification, optional one-minute automation | Rule editor, undo journal, filesystem events, model-based classification |
| Sensitive files | Filename/content heuristics exclude likely matches from embeddings, snapshots, and organization; encrypted APFS vault | Reviewed sensitive-file migration, richer detection, encrypted metadata |
| Versions | Full file/folder/package snapshots, SHA-256 verification, commit messages, non-destructive restore | Content-addressed deduplication, retention, coordinated editor saves, linked asset tracking |
| Menu bar | Commit picker available while other apps are active | Identify the active document via Accessibility or app adapters; Finder extension and global shortcuts |

**“Works with every app” is the direction, not a completed integration.** The snapshot engine accepts saved binary formats without needing to parse them, including PowerPoint, Excel, Photoshop, CAD, and audio/video projects. It cannot capture unsaved editor memory or guarantee a consistent project while another process writes it. A project may reference assets elsewhere; include those in the chosen project folder. No menu item is injected into other applications. Some apps, including SolidWorks, do not run natively on macOS; OpenFiles can store their saved files but does not provide those editors.

## Data and privacy

All application state lives in `~/Library/Application Support/OpenFiles/`:

- `library.json`: connected paths, file metadata, embedding vectors, and version metadata. No extracted document text is retained. This index is **not encrypted**; filenames, paths, and embeddings can reveal information.
- `Versions/<id>/`: full copies of committed files/projects. Sensitive-content checks are heuristics, not a confidentiality guarantee. Snapshots are local history, not an off-device backup.
- `Private.sparsebundle`: AES-256 encrypted APFS disk image, 10 GB logical capacity, allocated as needed.
- `vault-mount/`: mount point while unlocked. Vault content is accessible to the logged-in user and their processes while mounted. Passwords are not stored, logged, or passed as process arguments; there is no password recovery.

No telemetry, cloud API, or automatic model download is implemented. Files outside connected roots are not indexed. Hidden files, symbolic links, common generated directories, app data, and vault content are excluded. Scans are capped at 2,000 indexed files; text extraction at 5 MB files / 12,000 characters; PDFs at 20 pages; embeddings at 4,000 characters. Native packages are treated as single projects. Sensitive detection cannot find every secret, especially in opaque binary formats.

This is an unsandboxed, locally signed developer app. macOS may ask for access to Documents, Desktop, or Downloads after you choose them. Distribution needs a stable signing identity, hardened runtime/notarization, and a decision about sandboxing and security-scoped bookmarks.

## Work together

- UI and application state: `Sources/OpenFiles/`
- Search, file rules, snapshots, filesystem boundaries, vault: `Sources/OpenFilesCore/`
- Tests: `Tests/OpenFilesChecks/`
- Build/run: `scripts/` and `Makefile`
- Architecture and implementation sequence: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- Collaboration conventions: [CONTRIBUTING.md](CONTRIBUTING.md)

One teammate can own SwiftUI and workflow design while the other extends the core services. Keep the library API as the boundary, and avoid filesystem work on the main actor. CI builds and tests on macOS for pushes and pull requests.

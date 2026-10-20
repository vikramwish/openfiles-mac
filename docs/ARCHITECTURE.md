# Architecture

## Runtime

`OpenFilesApp` supplies the main SwiftUI window and `MenuBarExtra`. `AppModel` is main-actor isolated and presents system panels, publishes progress/results, and owns the opt-in organization timer. Its long-running operations call `FileLibrary` and `EncryptedVault`, separate actors, so filesystem and model work stays off the UI thread.

`FileBrowser` is a separate actor for direct directory listings. It accepts any accessible URL, returns folders and files independently of the index, and supports normal symlink navigation. Browsing has no 2,000-file cap. `AppModel` keeps navigation history and merges Spotlight results with semantic matches; stale directory/search callbacks are rejected using generation IDs. SwiftUI renders native file icons and embeds `QLPreviewView` for previews.

`SystemSearch` owns a main-actor `NSMetadataQuery` across `NSMetadataQueryLocalComputerScope`, or the selected folder. Observers receive gathering and update events; replacing the query stops it and removes observers. The first 1,000 Spotlight results and top 100 semantic results are merged by canonical path. Search respects Spotlight exclusions and macOS permissions. No full-filesystem recursive crawl runs on the UI thread.

`FileLibrary` persists a JSON manifest using atomic replacement. Indexing automatically enumerates the home folder, prioritizing common user folders, plus explicit organization targets, extracts bounded text/PDF content, checks sensitive heuristics, and computes Apple NaturalLanguage English sentence vectors. It caches vectors by path, size, and modification time. Search combines a filename bonus with cosine similarity. No file text is persisted. Replace the JSON index with SQLite and chunked embeddings as the library grows; add a schema version and migrations before changing the persistent models.

Organization proposals carry a source hash. Apply rechecks source boundaries, classification, and hashes, copies without overwriting, verifies the destination, then removes the source. Only top-level stable regular files in explicitly chosen organization targets are eligible. Default discovery roots never authorize moves. Project packages and flagged files stay in place. Automatic organization uses these same rules once per minute. A durable operation journal and Undo should precede broader background automation.

Versions use full copies keyed by UUID. Hash the source tree, copy it, and compare both the working tree and snapshot with the original hash. Failed or torn snapshots are removed. Restoring verifies the snapshot and exports a new uniquely named copy. This is format-independent history, not Git merge/diff semantics. Copying a live project is not a transaction across external writers; save/close in its editor first. Add NSFileCoordinator support, app save adapters, and content-addressed storage for production use.

`EncryptedVault` invokes `/usr/bin/hdiutil` with fixed arguments and a null-terminated password through stdin. The encrypted APFS sparse bundle grows to a logical maximum of 10 GB. Import copies and verifies a regular file; it intentionally retains the original. Vault contents cannot be indexed or snapshotted because app data is excluded. The UI reports the mount state, clears password input after submission, and attempts unmount before quitting. There is no recovery key or Keychain storage.

## Cloud providers

`OpenFilesCloud` is a Foundation-only module with separate models for remote items. `CloudClient` is an actor that builds provider-specific OAuth requests, exchanges and refreshes tokens, lists paginated folders, and downloads selected files. `CloudHTTPTransport` and `CloudCredentialStore` are injectable so provider behavior can be checked without credentials or access to personal accounts. The existing `LibraryState` format is unchanged; remote IDs never enter the filesystem browser as local URLs.

The macOS app owns `CloudBrowserModel`, the explicit connection workflow, and a separate cloud browser. Folder navigation and provider switching use cancellation/generation checks to reject stale results. Remote metadata remains in memory and does not participate in semantic indexing, organization, or version history. A user-selected download becomes an ordinary local file after it is saved.

`CloudAuthenticator` uses the system browser, authorization code flow with PKCE S256, random state, and an ephemeral listener bound to loopback. It validates callbacks and cleans up on completion, cancellation, or timeout. Google uses a desktop app registration and the read-only Drive scope; Microsoft uses a native public client and delegated `Files.Read` plus `offline_access`. `KeychainCloudStore` persists registration configuration and tokens independently of the local library. Only one account per provider is stored.

HTTP redirects are not followed automatically. API pagination stays within the provider's HTTPS API origin. OneDrive content redirects are followed explicitly without the Graph bearer token. Downloads stream through temporary files, refuse an existing destination, and clean up transfer artifacts. Google Workspace items and shortcuts cannot be downloaded as ordinary bytes; eligible provider links can be opened in the browser. This is read-only browsing and copy export, not synchronization or cloud backup of the local version store.

See [cloud storage setup](CLOUD_STORAGE.md) for provider registration and native integration checks. Mocked cloud checks run separately from the macOS-only filesystem, embedding, and vault checks.

## Product sequence

1. **Harden storage:** schema migrations, operation journal/Undo, quota and disk-space checks, snapshot retention, cancellation, interruption recovery, and robust coordinated reads.
2. **Improve search:** chunked PDF/text index; Office/iWork text extraction, OCR, filesystem events, incremental database updates, ranking evaluation, language support, explicit model availability status.
3. **Make organization personal:** editable rules, per-root automation, exclusions, review queues, undo, explainable classifiers. Keep uncertain matches out of unattended moves.
4. **Sensitive-file workflow:** better classifiers, reviewable vault migration, encrypted search metadata, lock lifecycle, linked-reference checks. Never claim that keyword detection protects all sensitive data.
5. **Editor integration:** a `DocumentResolver` protocol returns a URL plus provenance. Start with Finder selection and Accessibility document URLs (with explicit macOS permission), then editor-specific adapters. Provide a file/project picker when resolution fails. A menu bar app cannot obtain every editor's unsaved document or inject commands into every editor.
6. **Team-ready distribution:** signed/notarized releases, stable identity, update channel, privacy choices, sandbox/bookmarks decision. File history is currently per-machine; collaboration and sync require a separate conflict model.

## Known limits

- No automatic active-document capture, unsaved memory capture, universal save hook, cross-file transaction, or linked external asset discovery.
- No filesystem-event watcher; manual refresh and the optional one-minute organization pass drive reindexing.
- Local snapshots and index metadata are unencrypted. Vault import leaves originals in place.
- Sensitive matching is deliberately conservative and incomplete. Opaque binary formats are indexed by name; content inspection is limited to supported text and PDF formats.
- Paths/filenames are plaintext metadata even for flagged files. Automatic semantic discovery includes the home folder; per-folder semantic exclusions and encrypted metadata remain future work.
- The semantic index caps a scan at 2,000 files; browser listings and Spotlight search scope are independent of this cap. Large project snapshots are full copies and can consume substantial disk space.
- Filesystem validation reduces accidental path escapes but is not a defense against a malicious concurrent filesystem writer. The unsandboxed development app runs as the current user.

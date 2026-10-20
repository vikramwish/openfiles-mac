# Architecture

## Runtime

Workspace windows are owned by `SearchPanelController` and identified independently. New Window (⌘N) creates a separate `AppModel` for navigation, selection, search, sheets, and commit drafts. These models share the service owner’s `FileLibrary` and `EncryptedVault`, mirror published library/index/vault state, and forward indexing controls to the one service owner. Version-operation locking is shared across windows. The active window supplies command routing; closing a window tears down its searches and subscriptions while the service owner continues running.

`OpenFilesApp` supplies the main SwiftUI window and `MenuBarExtra`. `AppModel` is main-actor isolated and presents system panels, publishes progress/results, and owns the opt-in organization timer. Its long-running operations call `FileLibrary` and `EncryptedVault`, separate actors, so filesystem and model work stays off the UI thread.

`FileBrowser` is a separate actor for direct directory listings. It accepts any accessible URL, returns folders and files independently of the index, and supports normal symlink navigation. Browsing has no 2,000-file cap. `AppModel` keeps navigation history and merges Spotlight results with semantic matches; stale directory/search callbacks are rejected using generation IDs. SwiftUI renders native file icons and embeds `QLPreviewView` for previews.

`SystemSearch` owns a main-actor `NSMetadataQuery` across `NSMetadataQueryLocalComputerScope`, or the selected folder. Observers receive gathering and update events; replacing the query stops it and removes observers. The first 1,000 Spotlight results and top 100 semantic results are merged by canonical path. Search respects Spotlight exclusions and macOS permissions. No full-filesystem recursive crawl runs on the UI thread.

`FileLibrary` persists a JSON manifest using atomic replacement. Indexing automatically enumerates the home folder, prioritizing common user folders, plus explicit organization targets, extracts bounded text/PDF content, checks sensitive heuristics, and computes Apple NaturalLanguage English sentence vectors. It caches vectors by path, size, and modification time. Search combines a filename bonus with cosine similarity. No file text is persisted. Replace the JSON index with SQLite and chunked embeddings as the library grows; add a schema version and migrations before changing the persistent models.

Organization proposals carry a source hash. Apply rechecks source boundaries, classification, and hashes, copies without overwriting, verifies the destination, then removes the source. Only top-level stable regular files in explicitly chosen organization targets are eligible. Default discovery roots never authorize moves. Project packages and flagged files stay in place. Automatic organization uses these same rules once per minute. A durable operation journal and Undo should precede broader background automation.

Versions use full copies keyed by UUID and retain the existing manifest format. `Versioning.swift` builds digest-bound reviews against the most recent snapshot or the predecessor of a historical commit. Small UTF-8 text files expose contiguous line edits; folders expose added/modified/deleted files; opaque formats expose a complete document. Selective commits build a staged snapshot in private `VersionWork` storage and leave the working file untouched. Full selections copy the target exactly, preserving package structure. Every snapshot is verified before its metadata is persisted.

Cherry-pick maps selected text edits to a unique matching context in the current file; file-level picks require the affected file to match its baseline. Ambiguous matches, conflicts, changed working digests, changed baselines, and corrupt snapshots fail before installation. Restore and cherry-pick stage a verified sibling, coordinate replacement with `NSFileCoordinator`, preserve current saved content in history when needed, recheck its digest, and atomically replace the original path. They record the applied result as a new version. Existing recovery snapshots provide undo; explicit export retains collision refusal. Temp staging is removed after operations. This remains saved-file versioning: it cannot capture unsaved editor memory or force another app to reload cached documents. External writers that ignore coordination are not a cross-process transaction.

The shared `VersionHistoryView` contains change selection, the commit-message composer, progress/errors, and history actions. No commit sheet or destination dialog is involved. Menu bar actions route to the composer. An initial file picker is only needed when there is no selected or tracked file. Messages clear only after successful operations; polling does not erase operation errors or silently select edits added to an active review.

`EncryptedVault` invokes `/usr/bin/hdiutil` with fixed arguments and a null-terminated password through stdin. The encrypted APFS sparse bundle grows to a logical maximum of 10 GB. Import copies and verifies a regular file; it intentionally retains the original. Vault contents cannot be indexed or snapshotted because app data is excluded. The UI reports the mount state, clears password input after submission, and attempts unmount before quitting. There is no recovery key or Keychain storage.

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

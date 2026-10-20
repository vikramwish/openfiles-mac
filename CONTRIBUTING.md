# Contributing

Use macOS 14+ and Swift 5.9+. Clone, then run `make test` and `make run`. There are no secrets or dependencies to configure.

Create a short-lived branch (`codex/<topic>` for agent changes, or your team's chosen prefix), make a focused change, and open a PR to `main`. Include the resulting behavior, any data migration, and how it was verified. CI runs core tests and builds the app on macOS.

## Boundaries

- `OpenFilesCore` owns filesystem access, persistence, embeddings, moves, snapshots, and encrypted storage. Keep slow work off the main actor.
- `OpenFiles` owns user consent, native file pickers, progress, navigation, and error presentation. Pass selected URLs to the core; do not embed destructive operations in view code.
- Add meaningful tests when changing moves, restores, snapshots, or exclusion rules. Use temporary fixtures. Never scan a developer's home folder in tests.
- Do not commit personal files, model caches, disk images, app bundles, API keys, or generated build output.
- Preserve collision refusal and content verification. Never delete an original until its replacement is verified. Keep restore non-destructive.
- Treat sensitive detection as a hint. Do not label a normal folder secure. New cloud providers require explicit opt-in and clear disclosure of transmitted data.

## Manual smoke test

Start with the sample library. Search for a filename and a topic, reveal/open a result, preview and apply organization, commit a file, modify it, and restore to a new copy. Test a project package, destination collision, and changed source. Create a temporary vault, import a disposable file, lock, reject a wrong password, unlock, and verify the file. Never use irreplaceable files for early feature testing.

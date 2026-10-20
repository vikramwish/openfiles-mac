# Content-aware organization across your Mac

Organization and cleanup start from **This Mac**, without requiring a folder picker. Default discovery covers accessible `/Users` folders and writable local volumes mounted under `/Volumes`, plus explicitly included locations. macOS permissions, index exclusions, protected locations, source projects, packages and sensitive-file checks still apply. This is accessible user-data coverage, not access to every protected system file. Mounted volumes refresh the discovery scope and watcher. Optional scope controls can narrow cleanup to one folder.

## Dynamic folder names

The active organizer no longer routes files through a preset topic taxonomy. `OrganizationContext.dynamicSuggestions` uses existing user-created folder names, shared filename words, recurring indexed content terms, image subject labels and recorded places. A pair such as `Orion spectrometer budget` and `Orion spectrometer calibration` can propose `Orion Spectrometer`; matching scattered files can reuse a corpus-backed `Clients/Juniper Labs` name. Images can propose actual place/subject names such as `Kyoto/Building`. These are bounded evidence-derived labels, not unrestricted generative reasoning. They may need editing. The old standalone topic/context helpers remain for compatibility and are not used by the active planner.

Folder anchors require at least two shared meaningful terms and a clear lead over alternatives; ambiguous anchors remain unchanged. Generic staging folders, filler and numeric camera names do not establish a project. Features are bounded to 96 indexed content terms per file, up to 16 informative anchor terms with at most 128 folder matches each and 48 ranked lexical anchor candidates, 10,000 eligible files and 5,000 already-organized references per naming pass. Already-organized files can inform future folder names without being moved again. Coverage and deferred-file counts are shown. Optional embeddings are not required, and no cloud request or file content read is needed for naming itself. Source verification still reads bytes before proposing physical moves.

Suggested destinations stay inside `~/Organized/<derived folders>/<filename>` as a reviewed safety boundary. Folder names are sanitized single components. Existing filename collisions receive numbered suffixes. **Edit folder…** changes the relative path for every file in that proposed folder, supports up to six components, rechecks collisions and issues a new plan ID. It only revises the in-memory proposal: no directory is created and no original moves until the user applies selected suggestions. Hidden, sensitive and traversal names are refused.

## Applying a review

No files are selected initially. The user selects individual suggestions or Select All, then explicitly chooses Move Selected Files. The in-memory plan ID and selected file IDs are required; an expired/consumed plan cannot be replayed. Planning, browsing, indexing, search, and smart groups never apply a plan automatically.

Before each move, the library checks current scope and exclusions, source stamp/hash and sensitive content, then validates every level of the nested destination against symbolic links and refuses paths outside the reviewed Organized folder. It copies without overwriting, verifies source stability and destination bytes, and removes the source only after verification. Changed/colliding/unreadable files produce errors while other selections can complete. Successful paths are reconciled into the index. Moving files changes their paths and can affect external links; recognized project folders are skipped to reduce that risk.

No automatic migration into the password vault occurs. Potentially sensitive files remain in place. There is not yet a durable organization Undo journal, user-trained taxonomy, or open-document detection; these are necessary follow-ups before enabling unattended physical organization.

## Validation

Temporary-fixture checks cover recursive cross-folder suggestions without connected roots, analysis leaving originals unchanged, dynamic folder names and edited reviews, duplicate names, sensitive/project/unsupported exclusions, selected-only application, stale previews, consumed-plan rejection, destination symlinks, and ambiguous/incompatible vectors. Existing tests continue to verify that default discovery cannot invoke the legacy move API.

## File browser preview

Browse files includes an inline Quick Look preview that follows the selected file. Use Preview in the browser header to hide or show it. Wide layouts place it beside the list; narrower layouts place it below. Folders have a separate selection state, and no selection shows an explanation. Space and the Quick Look context action remain available for larger previews.

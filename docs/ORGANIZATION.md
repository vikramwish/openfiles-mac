# Content-aware organization across your Mac

The Organize screen starts with indexed personal files throughout the home folder, including nested Documents, Desktop, Downloads, Pictures, Music, and Movies folders. Additional locations can be added, including accessible external drives. macOS permissions and index exclusions still apply. System/app data, recognized project trees and packages, hidden files, and sensitive-classified files are excluded.

## Suggestions

Analyze My Files is read-only with respect to original files. It uses the existing index, so it does not need to embed each file again. Eight local topic descriptions are embedded using the same backend as the file vectors: Work, Study, Travel, Home, Creative, Purchases, Events, and Cooking. Files can cross format boundaries within a topic.

A suggestion requires a content-derived vector from the current backend, cosine similarity of at least 0.45, and a lead of at least 0.06 over the next topic. These are heuristic thresholds, not probabilities. Filename-only or old-model embeddings and ambiguous matches stay in place. Unsupported content needs richer extraction before it can participate. Extracted content is bounded by the indexer; the organizer does not claim to understand an entire long document.

Destinations are `~/Organized/<topic>/<filename>`. Existing filenames and duplicate proposals receive numbered suffixes. The screen shows both paths, similarity, margin, extraction evidence, and skip counts. It reviews at most 200 suggestions at a time and reports additional candidate matches. After applying a batch, analyze again for the remainder. Files already in the destination tree are excluded.

## Applying a review

No files are selected initially. The user selects individual suggestions or Select All, then explicitly chooses Move Selected Files. The in-memory plan ID and selected file IDs are required; an expired/consumed plan cannot be replayed. Planning, browsing, indexing, search, and smart groups never apply a plan automatically.

Before each move, the library checks current scope and exclusions, source stamp/hash and sensitive content, then validates each destination directory against symbolic links. It copies without overwriting, verifies source stability and destination bytes, and removes the source only after verification. Changed/colliding/unreadable files produce errors while other selections can complete. Successful paths are reconciled into the index. Moving files changes their paths and can affect external links; recognized project folders are skipped to reduce that risk.

No automatic migration into the password vault occurs. Potentially sensitive files remain in place. There is not yet a durable organization Undo journal, user-trained taxonomy, or open-document detection; these are necessary follow-ups before enabling unattended physical organization.

## Validation

Temporary-fixture checks cover recursive cross-folder suggestions without connected roots, analysis leaving originals unchanged, topic assignment, duplicate names, sensitive/project/unsupported exclusions, selected-only application, stale previews, consumed-plan rejection, destination symlinks, and ambiguous/incompatible vectors. Existing tests continue to verify that default discovery cannot invoke the legacy move API.

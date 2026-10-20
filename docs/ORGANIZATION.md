# Content-aware organization across your Mac

The Organize screen starts with indexed personal files throughout the home folder, including nested Documents, Desktop, Downloads, Pictures, Music, and Movies folders. Additional locations can be added, including accessible external drives. macOS permissions and index exclusions still apply. System/app data, recognized project trees and packages, hidden files, and sensitive-classified files are excluded.

## Suggestions

Analysis reads existing index metadata and leaves originals in place. A context planner combines filename terms, the existing folder hierarchy, indexed document/OCR terms, on-device image subject labels, and embedded image location metadata. Filename and folder signals have more weight than incidental document terms. Specific course, client, trip, and event names are preserved when their parent folder explicitly identifies their role. Generic folder names are not treated as course or client names.

Examples include `Study/Courses/COMP1511/Lectures`, `Work/Clients/Acme/Proposals`, `Travel/Trips/Japan 2025/Itineraries`, `Photos/Trips/Japan/Beaches`, and `Photos/Wildlife/Zebras`. Photographed receipts can be grouped with receipts using OCR. Image scene labels require confidence of at least 0.45; uncertain images remain in place. Embedded place names are used directly; GPS-only matches use the bounded offline city lookup and are described as approximate. The organizer does not infer an exact location from the appearance of a scene or treat a file’s modification date as the date a photo was taken.

The eight broad embedding topics remain a fallback for readable documents: Work, Study, Travel, Home, Creative, Purchases, Events, and Cooking. Semantic fallback still requires similarity of at least 0.45 and a margin of at least 0.06. Grounded context suggestions also work without an embedding backend. Unsupported files without indexed content stay in place; extracted content remains bounded by the indexer.

Destinations are `~/Organized/<context folders>/<filename>`, with readable, sanitized single folder components. Suggestions show the source and full relative destination hierarchy alongside the evidence, similarity, margin, extraction details, and skip counts; Preview file opens the selected original for review. Existing filenames and duplicate proposals receive numbered suffixes. The planner reviews at most 200 suggestions at a time and reports additional candidate matches. After applying a batch, analyze again for the remainder. Files already in the destination tree are excluded.

## Applying a review

No files are selected initially. The user selects individual suggestions or Select All, then explicitly chooses Move Selected Files. The in-memory plan ID and selected file IDs are required; an expired/consumed plan cannot be replayed. Planning, browsing, indexing, search, and smart groups never apply a plan automatically.

Before each move, the library checks current scope and exclusions, source stamp/hash and sensitive content, then validates every level of the nested destination against symbolic links and refuses paths outside the reviewed Organized folder. It copies without overwriting, verifies source stability and destination bytes, and removes the source only after verification. Changed/colliding/unreadable files produce errors while other selections can complete. Successful paths are reconciled into the index. Moving files changes their paths and can affect external links; recognized project folders are skipped to reduce that risk.

No automatic migration into the password vault occurs. Potentially sensitive files remain in place. There is not yet a durable organization Undo journal, user-trained taxonomy, or open-document detection; these are necessary follow-ups before enabling unattended physical organization.

## Validation

Temporary-fixture checks cover recursive cross-folder suggestions without connected roots, analysis leaving originals unchanged, topic assignment, duplicate names, sensitive/project/unsupported exclusions, selected-only application, stale previews, consumed-plan rejection, destination symlinks, and ambiguous/incompatible vectors. Existing tests continue to verify that default discovery cannot invoke the legacy move API.

## File browser preview

Browse files includes an inline Quick Look preview that follows the selected file. Use Preview in the browser header to hide or show it. Wide layouts place it beside the list; narrower layouts place it below. Folders have a separate selection state, and no selection shows an explanation. Space and the Quick Look context action remain available for larger previews.

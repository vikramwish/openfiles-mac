# Google Drive and OneDrive

OpenFiles can connect directly to Google Drive and Microsoft OneDrive. Their Mac sync apps are not required. The cloud browser lists folders and files in the connected account and downloads a selected file to a location you choose. Connections start read-only. Enable **uploads and two-way sync** in App registration and reconnect to grant write access. One account and one sync pairing per provider are supported. Shared-drive browsing, remote semantic search, and automatic deletion propagation are not implemented.

Google Docs, Sheets, Slides, and other Google Workspace formats open in the provider's website; OpenFiles does not export them to another format. Ordinary uploaded files can be downloaded. Ordinary **Save copy** downloads are independent local files. Files inside an explicitly paired sync folder participate in the sync workflow described below.

## Register the applications

These are native desktop OAuth clients. Each developer or distributor supplies their own registration. Do not commit downloaded credential files, tokens, or client secrets to Git. Enter the registration fields in OpenFiles on your Mac; the app stores them in macOS Keychain.

### Google Drive

1. In [Google Cloud Console](https://console.cloud.google.com/), select or create a project and enable the **Google Drive API**.
2. Configure **Google Auth Platform** / the OAuth consent screen. For a personal development registration in testing mode, add the Google accounts you will use as test users. An internal registration is limited to the associated organization.
3. Create an OAuth client of type **Desktop app**. Use its client ID in OpenFiles. If the desktop credentials include a client secret, enter that in the Google desktop client secret field. This is not a web application registration; do not configure a backend or use a web client secret.
4. Read-only connections request `https://www.googleapis.com/auth/drive.readonly`; enabling uploads and sync requests `https://www.googleapis.com/auth/drive`. Include the selected scope in the consent configuration. The write scope permits modifying existing Drive files across the account; the narrower `drive.file` scope cannot support arbitrary existing-folder sync. These scopes are classified as restricted by Google; public distribution may require Google's verification and applicable security review.
5. Choose **Connect** in OpenFiles and complete Google's sign-in and consent in the system browser.

The app uses an ephemeral loopback redirect, `http://127.0.0.1:<port>/callback`, with authorization code flow and PKCE. The local listener runs only during sign-in. Desktop app registrations support the loopback flow without a fixed callback port. Testing-mode grants can expire according to Google's policy; reconnect when prompted.

See Google's [OAuth for desktop applications](https://developers.google.com/identity/protocols/oauth2/native-app) and [Drive API scopes](https://developers.google.com/workspace/drive/api/guides/api-specific-auth).

### Microsoft OneDrive

1. In the [Microsoft Entra admin center](https://entra.microsoft.com/), create an **App registration**.
2. For the app's common sign-in authority, select supported account types that include **accounts in any organizational directory and personal Microsoft accounts**. Organization policy may still restrict consent or OneDrive access.
3. Under **Authentication**, add the **Mobile and desktop applications** platform and register `http://localhost/callback` as a redirect URI. Use a native/public client configuration, not a web application. Microsoft's loopback redirect handling ignores the ephemeral port; the callback path must match.
4. Add Microsoft Graph **delegated** permission `Files.Read` for browsing, or `Files.ReadWrite` when enabling uploads and sync. The sign-in request also asks for `offline_access` so the app can refresh an expired access token. Application permissions and a client secret are not needed.
5. Copy the **Application (client) ID** into OpenFiles, then choose **Connect** and complete Microsoft's sign-in and consent in the system browser.

The app uses `https://login.microsoftonline.com/common/oauth2/v2.0/authorize`, authorization code flow with PKCE, and `http://localhost:<port>/callback`. An organizational administrator may need to allow the app or grant consent. The signed-in account must have a provisioned OneDrive.

See Microsoft's [desktop application registration](https://learn.microsoft.com/en-us/entra/identity-platform/scenario-desktop-app-registration), [redirect URI restrictions](https://learn.microsoft.com/en-us/entra/identity-platform/reply-url), and [delegated permissions](https://learn.microsoft.com/en-us/graph/permissions-reference#filesread).

## Connect and browse

Open **Cloud storage**, choose a provider, and enter its registration fields. **Connect** saves the registration and opens the provider's sign-in page. **Save and reconnect** replaces the provider's existing local authorization before starting a new sign-in. You can cancel sign-in; a cancelled or timed-out attempt must be started again.

Browse folders, return through the folder navigation, refresh a listing, or load another page of results. Choose a downloadable file and a local destination. OpenFiles refuses to replace an existing file; choose a different name or destination. Network and provider errors are displayed so you can retry. Remote browsing, uploads, and sync require an Internet connection. Existing connections do not silently gain write permission when the app is updated: enable the write option and reconnect first.

Successful sign-in immediately loads the account root. Provider shortcuts in the sidebar return to the cloud browser; rows carry a provider tag and the current folder path. **Connection settings** reveals registration and disconnect controls after sign-in. **Uploads and folder sync** expands the optional transfer controls. The local browser also labels recognized iCloud, Google Drive, and OneDrive folders on this Mac; these labels describe their paths, not proof of completed synchronization or offline availability.

Storage indicators show the Mac's current volume and the connected account's quota. Google uses Drive `about.storageQuota` (account usage can include Gmail and Photos); OneDrive uses Graph `me/drive.quota`. These metadata calls use existing read permissions and do not download files. Refresh updates the listing and account quota independently, so unavailable quota data does not hide files. A missing or unlimited provider limit is shown as unavailable, never zero capacity. Local capacity refreshes every minute while visible and can differ from macOS's reclaimable-space estimate.

The storage bar stays visible throughout the main window, including Home, with used/available/total values where reported. Home restores the selected provider's saved connection and shows up to eight items from the current folder, with files before folders. **View all** opens the full cloud browser for paging and transfers. Use **Search cloud…** for a separate account search.

### Search cloud files

Choose **Search cloud…** on Home or in Cloud storage, enter 1–200 characters, and press Search or Return. Google Drive uses its `name contains` query, with Google's filename matching rules. OneDrive uses `root/search`, which can match names, metadata, and indexed contents. Searches cover the selected account rather than the browsed folder; results depend on the provider's index and access permissions. This does not add remote documents to the local semantic index.

Search sends the submitted text to the selected provider using the existing read scope. Results contain metadata only; content downloads happen only through Preview or Save copy. Queries and results are not saved as search history. Native Google Workspace documents open on the provider's website.

Filter loaded results by file type and sort by provider order, name, newest, or largest. Types use MIME metadata and filename extensions where available. Unknown dates/sizes sort last. Each request asks for up to 100 results; **Load more** explicitly fetches the next page, including after an empty filtered page. Counts and sorting describe loaded results, not the total account. Results show a provider tag without inventing a parent-folder path.

Starting a new search cancels the previous request. Stop and closing the search cancel pending work; changing accounts/providers closes the search and rejects late responses. Continuations are tied to the original query/client session. OneDrive next-page links must remain on the same HTTPS Graph search endpoint. Opening a result does not change the browsed folder or upload destination.

### File previews

Select a supported file in the cloud browser or choose **Preview** on Home to download a private temporary copy for Quick Look. PDF, common image, text, and Office formats are supported. Metadata must report a size no greater than 25 MiB; the downloaded size and remote metadata are checked again before display. Unknown sizes, changed versions, unsupported formats, and larger files show an explanation with **Save copy…** or a provider link.

Preview files are read-only, outside the local index and paired folders. Closing or replacing a preview, changing folders/accounts, or quitting cleans up its temporary copy. A process crash can leave temporary data for manual cleanup. **Save copy…** remains a separate permanent download to a location you choose. Google Workspace documents open on the provider's website.

**Disconnect** removes the locally stored authorization and retains your registration fields in Keychain. It does not delete your cloud files or revoke the app's grant at the provider. To revoke provider-side access, use your [Google third-party connections](https://myaccount.google.com/connections) or Microsoft's account/application permission controls. To use a different account for a provider, disconnect and sign in again.

## Upload files

After enabling write access and reconnecting, **Upload files…** sends selected regular files to the currently displayed cloud folder. Existing names are refused; choose another filename to upload a separate version. Google Drive can contain duplicate names, so a concurrent creation by another client may leave duplicate entries; sync reports that ambiguity instead of choosing one.

New nonempty files upload in 5 MiB chunks. Temporary upload URLs and session identifiers remain in memory. The app does not persist a transfer queue or resume interrupted sessions across launches. Cancel or network failure can occur after the provider has committed a file; refresh the folder before retrying. Empty files use the providers' single-request upload paths.

### Home suggestions

**Suggested for cloud storage** ranks indexed local files by size. Candidates are at least 25 MiB, or at least 1 MiB with a modification date over 90 days ago. Project records, sensitive flags/names, and recognized `Library/CloudStorage` or `Library/Mobile Documents` paths are excluded. These are metadata heuristics, not a claim about how often a file is used or whether another cloud copy already exists.

Choose the destination folder in Cloud documents, then **Review upload…**. The review displays the source, indexed size, destination, and disclosure that the current filename and contents will be transmitted. Account or folder changes invalidate an open review. Read-only connections must explicitly enable uploads and reconnect first. Confirming uploads a copy and reports the result; local originals are retained and no disk space is freed automatically. Verify the cloud copy before separately removing any original.

## Pair and sync folders

1. Browse to the cloud folder you want to synchronize, then choose **Pair local folder…** and select its local counterpart. Pairings cannot overlap locally or include OpenFiles application data or the private vault. Pairing alone transfers nothing.
2. Choose **Preview sync**. The preview includes files in subfolders and shows uploads, downloads, folder creation, content comparisons, and conflicts.
3. Choose **Apply sync** to execute the preview. File contents and remote revisions are checked again before changes are made. Save or close files in their editors before syncing; OpenFiles cannot capture unsaved editor memory or make a multi-file project transaction.
4. Optionally enable **Sync this pairing every minute while OpenFiles is open**. It applies subsequent passes without another preview, pauses on conflicts/errors, and stops when switching providers or disconnecting. It starts off after every app launch. Disable the toggle to stop future passes; **Cancel sync** stops the pending pass as well. There is no system daemon when OpenFiles is closed.

The pairing is pinned to the connected account and remote folder ID. Reconnecting another account does not reuse the pairing. Browsing another cloud folder does not change the existing pairing; its local and remote paths remain shown in the sync controls. Removing a pairing preserves local files, cloud files, and backups. Removing and recreating it resets the baseline and treats same-name files as an initial comparison again.

Sync behavior:

| Situation | Result |
| --- | --- |
| New file exists only locally | Upload to the matching remote folder. |
| New file exists only remotely | Download into the matching local folder. |
| Only the local copy changed since the last successful sync | Update the remote file with an `If-Match` precondition. |
| Only the remote copy changed | Download, recheck the local fingerprint, retain a verified backup, then replace the local content. |
| Both copies changed, or same-name files have no baseline | Compare contents; accept only identical bytes, otherwise report a conflict and retain both copies. |
| A previously synced file/folder is missing on one side | Report it for manual resolution; do not delete or automatically restore the missing copy. |
| A file moves, a remote ID changes, or names collide by case | Report the ambiguity instead of choosing a copy. |

For competing files present on both sides, choose **Compare copies…** in the sync preview. The comparison shows sizes, dates, and text changes or side-by-side previews. Both files must have known sizes of at most 25 MiB. Text differences support UTF-8 without NUL bytes, up to 1 MiB and 2,000 lines per file; other contents use Quick Look previews. **Keep local copy** backs up the compared cloud bytes before a conditional upload. **Keep cloud copy** backs up the local file before replacement. Both choices revalidate the account, pairing, paths, revisions, and captured bytes; stale comparisons require a new preview. Canceling changes neither original and removes temporary comparison copies. Automatic sync pauses while reviewing a conflict and does not resume implicitly.

Files outside these limits require manual comparison. For a deletion, restore the missing copy yourself or remove the counterpart yourself. Sync never deletes cloud files. Files removed from both sides remain absent. Native Google Workspace documents, shortcuts, and other nondownloadable cloud items are reported as unsupported for content sync.

Hidden files/folders and symbolic links are excluded. Pairings are limited to 10,000 entries and 64 folder levels; exceeding these limits stops the scan rather than applying a partial inventory. Sync tracks file bytes and names, not complete filesystem metadata or permissions across providers. It does not infer renames as moves. Initial content comparisons can download files even when no replacement is needed.

Updates to existing remote files use a streamed conditional content request, not an upload session whose revision check could apply only at session creation. If the provider does not return a usable ETag, OpenFiles reports a conflict and refuses the replacement. OneDrive's conditional content updates are limited to 250 MB; larger new files can use chunked upload, but larger changed files must be uploaded under a new name. Transfers are rechecked on subsequent sync passes after interruptions; they are not a distributed transaction across the two filesystems.

Sync state is stored in `~/Library/Application Support/OpenFiles/CloudSync/`:

- `<pair-id>.json`: paired paths, provider account identifier, SHA-256 file fingerprints, remote IDs/revisions, and a schema/revision number. This is plaintext metadata and contains no OAuth tokens.
- `Backups/<pair-id>/<operation-id>/`: verified copies of local files replaced by downloaded versions, and cloud copies replaced through explicit conflict resolution. These backups are **not encrypted** and have no automatic retention limit. **Show local backups** opens this folder. Review and remove old backups yourself when appropriate.
- `Temporary/`: scratch copies during content comparison and upload. Completed and failed operations clean their own scratch folders; a process crash can leave scratch files for manual cleanup.

If another process changes a file during final replacement, the error may identify a retained `.openfiles-previous-…` sibling for manual recovery. Such hidden recovery files are excluded from subsequent sync.

Workspace windows share one cloud session, including the selected provider, folder, connection, transfers, and sync pairing. Closing one cloud view does not cancel work displayed in another. Automatic sync can continue with all workspace windows closed while OpenFiles remains in the menu bar. Quitting cancels transfers and waits for their cleanup and sync checkpoints.

## Data and permissions

- Connecting sends OAuth requests to the selected provider. Listing a folder fetches filenames, identifiers, sizes, modification dates, revisions, and provider links. Downloading retrieves file contents. Uploads transmit selected filenames and file contents; an enabled pairing authorizes these transfers recursively within the paired folder.
- Explicit cloud searches send the submitted search text to that provider. Search result filtering and sorting run locally on returned metadata.
- The Google Drive API and Microsoft Graph receive bearer tokens only at their configured HTTPS API endpoints. OneDrive content can be served from a temporary download URL or sent to a provider-issued upload URL; the Graph bearer token is never forwarded to those hosts. Upload session destinations are restricted to the provider's supported HTTPS hosts.
- OAuth tokens and registration configuration are stored in macOS Keychain. They are not written into `library.json`, source files, or log output. A locked or inaccessible Keychain can prevent connection until it is available.
- Cloud listings remain separate from the local library. Browsing alone does not index, organize, snapshot, or download remote files. Explicitly paired folders can transfer contents automatically when you enable that option. Files downloaded into your home folder can enter the existing local indexing workflow.
- Downloads use temporary files while transferring, then save to your chosen destination. Disconnecting does not remove copies you have already downloaded. Keep sensitive downloads in a location appropriate for their contents.

## Development checks

The provider checks use temporary fixtures, fake tokens, an in-memory credential store, and a mocked HTTP transport. They do not connect to personal accounts:

```sh
swift run --build-system native OpenFilesCloudChecks
```

These checks exercise request construction, response handling, token refresh, pagination, download/upload boundaries, write-permission migration, recursive sync, persisted baselines, account isolation, stale previews, conflicts, local backups, and interrupted operations. They do not establish that a real registration is configured correctly or that macOS Keychain/browser callbacks work. The application, native OAuth listener, and Keychain integration need macOS 14+ for validation.

Before shipping, use disposable files and test accounts to check both providers:

1. Build and run the app. Confirm the local browser still works before connecting a provider.
2. Connect, consent, browse nested folders, load additional pages, and refresh. Cancel a new sign-in, confirm the browser remains disconnected, and reconnect successfully.
3. Download a binary file and compare it with the original. Confirm an existing destination is refused and a failed/cancelled transfer does not publish a partial copy.
4. Open a Google Workspace item in the provider's website. Confirm it is not offered as an ordinary binary download.
5. Restart the app, unlock Keychain if requested, and confirm the connection can be restored. Exercise access-token refresh and a revoked grant, which should require reconnecting.
6. Disconnect while a listing or download is pending and confirm late results do not repopulate the disconnected browser. Switch providers and confirm folder state does not leak between them.
7. Enable uploads/sync and reconnect; confirm the provider requests the expanded scope. Upload a small binary file, an empty file, and a file larger than one chunk. Check the contents in the provider and confirm duplicate names are refused.
8. Pair disposable folders containing nested files. Preview/apply, then separately edit each side and verify transfers and local backup contents. Edit both copies and confirm conflict reporting preserves both.
9. Remove a previously synced file from one side and confirm sync reports it without deleting or restoring its counterpart. Cancel a transfer, preview again, and verify it can converge without data loss.
10. Enable automatic sync and verify a subsequent pass; introduce a conflict and confirm automatic sync pauses. Restart the app and confirm the pairing survives while automatic sync starts off.
11. Reconnect a different account and confirm the old pairing refuses to transfer files. Confirm no remote files enter local indexing/history/organization merely by browsing.

12. Open Cloud storage in two workspace windows. Confirm provider changes and transfer status agree, an active transfer cannot be started twice, and closing one window leaves the other’s transfer running. Enable automatic sync, close both windows, reopen a workspace, and confirm the same session is retained. Quit during a transfer and verify the next launch can reconcile the disposable pairing.
13. On Home, browse cloud documents, preview a PDF/image/text file, close it, and confirm its temporary copy is removed. Test an unknown-size file, a file over 25 MiB, and a file changed while its preview downloads. Confirm local and cloud storage remain visible in the main window.
14. Compare a disposable sync conflict, try each choice, and verify the replaced copy in backups. Change a file after comparison and confirm resolution refuses stale content. Cancel a binary comparison and verify both originals remain.
15. Index disposable large/older files. Review a Home upload, confirm the displayed destination and retained local original, then repeat while switching the destination in another workspace. Confirm the stale review cannot upload.
16. Select several local text files and review batch filenames. Apply a prefix/date pattern to selected rows, leave others unchecked, and verify contents and extensions after renaming. Test duplicate target names and a source edited after analysis; neither should start a partially validated batch.
17. From Home, search for a disposable cloud file outside the current folder. Try punctuation and non-ASCII text, filter by document/image, sort by size/date, and load another page. Preview/save a result and confirm its location tag identifies the provider without displaying the currently browsed folder as its parent. Switch accounts in another window while a search is pending and confirm old results cannot appear.

The app remains a locally signed developer build. Distribution needs a stable signing identity, appropriate provider registration/verification, and testing of Keychain access across updates.

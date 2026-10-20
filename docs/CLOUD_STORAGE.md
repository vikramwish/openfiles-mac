# Google Drive and OneDrive

OpenFiles can connect directly to Google Drive and Microsoft OneDrive. Their Mac sync apps are not required. The cloud browser lists folders and files in the connected account and downloads a selected file to a location you choose. Access is read-only: uploading, moving, deleting, two-way sync, shared-drive browsing, and remote semantic search are not implemented. One account per provider can be connected at a time.

Google Docs, Sheets, Slides, and other Google Workspace formats open in the provider's website; OpenFiles does not export them to another format. Ordinary uploaded files can be downloaded. Downloads are independent local copies: editing one does not update the cloud original.

## Register the applications

These are native desktop OAuth clients. Each developer or distributor supplies their own registration. Do not commit downloaded credential files, tokens, or client secrets to Git. Enter the registration fields in OpenFiles on your Mac; the app stores them in macOS Keychain.

### Google Drive

1. In [Google Cloud Console](https://console.cloud.google.com/), select or create a project and enable the **Google Drive API**.
2. Configure **Google Auth Platform** / the OAuth consent screen. For a personal development registration in testing mode, add the Google accounts you will use as test users. An internal registration is limited to the associated organization.
3. Create an OAuth client of type **Desktop app**. Use its client ID in OpenFiles. If the desktop credentials include a client secret, enter that in the Google desktop client secret field. This is not a web application registration; do not configure a backend or use a web client secret.
4. OpenFiles requests `https://www.googleapis.com/auth/drive.readonly`. Include this scope in the consent configuration when required. This scope permits reading existing Drive files and is classified as restricted by Google; a public distribution may require Google's verification and applicable security review.
5. Choose **Connect** in OpenFiles and complete Google's sign-in and consent in the system browser.

The app uses an ephemeral loopback redirect, `http://127.0.0.1:<port>/callback`, with authorization code flow and PKCE. The local listener runs only during sign-in. Desktop app registrations support the loopback flow without a fixed callback port. Testing-mode grants can expire according to Google's policy; reconnect when prompted.

See Google's [OAuth for desktop applications](https://developers.google.com/identity/protocols/oauth2/native-app) and [Drive API scopes](https://developers.google.com/workspace/drive/api/guides/api-specific-auth).

### Microsoft OneDrive

1. In the [Microsoft Entra admin center](https://entra.microsoft.com/), create an **App registration**.
2. For the app's common sign-in authority, select supported account types that include **accounts in any organizational directory and personal Microsoft accounts**. Organization policy may still restrict consent or OneDrive access.
3. Under **Authentication**, add the **Mobile and desktop applications** platform and register `http://localhost/callback` as a redirect URI. Use a native/public client configuration, not a web application. Microsoft's loopback redirect handling ignores the ephemeral port; the callback path must match.
4. Add Microsoft Graph **delegated** permission `Files.Read`. The sign-in request also asks for `offline_access` so the app can refresh an expired access token. Application permissions and a client secret are not needed.
5. Copy the **Application (client) ID** into OpenFiles, then choose **Connect** and complete Microsoft's sign-in and consent in the system browser.

The app uses `https://login.microsoftonline.com/common/oauth2/v2.0/authorize`, authorization code flow with PKCE, and `http://localhost:<port>/callback`. An organizational administrator may need to allow the app or grant consent. The signed-in account must have a provisioned OneDrive.

See Microsoft's [desktop application registration](https://learn.microsoft.com/en-us/entra/identity-platform/scenario-desktop-app-registration), [redirect URI restrictions](https://learn.microsoft.com/en-us/entra/identity-platform/reply-url), and [delegated permissions](https://learn.microsoft.com/en-us/graph/permissions-reference#filesread).

## Connect and browse

Open **Cloud storage**, choose a provider, and enter its registration fields. **Connect** saves the registration and opens the provider's sign-in page. **Save and reconnect** replaces the provider's existing local authorization before starting a new sign-in. You can cancel sign-in; a cancelled or timed-out attempt must be started again.

Browse folders, return through the folder navigation, refresh a listing, or load another page of results. Choose a downloadable file and a local destination. OpenFiles refuses to replace an existing file; choose a different name or destination. Network and provider errors are displayed so you can retry. Remote browsing and downloads require an Internet connection.

**Disconnect** removes the locally stored authorization and retains your registration fields in Keychain. It does not delete your cloud files or revoke the app's grant at the provider. To revoke provider-side access, use your [Google third-party connections](https://myaccount.google.com/connections) or Microsoft's account/application permission controls. To use a different account for a provider, disconnect and sign in again.

## Data and permissions

- Connecting sends OAuth requests to the selected provider. Listing a folder fetches filenames, identifiers, sizes, modification dates, and provider links. Downloading sends the selected file identifier and retrieves its contents.
- The Google Drive API and Microsoft Graph receive bearer tokens only at their configured HTTPS API endpoints. OneDrive content can be served from a temporary download URL; the Graph bearer token is not forwarded to that content host.
- OAuth tokens and registration configuration are stored in macOS Keychain. They are not written into `library.json`, source files, or log output. A locked or inaccessible Keychain can prevent connection until it is available.
- Cloud listings remain separate from the local library. OpenFiles does not automatically index, organize, snapshot, or download remote files. A copy you save into your local home folder becomes an ordinary local file and can be included in the existing local indexing workflow.
- Downloads use temporary files while transferring, then save to your chosen destination. Disconnecting does not remove copies you have already downloaded. Keep sensitive downloads in a location appropriate for their contents.

## Development checks

The provider checks use temporary fixtures, fake tokens, an in-memory credential store, and a mocked HTTP transport. They do not connect to personal accounts:

```sh
swift run --build-system native OpenFilesCloudChecks
```

These checks exercise request construction, response handling, token refresh, pagination, and download boundaries. They do not establish that a real registration is configured correctly or that macOS Keychain/browser callbacks work. The application, native OAuth listener, and Keychain integration need macOS 14+ for validation.

Before shipping, use disposable files and test accounts to check both providers:

1. Build and run the app. Confirm the local browser still works before connecting a provider.
2. Connect, consent, browse nested folders, load additional pages, and refresh. Cancel a new sign-in, confirm the browser remains disconnected, and reconnect successfully.
3. Download a binary file and compare it with the original. Confirm an existing destination is refused and a failed/cancelled transfer does not publish a partial copy.
4. Open a Google Workspace item in the provider's website. Confirm it is not offered as an ordinary binary download.
5. Restart the app, unlock Keychain if requested, and confirm the connection can be restored. Exercise access-token refresh and a revoked grant, which should require reconnecting.
6. Disconnect while a listing or download is pending and confirm late results do not repopulate the disconnected browser. Switch providers and confirm folder state does not leak between them.
7. Confirm no remote files are added to the local semantic index, version history, or organization targets merely by browsing.

The app remains a locally signed developer build. Distribution needs a stable signing identity, appropriate provider registration/verification, and testing of Keychain access across updates.

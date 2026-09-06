# GitHub authentication setup

## Recommended: selected-repository tokens on iOS

In Account, create a fine-grained personal access token, select only the required repositories, grant Contents read/write (or read-only for downloads), and set an expiration date. Paste it into the secure field and choose **Connect selected repositories**. No OAuth client ID is needed for this option. GitNote validates the token with GitHub and stores it using `WhenUnlockedThisDeviceOnly` Keychain accessibility. This is the recommended path for public and private notebooks.

Disconnect removes the local credential; it does not revoke it on GitHub or delete downloaded notes. Account contains links to token and OAuth settings for revocation. Existing broad OAuth grants must be revoked there before reauthorizing if you want to remove their old permissions.

## Optional: OAuth for public repositories

The iOS app uses GitHub's OAuth device flow. The app opens GitHub in the browser, displays a one-time code, polls at GitHub's required interval, validates the resulting user, and stores the access token in Keychain. No client secret is embedded in the app.

## Register GitNote

1. Sign in to GitHub as the account that should own the OAuth App.
2. Open [GitHub → Settings → Developer settings → OAuth Apps](https://github.com/settings/developers) and choose **New OAuth App**.
3. Use `GitNote` as the application name.
4. Use `https://github.com/henrikvindshoj/GitNote` for both the homepage and authorization callback URL. Device flow does not use the callback URL, but GitHub requires one when registering the app.
5. Register the app, then enable **Device Flow** in its settings. Leave expiring user tokens disabled for this MVP; refresh-token rotation is not implemented yet.
6. Copy the OAuth App's client ID. The client ID is public; do not create or embed a client secret for this flow.

## Configure Xcode

1. Open `apps/ios/GitNote.xcodeproj`.
2. Select the GitNote project, then the GitNote target.
3. Open **Build Settings** and search for `GITHUB_OAUTH_CLIENT_ID`.
4. Set it to the copied client ID for both Debug and Release.
5. Build and run, open **Account**, and choose **Sign in with GitHub**.

The optional OAuth flow requests `public_repo`, allowing public-repository access only for a new grant. It is broader than selected-repository tokens and is not recommended when narrower access is sufficient. Access tokens are stored in Keychain and passed to libgit2 through in-memory credential callbacks; they are never written into clone URLs or Git configuration. Users with an older `repo` grant must revoke it in GitHub’s Authorized OAuth Apps settings; requesting a smaller scope does not revoke previously granted access. Use a fine-grained token for private notebooks.

## Simulator signing

Run GitNote from Xcode with normal code signing enabled. A simulator build created with
`CODE_SIGNING_ALLOWED=NO` can launch, but iOS will reject Keychain access with status
`-34018`. The GitNote test suite includes a signed Keychain round-trip test to catch this.

## Web authentication

The React client does not use the iOS device flow or an embedded client secret. It connects directly to GitHub’s REST API with a personal access token supplied in the account dialog.

1. Create a [fine-grained personal access token](https://github.com/settings/personal-access-tokens/new).
2. Select the repositories the browser client should access.
3. Grant **Contents: Read and write** for sync, or read-only access for downloading notes. Required metadata access is included by GitHub.
4. Paste the token in **GitHub account** and connect. GitNote validates it with the authenticated user endpoint.

The token is held in memory only, never in IndexedDB, localStorage, sessionStorage, URLs, or the service worker cache. Re-enter it after reloading the page. Disconnecting leaves local notes intact; remove a local copy or clear site data to remove downloaded private content. Public repositories can be downloaded without authentication. Branch protection and organization policies still apply to sync.

# GitHub OAuth setup

GitNote uses GitHub's OAuth device flow. The app opens GitHub in the browser, displays a one-time code, polls at GitHub's required interval, validates the resulting user, and stores the access token in Keychain. No client secret is embedded in the app.

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

GitNote requests `repo`, which permits it to browse, clone, and push public and authorized private repositories. Access tokens are stored in Keychain and passed to libgit2 through in-memory credential callbacks; they are never written into clone URLs or Git configuration. Users upgrading from a build that requested only `public_repo` must disconnect and sign in again once to grant the expanded scope.

## Simulator signing

Run GitNote from Xcode with normal code signing enabled. A simulator build created with
`CODE_SIGNING_ALLOWED=NO` can launch, but iOS will reject Keychain access with status
`-34018`. The GitNote test suite includes a signed Keychain round-trip test to catch this.

# GitNote

GitNote is a local-first client for Markdown repositories hosted on GitHub. The MVP is a native iPhone and iPad app that can discover multiple GitHub repositories, create real local Git working copies, browse and edit Markdown, show working-tree changes, and expose its Documents directory through the Files app.

## Repository layout

```text
apps/
  ios/                 Native SwiftUI MVP
  android/             Reserved Android application boundary
  web/                 Reserved web application boundary
services/
  api/                 Optional future backend services
packages/
  contracts/           Platform-neutral API contracts
docs/                  Product and architecture documentation
```

The platform folders are intentionally independent. UI and local Git behavior stay native, while shared network contracts live under `packages/` so Android, Web, and backend implementations can evolve alongside iOS without coupling their build systems.

## Run the iOS MVP

Requirements: Xcode 26 or newer and iOS 17 or newer.

1. Open `apps/ios/GitNote.xcodeproj`.
2. Select the `GitNote` scheme and an iPhone or iPad simulator.
3. Build and run.
4. Configure the GitHub OAuth client ID as described in [docs/GITHUB_OAUTH.md](docs/GITHUB_OAUTH.md).
5. Open Account, choose **Sign in with GitHub**, and authorize GitNote as your GitHub user.
6. Add a public repository directly as `owner/repository`, or browse repositories available to your account.

OAuth tokens are stored in Keychain. The MVP never writes a token into a clone URL or Git configuration.

## Current MVP boundary

Implemented:

- Multiple local working copies.
- GitHub OAuth device login, account validation, and repository discovery.
- Real `libgit2` clones for public HTTPS repositories.
- Markdown file creation and Word-like editing with hidden syntax, a persistent formatting toolbox, and secondary raw-source inspection.
- Git working-tree status.
- Dirty working-copy badges and optimistic stage-all, commit, and authenticated push sync.
- Files app visibility via document sharing.
- Offline access to cloned notes.

Not yet implemented:

- Authenticated clone/push for private repositories.
- Pull, branch management, and merge conflict resolution.
- Guaranteed direct vault adoption by Obsidian on every Apple platform.
- Android, Web, or backend runtime code.

See [docs/MVP.md](docs/MVP.md) for acceptance criteria and [PLAN.md](PLAN.md) for the longer roadmap.

## Security note

GitNote requests the OAuth `public_repo` scope for the current public-repository MVP. Access tokens remain in Keychain and are supplied to libgit2 only through an in-memory credential callback.

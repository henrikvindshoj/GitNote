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
4. Add a public repository directly as `owner/repository`, or save a fine-grained GitHub personal access token to browse repositories available to your account.

Tokens are stored in Keychain. The MVP never writes a token into a clone URL or Git configuration.

## Current MVP boundary

Implemented:

- Multiple local working copies.
- GitHub token validation and repository discovery.
- Real `libgit2` clones for public HTTPS repositories.
- Markdown file creation, browsing, source editing, and preview.
- Git working-tree status.
- Files app visibility via document sharing.
- Offline access to cloned notes.

Not yet implemented:

- Authenticated clone/push for private repositories.
- Commit, pull, push, branches, and merge conflict resolution.
- Guaranteed direct vault adoption by Obsidian on every Apple platform.
- Android, Web, or backend runtime code.

See [docs/MVP.md](docs/MVP.md) for acceptance criteria and [PLAN.md](PLAN.md) for the longer roadmap.

## Security note

Use a fine-grained token with read-only repository metadata access for the MVP. Do not grant write access until authenticated Git operations are implemented and reviewed.

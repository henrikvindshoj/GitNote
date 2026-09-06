# GitNote development guide

GitNote is a local-first client for Markdown repositories hosted on GitHub. The native iPhone and iPad MVP is an app that can discover multiple GitHub repositories, create real local Git working copies, browse and edit Markdown, show working-tree changes, and expose its Documents directory through the Files app.

## Repository layout

```text
apps/
  ios/                 Native SwiftUI MVP
  android/             Reserved Android application boundary
  web/                 React / TypeScript browser client
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
4. Create a fine-grained token as described in the [authentication guide](GITHUB_OAUTH.md).
5. Open Account and choose **Connect selected repositories**. The optional OAuth route is for public repositories and requires a configured client ID.
6. Add a public or private repository directly as `owner/repository`, or browse repositories available to your account.

OAuth tokens are stored in Keychain. The MVP never writes a token into a clone URL or Git configuration.

## Run the web app

Requirements: Node.js 22.12+ and npm.

```sh
cd apps/web
npm ci
npm run dev
```

Use `npm test` for unit tests and `npm run build` for type checking and the production build. Run `npx playwright install chromium` followed by `npm run test:e2e` for browser tests. The web CI workflow runs these checks independently of iOS.

The web client uses React, Tiptap, IndexedDB, and the GitHub REST API. Its production build caches the application shell for offline reopening. It needs no backend or OAuth client ID; private repositories and sync use a token held in memory for the current session. See the [web README](../apps/web/README.md) for authentication, deployment, supported workflows, and browser limits.

## Current iOS MVP boundary

Implemented:

- Multiple local working copies.
- Selected-repository personal tokens, optional public-repository OAuth device login, account validation, and repository discovery.
- Authenticated `libgit2` clones for public and authorized private HTTPS repositories.
- Markdown file creation and Word-like editing with hidden syntax, a persistent formatting toolbox, and secondary raw-source inspection.
- Git working-tree status.
- Dirty working-copy badges and sync that fetches first, fast-forwards clean copies, and commits/pushes compatible local changes. Clean downloads need no commit message or author details.
- Files app visibility via document sharing.
- Offline access to cloned notes.

Not yet implemented:

- Automatic merging/rebasing, branch management, and merge conflict resolution. Diverged history and dirty copies behind GitHub are preserved and require reconciliation in another Git client.
- Guaranteed direct vault adoption by Obsidian on every Apple platform.
- Android or backend runtime code.

See the [MVP acceptance criteria](MVP.md) and the [longer-term project plan](../PLAN.md).

## Security note

iOS recommends fine-grained tokens limited to selected repositories. Optional OAuth requests `public_repo`; previous broad grants must be revoked in GitHub settings. Credentials use unlocked-device-only Keychain storage, an exact GitHub repository destination check, normal certificate validation, and no authenticated redirects. Symlink components are rejected during file access. Notes are limited to 2 MB; clones are limited to 100 MB transferred and checked out, 20,000 objects, 10,000 files, and 20 MB per checked-out file. Images are bounded before thumbnail decoding. Clone cancellation and the 120-second deadline are checked at libgit2 progress boundaries.

CI runs signed simulator XCTest, browser tests, and npm advisory checks. The security assessment and remediation status are in [the security report](security/ASSESSMENT-2026-09-06.md).

The web app uses a fine-grained token with repository Contents access, stored only in memory. Downloaded notes, including private notes, stay in IndexedDB after disconnecting. See [web authentication](GITHUB_OAUTH.md#web-authentication).

# Architecture

## Monorepo boundaries

GitNote uses a product monorepo rather than a shared-runtime monolith. Each client owns its UI, local persistence, and Git integration:

- `apps/ios`: SwiftUI, Keychain, Files integration, and libgit2.
- `apps/android`: future Kotlin/Compose client and native Git adapter.
- `apps/web`: React/TypeScript, Tiptap, IndexedDB, and a GitHub REST adapter. Browser copies are note snapshots, not local Git working trees.
- `services/api`: optional future webhooks, notification relay, or account services. OAuth device flow and repository contents travel directly between the client and GitHub.
- `packages/contracts`: OpenAPI and other platform-neutral schemas. Generated clients may be produced within each platform folder.

## iOS layers

```text
SwiftUI features
       |
    AppModel
   /    |     \
GitHub Git   Workspace files
 API  engine   + metadata
       |
 SwiftGitX / libgit2
```

- `Domain` contains serializable repository, workspace, Markdown-file, and change models.
- `Infrastructure` owns GitHub HTTP, Keychain, filesystem traversal, workspace persistence, and the Git adapter.
- `Application/AppModel` is the main-actor state coordinator consumed by SwiftUI.
- `Features` contains screens and reusable views.

The app stores workspace metadata as JSON in Application Support and real clones under `Documents/Repositories`. `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` make the Documents container visible through Files. Repository contents are canonical; the metadata store never duplicates note bodies.

## Web layers

```text
React repository/account UI + Tiptap editor
                     |
                App coordinator
                 /          \
           IndexedDB       GitHub REST
       notes + baselines   trees / commits / refs
```

The web client downloads visible Markdown blobs from the default branch and stores exact note bodies, original bodies, directory metadata, and the base tree/commit in IndexedDB. Downloads are committed locally only when complete. A serial write queue persists edits; storage failures remain visible and trigger a leave-page warning. Web Locks prevent simultaneous writers in multiple tabs where supported.

Dirty state compares each note against its original body. Sync creates a tree over the remote base tree, preserving all other files, then creates one commit and updates the branch with `force: false`. The adapter rejects a changed remote head before creating a commit; GitHub rejects any subsequent non-fast-forward race. Local baselines advance only after the update succeeds. No pull or merge is performed.

Tiptap handles common rich Markdown; source mode handles unsupported structures without rendering arbitrary HTML. Opening a note does not serialize it. The production service worker precaches application assets only; API traffic is never put into the service-worker cache. Individual notes can be downloaded as Markdown, and all local notes can be exported as JSON.

## Dependency decision

The MVP pins SwiftGitX 0.4.x, which wraps libgit2 and supports Apple platforms through Swift Package Manager. Its adapter is isolated in `GitEngine.swift`. This deliberately limits replacement cost if GitNote later adopts direct swift-libgit2 bindings for authenticated credential callbacks, more precise pull behavior, or Git LFS.

## Security boundaries

- iOS GitHub OAuth tokens live only in Keychain. Web personal access tokens live only in memory and are cleared on reload or disconnect.
- Push tokens are passed to libgit2 through an in-memory credential callback and are never persisted in Git configuration.
- HTTP uses GitHub's HTTPS API and standard URLSession trust handling.
- Clone URLs are validated HTTPS URLs and do not contain credentials.
- File enumeration skips hidden files and never presents `.git` internals for editing.
- All note writes are constrained to a URL produced by the workspace scanner.

Web HTTP goes directly to `https://api.github.com`; credentials are attached only in an Authorization header. Private browser copies remain in IndexedDB after disconnecting. Browser storage is subject to eviction and is not a filesystem vault. See the [web guide](../apps/web/README.md) for limits and export behavior.

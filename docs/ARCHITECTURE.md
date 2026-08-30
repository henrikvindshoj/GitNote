# Architecture

## Monorepo boundaries

GitNote uses a product monorepo rather than a shared-runtime monolith. Each client owns its UI, local persistence, and Git integration:

- `apps/ios`: SwiftUI, Keychain, Files integration, and libgit2.
- `apps/android`: future Kotlin/Compose client and native Git adapter.
- `apps/web`: future browser experience; it cannot assume direct access to local Git working copies.
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

## Dependency decision

The MVP pins SwiftGitX 0.4.x, which wraps libgit2 and supports Apple platforms through Swift Package Manager. Its adapter is isolated in `GitEngine.swift`. This deliberately limits replacement cost if GitNote later adopts direct swift-libgit2 bindings for authenticated credential callbacks, more precise pull behavior, or Git LFS.

## Security boundaries

- GitHub OAuth tokens live only in Keychain.
- Push tokens are passed to libgit2 through an in-memory credential callback and are never persisted in Git configuration.
- HTTP uses GitHub's HTTPS API and standard URLSession trust handling.
- Clone URLs are validated HTTPS URLs and do not contain credentials.
- File enumeration skips hidden files and never presents `.git` internals for editing.
- All note writes are constrained to a URL produced by the workspace scanner.

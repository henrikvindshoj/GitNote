# GitNote product and implementation plan

> Implementation status: iOS and React web MVPs are available. The web client uses browser snapshots and GitHub API commits rather than filesystem clones. This document retains the broader product roadmap; see [development](docs/DEVELOPMENT.md) and the [web guide](apps/web/README.md) for what is implemented today.

## 1. Product definition

GitNote is a local-first Git client for Markdown repositories. It connects to GitHub, keeps multiple repositories as ordinary working copies, provides a focused Markdown browsing and editing experience, and lets other editors such as Obsidian work with the same files.

The initial product should target iPhone and iPad, with macOS support designed in from the beginning. The recommended implementation is a native Swift/SwiftUI app because Git integration, local file access, background work, Keychain storage, and Apple Files integration are central to the product.

### Product principles

- **Local first:** cloned content remains usable without a network connection.
- **Real Git:** repositories contain normal files and standard `.git` metadata; GitNote does not invent its own sync format.
- **Interoperable:** users can open a working copy in Obsidian or another file-based Markdown editor.
- **Safe by default:** destructive Git operations require explicit confirmation and recoverable operations are preferred.
- **Progressive complexity:** basic edit/commit/push flows stay simple, while branches, diffs, and conflict tools are available when needed.
- **User-controlled sync:** edits save automatically, but commits, pulls, and pushes are explicit in the first version.

## 2. Primary user journeys

### Connect and clone

1. The user signs in to GitHub.
2. GitNote lists repositories the account can access and supports search/filtering.
3. The user selects a repository, branch, and local location.
4. GitNote clones it and opens the Markdown file browser.

### Read and edit notes

1. The user selects one of several local repositories.
2. GitNote shows folders, Markdown files, and repository status.
3. The user reads rendered Markdown or edits the source.
4. GitNote saves the file locally and marks the working copy as changed.

### Synchronize changes

1. The user reviews changed files and diffs.
2. The user stages all or selected files and writes a commit message.
3. GitNote commits locally.
4. The user fetches/pulls and then pushes to GitHub.
5. If histories diverge, GitNote explains the situation and offers a guided resolution rather than silently rewriting history.

### Work in Obsidian

1. The user chooses **Open in Obsidian / Files** or selects a shared repository location.
2. Obsidian reads and edits the same Markdown folder.
3. GitNote detects those external changes and shows them in Git status.
4. The user commits and pushes the external edits from GitNote.

The round trip in this final journey is a release-blocking capability, not an optional export feature.

## 3. MVP scope

### Include

- One GitHub account and multiple repositories; keep the model ready for multiple accounts later.
- GitHub sign-in with access to public and authorized private repositories.
- Repository listing, search, clone, remove local copy, and re-clone.
- Local repository switcher with clone/sync state.
- Folder and file browser optimized for `.md` and `.markdown` files.
- Markdown source editor and rendered preview.
- Create, rename, move, and delete Markdown files and folders.
- Git status, file diff, stage/unstage, commit, fetch, pull, and push.
- Current-branch display and branch switching when the working tree is clean.
- Clear offline, authentication, merge-conflict, and push-rejection states.
- Standard links, images with relative paths, YAML front matter, and common Markdown extensions.
- External-folder integration sufficient for an Obsidian round trip on the supported platform.
- Keychain-backed credential storage and protection against credentials appearing in logs or remote URLs.

### Defer until after MVP

- Pull request creation/review, issues, discussions, and GitHub Actions.
- Rich WYSIWYG or block editing.
- Real-time collaboration.
- Automatic background commits or pushes.
- Full graphical merge editor; MVP can provide a clear conflict list and source-marker editor.
- Git LFS downloads/uploads, submodules, sparse checkout, worktrees, and signing commits.
- Non-GitHub remotes, SSH keys, self-hosted GitHub Enterprise, and multiple GitHub accounts.
- Plugin ecosystem, graph view, backlinks, databases, and an Obsidian-compatible plugin runtime.

## 4. Resolve the highest-risk question first

The largest product risk is not Markdown editing or GitHub authentication; it is allowing GitNote and Obsidian to safely edit the same repository on iPhone/iPad.

Run a short interoperability spike before building the full app. Test these approaches with a small repository containing `.git`, nested folders, attachments, and Unicode filenames:

1. A user-selected folder in iCloud Drive retained with a security-scoped bookmark.
2. A Files/File Provider extension backed by GitNote's repository storage.
3. An app-owned working copy plus explicit import/export, only as a fallback because it does not provide a true shared working copy.

Validate each approach on physical iPhone and iPad devices, with GitNote suspended and relaunched, with iCloud temporarily offline, and with edits made alternately in both apps. Also verify which locations Obsidian can actually adopt as a vault. Choose the simplest approach that passes the round-trip tests. On macOS, use a normal user-selected directory with a retained security-scoped bookmark.

Do not promise universal “Open in Obsidian” support until this spike passes. If iOS restrictions prevent a dependable shared folder, make the first public release macOS-first or clearly scope iOS interoperability to the supported storage location.

## 5. Recommended architecture

Use a modular monolith initially. Separate packages/modules make the risky components testable without adding service or framework complexity.

### App/UI

- SwiftUI navigation for account, repository list, file browser, editor, changes, history, and settings.
- Platform-specific adapters only where file picking, commands, or window behavior differs.
- An operation center for long-running clone/fetch/push progress and cancellation.

### Git engine

- A thin Swift-facing adapter over a mature native Git implementation such as `libgit2`.
- One serialized operation queue per repository to prevent overlapping Git writes.
- Typed operations for clone, status, diff, stage, commit, fetch, merge/fast-forward, branch, and push.
- Structured progress, cancellation, and actionable errors; do not expose raw library errors directly to users.
- Integration tests against local bare repositories so most Git behavior can be verified without GitHub or network access.

Keep the Git adapter narrow so the underlying library can be replaced if its Apple-platform maintenance, binary size, or credential support proves unsuitable during the spike.

### GitHub service

- Browser-based OAuth appropriate for an installed app.
- GitHub API client for the repository list, account metadata, branches, and permission information.
- HTTPS Git credentials supplied to the Git engine only when needed.
- Pagination, rate-limit handling, token-expiration recovery, and mocked responses in tests.

### Workspace and file coordination

- A `Workspace` abstraction that owns the repository URL, selected external location/bookmark, active branch, and local state.
- Coordinated reads/writes for folders that may also be edited by another app or synchronized by iCloud.
- Filesystem observation plus a full Git status refresh after returning to the foreground; observers alone are not authoritative.
- Atomic file writes where possible and no assumptions about filenames being ASCII or case-sensitive.
- Repository validation to prevent writes outside the selected working-copy root through malformed paths or symlinks.

### Markdown subsystem

- Plain-text source is always canonical.
- Source editor and deterministic rendered preview.
- Relative links and images resolve against the current file/repository.
- Front matter is preserved even when GitNote does not interpret every key.
- Editor autosave is separate from Git commit history.

### Persistence

Persist metadata such as account identity, repository remote, local bookmark/location, last branch, and UI preferences in a small local store. Do not duplicate repository file contents in the database. Store credentials only in Keychain.

### Suggested domain objects

- `GitHubAccount`
- `RemoteRepository`
- `Workspace`
- `RepositoryOperation`
- `WorkingTreeStatus`
- `FileChange`
- `CommitDraft`
- `SyncState`

## 6. Git behavior and safety rules

- Autosave files, but never auto-commit or auto-push in MVP.
- Fetch before deciding whether a pull/push is safe.
- Use fast-forward-only pull when possible. If local and remote histories diverge, present an explicit merge/rebase choice later; MVP may support merge only.
- If the working tree is dirty before pull or branch switch, block the operation with clear next actions: commit, discard selected changes, or cancel. Add stash after MVP unless it is required by beta feedback.
- Never force-push through the normal sync button.
- Show exactly which files are staged before commit.
- Make deleting a local clone explicit and explain that it does not delete the GitHub repository.
- Keep an operation journal sufficient to explain the latest failed Git action without recording tokens or file contents.

## 7. Delivery roadmap

Assuming one experienced Apple-platform engineer, the MVP is approximately 12–16 weeks. A second engineer can shorten the calendar time by separating Git/file infrastructure from the UI, but the interoperability spike should still happen first.

### Phase 0 — Product and interoperability spike (week 1–2)

- Confirm iPhone/iPad/macOS release order.
- Prototype clone/status on device with the candidate Git library.
- Test GitHub authentication and private-repository credentials.
- Complete the Obsidian/shared-folder experiment described above.
- Record decisions in short architecture decision records.

**Exit:** a physical-device demo clones a private test repository, an external editor changes a Markdown file, and GitNote detects the change.

### Phase 1 — App foundation and accounts (week 2–3)

- Establish modules, dependency boundaries, logging, error model, and CI.
- Implement GitHub sign-in/sign-out and Keychain storage.
- List/search repositories with pagination and permission states.
- Add test accounts and a repeatable fixture-repository setup.

**Exit:** a user can sign in and browse every repository they are authorized to clone.

### Phase 2 — Working copies and file browser (week 4–6)

- Clone with progress/cancellation and default-branch detection.
- Implement the repository switcher and local workspace lifecycle.
- Build folder navigation, file search, and Markdown preview.
- Handle offline opening and clone recovery after interruption.

**Exit:** multiple repositories can be cloned, reopened offline, switched, and safely removed locally.

### Phase 3 — Editing and external changes (week 6–8)

- Add source editing, preview, autosave, file/folder operations, attachments, and link handling.
- Implement coordinated filesystem access and external-change refresh.
- Finish the supported Obsidian/Files workflow and in-app instructions.

**Exit:** edits made in either GitNote or the supported external editor survive relaunch and are visible in both apps.

### Phase 4 — Complete Git workflow (week 8–11)

- Add status, unified diff, staging, commit, fetch, fast-forward pull, push, and branch switching.
- Add safe dirty-tree checks and push-rejection handling.
- Add conflict detection and a minimal conflict-resolution workflow.
- Make all long-running operations cancellable where the Git library allows it.

**Exit:** two devices can alternately edit and sync a test repository, including a deliberately created conflict.

### Phase 5 — Hardening and private beta (week 11–14)

- Test large repositories, many small files, large attachments, slow networks, expired credentials, low disk space, and interrupted operations.
- Add accessibility, keyboard support, iPad multitasking, and recovery UI.
- Add privacy disclosures, diagnostics export with redaction, and onboarding.
- Run TestFlight with users who already keep Obsidian vaults in Git.

**Exit:** no known data-loss bugs, auth secrets do not leak, and beta users can complete the four primary journeys without developer help.

### Phase 6 — Release and next iteration (week 15+)

- Ship the narrow MVP.
- Measure clone success, sync failures, conflict frequency, and external-editor adoption without collecting note contents or filenames.
- Prioritize multiple accounts, richer conflicts, SSH/non-GitHub remotes, history, backlinks, or pull requests based on observed demand.

## 8. Test strategy

### Automated

- Unit tests for path validation, Markdown links, status mapping, error translation, and domain state transitions.
- Git integration matrix using temporary working copies and local bare remotes: clean clone, ahead, behind, diverged, untracked, renamed, deleted, conflicted, detached head, and interrupted operation.
- API contract tests using recorded/synthetic GitHub responses without storing real tokens.
- UI tests for sign-in callback handling, repository switching, editing, staging, commit, and sync error recovery.

### Physical-device scenarios

- GitNote and Obsidian editing the same vault in alternating foreground/background cycles.
- iCloud online/offline transitions and changes from a second Apple device.
- Network loss during clone/fetch/push.
- Token revocation and repository permission removal.
- Low storage, app termination during clone, and restoration after update.
- Repositories with Unicode, emoji, spaces, case-only renames, symlinks, hundreds of folders, and large binary attachments.

## 9. Security and privacy baseline

- Store OAuth tokens in Keychain with the narrowest practical GitHub authorization.
- Never embed tokens in persisted clone URLs, analytics, crash reports, or Git configuration.
- Redact remote URLs and user content from exported diagnostics by default.
- Treat rendered Markdown as untrusted input: block unsafe script execution and carefully control external URL/file handling.
- Validate all filesystem destinations and do not follow paths outside the working-copy root.
- Publish a clear privacy policy stating what metadata leaves the device.
- Use test GitHub organizations and repositories for CI; never use a developer's personal token in builds.

## 10. MVP success criteria

- At least 95% of valid test repository clones complete or return an actionable error.
- A user can manage at least 20 cloned repositories without cross-repository state or credential leakage.
- A Markdown edit can round-trip GitNote → Obsidian → GitNote → commit → GitHub without copying files manually.
- No app action can silently discard uncommitted content.
- The complete edit/commit/push flow is usable offline until the final network operation.
- Common push rejection and merge-conflict cases explain what happened and preserve both versions.
- No credentials appear in local Git configuration, logs, analytics, or diagnostics.

## 11. Decisions to make after the spike

1. Whether v1 ships on iPhone/iPad, macOS, or all three together.
2. Which shared-folder mechanism reliably supports Obsidian on each platform.
3. Which Git implementation meets clone, authentication, cancellation, binary-size, and maintenance requirements.
4. Whether merge support is sufficient for MVP or rebase is also required.
5. Whether the initial GitHub authorization model should favor the simplest onboarding or finer per-repository access.

These are implementation decisions, not reasons to delay the first prototype. Phase 0 should produce evidence for each one.

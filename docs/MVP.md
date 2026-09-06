# iOS MVP

## Goal

Prove the smallest useful GitNote loop on a physical iPhone or iPad:

1. Connect to GitHub or enter a public or private `owner/repository` address.
2. Clone more than one real repository locally.
3. Read and edit Markdown offline.
4. Observe the edit in Git status.
5. Reach the working-copy folder through Files so another editor can modify its contents.

## Acceptance checklist

- [x] Public and authorized private GitHub repositories can be resolved and cloned.
- [x] Multiple cloned repositories persist across app launches.
- [x] A user can authorize GitNote through GitHub's OAuth device flow, with credentials stored in Keychain.
- [x] `.md` and `.markdown` files are discoverable without exposing `.git` internals.
- [x] New Markdown files and optional parent folders can be created safely inside a working copy.
- [x] Markdown opens in a directly editable, syntax-hiding surface with common formatting tools and secondary raw-source inspection.
- [x] Working-tree changes are listed after an edit or foreground refresh.
- [x] Dirty working copies are visible in the repository list.
- [x] Sync fetches GitHub first, fast-forwards a clean copy, or stages/commits/pushes compatible local changes. Diverged history and local edits behind GitHub stop without overwriting work.
- [x] Cloned repositories remain readable offline.
- [x] The Documents container is visible in Files.
- [ ] Validate Obsidian round-trip behavior on physical devices and document the exact supported location.
- [x] Download newer commits into clean copies with safe fast-forward checkout.
- [ ] Add selective staging and conflict resolution.

## Manual test

Use a small public fixture repository containing nested Markdown, front matter, relative links, images, Unicode filenames, and at least one non-Markdown file.

1. Install the app on a device.
2. Add and clone the fixture repository.
3. Turn on airplane mode and open two Markdown files.
4. Edit and save one file.
5. Confirm the Changes view lists it.
6. Open Files → On My iPhone → GitNote → Repositories.
7. Edit the file using a compatible external editor.
8. Return to GitNote and refresh; confirm the external change remains present.
9. Sign in with GitHub, sync, and confirm the new commit appears on GitHub.

## Explicit limitations

The OAuth request uses the `repo` scope. Clone and push authentication use in-memory libgit2 credential callbacks and never write the OAuth token into clone URLs or Git configuration.

## Web counterpart

The React client now implements the same core browsing, writing, folders, change-review, and explicit-sync loop. Browser copies persist in IndexedDB; production application assets are cached for offline use. Its authentication is session-only token entry, and sync creates commits via GitHub’s API rather than a local Git engine.

Web acceptance checks and browser-specific limitations are maintained in the [web README](../apps/web/README.md). Automated browser tests cover the workflow against a mocked GitHub API, including offline reopening and a mobile viewport. Apple Files integration and local Git clones remain native-only capabilities.

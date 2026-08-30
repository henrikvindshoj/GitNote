# iOS MVP

## Goal

Prove the smallest useful GitNote loop on a physical iPhone or iPad:

1. Connect to GitHub or enter a public `owner/repository` address.
2. Clone more than one real repository locally.
3. Read and edit Markdown offline.
4. Observe the edit in Git status.
5. Reach the working-copy folder through Files so another editor can modify its contents.

## Acceptance checklist

- [x] A public GitHub repository can be resolved and cloned.
- [x] Multiple cloned repositories persist across app launches.
- [x] GitHub credentials are stored in Keychain.
- [x] `.md` and `.markdown` files are discoverable without exposing `.git` internals.
- [x] New Markdown files and optional parent folders can be created safely inside a working copy.
- [x] Markdown source can be edited and rendered.
- [x] Working-tree changes are listed after an edit or foreground refresh.
- [x] Cloned repositories remain readable offline.
- [x] The Documents container is visible in Files.
- [ ] Validate Obsidian round-trip behavior on physical devices and document the exact supported location.
- [ ] Add credential callbacks for private clone, fetch, and push.
- [ ] Add staging, commit, safe pull, and push.

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

## Explicit limitations

Repository discovery can show private repositories when the supplied token permits it, but the clone action is disabled for them. SwiftGitX's high-level clone API does not expose credential callbacks in the pinned version. Putting tokens in URLs would leak credentials into Git configuration, so GitNote does not use that workaround.

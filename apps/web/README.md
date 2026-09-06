# GitNote Web

A React + TypeScript browser client that follows the iOS app’s repository → write → review → sync workflow. Vite builds a static app; no backend or environment secrets are required.

## Run locally

Use Node.js 22.12+ (Node 24 LTS recommended) and npm.

```sh
cd apps/web
npm ci
npm run dev
```

Open the URL printed by Vite. For the production build, including offline application loading:

```sh
npm run build
npm run preview
```

Deploy the contents of `dist/` to a static host at the origin root over HTTPS. Service workers require HTTPS or localhost. The production service worker caches only application assets, never GitHub API responses. Development mode does not install a service worker.

## Use the app

1. Choose **Add repository** and enter `owner/repository` or its GitHub HTTPS URL. Public repositories require no account.
2. For private repositories or sync, open **GitHub account**. Supply a [fine-grained personal access token](https://github.com/settings/personal-access-tokens/new) with access to the selected repositories and **Contents: Read and write** permission. Read-only permission is enough for downloads. Organization approval or branch protection rules may restrict writes.
3. Optionally load and filter repositories available to your account in the Add Repository dialog.
4. Browse folders, search the current folder, and create Markdown notes or nested folders. Existing `.md` and `.markdown` files are downloaded completely before a working copy is added.
5. Write with the formatting toolbar or switch to **Source**. Edits save automatically in IndexedDB. **Changes** shows added/modified notes and their before/after text.
6. **Sync changes** creates one GitHub commit with all changed notes, the commit message, and author details you supply. Sync does not pull or merge.
7. Download an individual Markdown file or export all local note paths, bodies, and folders as JSON. Removing a local copy requires confirmation and never deletes the GitHub repository.

Tokens are kept only in memory and must be entered again after a reload. Disconnecting clears the token, but downloaded private notes remain locally until the copy or site data is removed.

## GitHub token permissions

When creating a [fine-grained personal access token](https://github.com/settings/personal-access-tokens/new):

1. Under **Repository access**, choose **Only select repositories** and select the repositories you want to use with GitNote.
2. Under **Permissions → Repositories**, click **Add permissions**, search for **Contents**, and add it. Set its access to **Read and write** to download and sync notes.
3. Leave **Metadata** at **Read-only**. GitHub includes this permission automatically.
4. No **Account** permissions are needed.
5. Click **Generate token**, then paste the token into GitNote’s **GitHub account** dialog and click **Connect account**.

If you only want to download and read repositories, **Contents: Read-only** is sufficient. Sync requires **Read and write**.

## Browser-specific behavior

- Each copy is a snapshot of the default branch, stored with original note bodies and the base commit/tree in IndexedDB. It is **not** a filesystem Git clone and has no local commit history or Apple Files/Obsidian integration.
- Once the production app has loaded and its service worker is ready, it can reopen and edit downloaded notes offline. Network access is required to connect, download, discover repositories, or sync.
- Browser site data can be cleared or evicted. Use exports and GitHub sync for durable backups. Storage failures are reported; do not close the tab before downloading affected edits.
- One tab per origin may edit at a time using the Web Locks API. A second tab asks you to close the first and reload. Browsers without Web Locks should be used with one GitNote tab.
- Merely opening a note does not rewrite its Markdown. Rich editing can normalize whitespace and Markdown syntax. Front matter, HTML, images, tables, reference definitions, and task lists open in source mode to avoid a lossy rich-text conversion. These constructs remain editable as text; relative images are not rendered.
- All non-Markdown files remain in the remote base tree. Hidden paths, symlinks, and submodules are not presented as editable notes. Empty folders remain local until they contain a committed note.
- Sync checks the branch head and updates it without force. A changed remote branch or rejected update leaves local edits intact. Export and reconcile externally, then remove and re-add the copy to obtain a fresh snapshot. There is no pull, branch switching, conflict resolution, selective staging, note deletion, or note renaming yet.
- If a network response is lost after GitHub accepts a commit, check GitHub before retrying. The app may still show local changes; it will refuse to overwrite the now-advanced remote branch.
- Empty GitHub repositories must first be initialized with a commit. Truncated Git trees, more than 1,000 Markdown files, or more than 20 MB of Markdown are rejected rather than partially downloaded. GitHub API rate limits apply; connecting an account is useful for repositories with many notes.

## Validation

```sh
npm test
npm run format:check
npm run build
npx playwright install chromium
npm run test:e2e
```

Unit tests cover path validation, collisions, dirty state, IndexedDB persistence, UTF-8 downloads, API pagination, commit construction, and rejected writes. Playwright tests use a mocked GitHub API and a real production build to cover rich/source editing, persistence, folders, discovery, sync, mobile navigation, removal, offline reloads, rejected syncs, storage failures, and protection against competing tabs. They never write to a real repository.

## Code layout

- `src/App.tsx`: repository/account UI and local state coordination.
- `src/NoteEditor.tsx`: Tiptap rich Markdown editor, source editing, and file downloads.
- `src/model.ts`: platform-specific models, path validation, and change detection.
- `src/storage.ts`: transactional IndexedDB persistence.
- `src/github.ts`: GitHub REST download and optimistic commit/update adapter.
- `vite.config.ts`: React build and offline application shell.

The editor uses [Tiptap’s Markdown API](https://tiptap.dev/docs/editor/markdown/getting-started/basic-usage). Sync uses GitHub’s [Git tree API](https://docs.github.com/en/rest/git/trees) and [reference API](https://docs.github.com/en/rest/git/refs). Dependencies are pinned by `package-lock.json`; use `npm ci` for reproducible installs.

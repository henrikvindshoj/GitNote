# GitNote

**Your Markdown notes, backed by GitHub.**

GitNote is a local-first notes app for people who keep Markdown files in GitHub repositories. It gives you a friendly writing experience on iPhone, iPad, and the web while keeping your notes as ordinary `.md` files that you own and can use with other tools.

## What GitNote can do for you

- **Keep different collections together.** Connect multiple GitHub repositories and manage each one as a separate working copy.
- **Write without Markdown getting in the way.** Edit notes in a Word-like view with formatting tools for headings, bold, italic, lists, quotes, links, code, and more.
- **Work offline.** Read and edit cloned notes without a network connection.
- **Organize with directories.** Browse nested folders and create directories or Markdown files wherever they belong.
- **Stay in control of your files.** Notes stay as regular Markdown in GitHub. iOS keeps real local Git repositories; the web app keeps offline browser copies with Markdown and JSON export.
- **See what changed.** GitNote shows when a working copy has uncommitted changes and lets you inspect the changed files.
- **Send updates to GitHub.** Sync stages your changes, creates a commit, and pushes it to the connected repository.
- **Use other editors too on iOS.** Working copies are exposed through Apple's Files app so compatible Markdown editors can access the same files.
- **Inspect the source when needed.** Raw Markdown is still available as a secondary view, while the formatted editor remains the default.

## A simple workflow

1. Connect your GitHub account (OAuth on iOS, a session-only personal access token on the web).
2. Choose a public or private Markdown repository, or enter its `owner/repository` address.
3. Clone it on iOS or download an offline copy in your browser.
4. Browse, create, and edit notes—even while offline.
5. Review the working copy's changes and sync them back to GitHub.

Because GitNote works with standard Git repositories and Markdown files, your notes can also be cloned on a computer and opened in Obsidian, VS Code, or another Markdown-compatible app.

## Who GitNote is for

GitNote is designed for writers, developers, researchers, and knowledge workers who like Markdown and want the ownership and history of Git without doing everyday note-taking from a terminal.

## Current availability

GitNote has an early iPhone/iPad MVP and a React web app in [`apps/web`](apps/web). Both support public and authorized private GitHub repositories, offline notes, rich/source editing, folders, change review, and explicit sync. The web app stores notes in IndexedDB and commits through the GitHub API; its browser-specific limits are documented in the [web guide](apps/web/README.md). Pulling remote changes, branch management, and merge-conflict resolution are planned but not yet available.

To run the web app with Node.js 22.12+: `cd apps/web && npm ci && npm run dev`.

For build instructions and technical details, see the [development guide](docs/DEVELOPMENT.md). The [project plan](PLAN.md) describes the longer-term direction.

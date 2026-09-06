import {
  changes,
  isMarkdown,
  repositoryAddress,
  visiblePath,
  type GitHubUser,
  type Repository,
  type TreeEntry,
  type Workspace,
} from "./model";
const API = "https://api.github.com";
const segment = encodeURIComponent;
const repoPath = (fullName: string) =>
  `/repos/${repositoryAddress(fullName).split("/").map(segment).join("/")}`;

export class GitHubClient {
  constructor(
    private token = "",
    private transport: typeof fetch = (...args) => globalThis.fetch(...args),
  ) {}
  private async request<T>(
    path: string,
    method = "GET",
    body?: unknown,
  ): Promise<T> {
    const response = await this.transport(`${API}${path}`, {
      method,
      headers: {
        Accept: "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        ...(this.token ? { Authorization: `Bearer ${this.token}` } : {}),
        ...(body ? { "Content-Type": "application/json" } : {}),
      },
      ...(body ? { body: JSON.stringify(body) } : {}),
      signal: AbortSignal.timeout(60_000),
    });
    if (!response.ok) {
      const error = await response.json().catch(() => ({}));
      throw new Error(
        `GitHub ${response.status}: ${error.message || response.statusText}${response.status === 403 ? " Check token permissions, branch rules, or API rate limits." : ""}`,
      );
    }
    return response.json() as Promise<T>;
  }
  user() {
    return this.request<GitHubUser>("/user");
  }
  async repositories(): Promise<Repository[]> {
    const repositories: Repository[] = [];
    for (let page = 1; ; page++) {
      const batch = await this.request<Repository[]>(
        `/user/repos?per_page=100&sort=updated&page=${page}`,
      );
      repositories.push(...batch);
      if (batch.length < 100) return repositories;
    }
  }
  async download(address: string): Promise<Workspace> {
    const path = repoPath(address);
    const repository = await this.request<Repository>(path);
    const ref = await this.request<{ object: { sha: string } }>(
      `${path}/git/ref/heads/${segment(repository.default_branch)}`,
    );
    const commit = await this.request<{ tree: { sha: string } }>(
      `${path}/git/commits/${ref.object.sha}`,
    );
    const tree = await this.request<{ tree: TreeEntry[]; truncated: boolean }>(
      `${path}/git/trees/${commit.tree.sha}?recursive=1`,
    );
    if (tree.truncated)
      throw new Error(
        "This repository is too large to download completely. Use a smaller notes repository.",
      );
    const markdown = tree.tree.filter(
      (e) =>
        e.type === "blob" &&
        (e.mode === "100644" || e.mode === "100755") &&
        isMarkdown(e.path) &&
        visiblePath(e.path),
    );
    if (
      markdown.length > 1000 ||
      markdown.reduce((sum, e) => sum + (e.size ?? 0), 0) > 20_000_000
    ) {
      throw new Error(
        "This web MVP supports up to 1,000 notes and 20 MB of Markdown per repository.",
      );
    }
    const notes: Workspace["notes"] = [];
    // Limit concurrent requests to avoid flooding GitHub for larger notebooks.
    for (let start = 0; start < markdown.length; start += 5) {
      notes.push(
        ...(await Promise.all(
          markdown.slice(start, start + 5).map(async (entry) => {
            const blob = await this.request<{
              content: string;
              encoding: string;
            }>(`${path}/git/blobs/${entry.sha}`);
            if (blob.encoding !== "base64")
              throw new Error(`Unsupported encoding for ${entry.path}.`);
            const bytes = Uint8Array.from(
              atob(blob.content.replace(/\s/g, "")),
              (char) => char.charCodeAt(0),
            );
            const content = new TextDecoder("utf-8", {
              fatal: true,
              ignoreBOM: true,
            }).decode(bytes);
            return { path: entry.path, content, base: content };
          }),
        )),
      );
    }
    return {
      id: String(repository.id),
      fullName: repository.full_name,
      branch: repository.default_branch,
      head: ref.object.sha,
      tree: commit.tree.sha,
      entries: tree.tree,
      notes,
      directories: tree.tree
        .filter((e) => e.type === "tree" && visiblePath(e.path))
        .map((e) => e.path),
      updatedAt: new Date().toISOString(),
    };
  }
  async sync(
    workspace: Workspace,
    message: string,
    name: string,
    email: string,
  ): Promise<Workspace> {
    if (!this.token)
      throw new Error("Connect your GitHub account before syncing.");
    if (
      !message.trim() ||
      !name.trim() ||
      !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.trim())
    )
      throw new Error("Enter a commit message, author name, and valid email.");
    const changed = changes(workspace);
    if (!changed.length) return workspace;
    const path = repoPath(workspace.fullName);
    const refPath = `${path}/git/refs/heads/${segment(workspace.branch)}`;
    const current = await this.request<{ object: { sha: string } }>(
      `${path}/git/ref/heads/${segment(workspace.branch)}`,
    );
    if (current.object.sha !== workspace.head)
      throw new Error(
        "The remote branch has changed. Your edits are safe locally. Export your edits and reconcile them outside GitNote before adding a fresh copy.",
      );
    const tree = await this.request<{ sha: string }>(
      `${path}/git/trees`,
      "POST",
      {
        base_tree: workspace.tree,
        tree: changed.map((note) => ({
          path: note.path,
          mode:
            workspace.entries.find((entry) => entry.path === note.path)?.mode ??
            "100644",
          type: "blob",
          content: note.content,
        })),
      },
    );
    const commit = await this.request<{ sha: string }>(
      `${path}/git/commits`,
      "POST",
      {
        message: message.trim(),
        tree: tree.sha,
        parents: [workspace.head],
        author: { name: name.trim(), email: email.trim() },
      },
    );
    // GitHub rejects a non-fast-forward update if another writer wins the race.
    await this.request(refPath, "PATCH", { sha: commit.sha, force: false });
    return {
      ...workspace,
      head: commit.sha,
      tree: tree.sha,
      notes: workspace.notes.map((note) => ({ ...note, base: note.content })),
      updatedAt: new Date().toISOString(),
    };
  }
}

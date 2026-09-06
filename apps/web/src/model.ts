export interface Note {
  path: string;
  content: string;
  base: string | null;
}
export interface TreeEntry {
  path: string;
  type: string;
  mode: string;
  sha: string;
  size?: number;
}
export interface Workspace {
  id: string;
  fullName: string;
  branch: string;
  head: string;
  tree: string;
  entries: TreeEntry[];
  notes: Note[];
  directories: string[];
  updatedAt: string;
}
export interface GitHubUser {
  id: number;
  login: string;
}
export interface Repository {
  id: number;
  full_name: string;
  default_branch: string;
  private: boolean;
  description: string | null;
}
export const changes = (workspace: Workspace) =>
  workspace.notes.filter((note) => note.content !== note.base);
export const parentPath = (path: string) =>
  path.split("/").slice(0, -1).join("/");
export const fileName = (path: string) => path.split("/").at(-1)!;
export const isMarkdown = (path: string) => /\.(md|markdown)$/i.test(path);
export const visiblePath = (path: string) =>
  path.split("/").every((part) => !part.startsWith("."));

export function repositoryAddress(input: string): string {
  const value = input
    .trim()
    .replace(/^https:\/\/github\.com\//, "")
    .replace(/\/+$/, "")
    .replace(/\.git$/, "");
  if (
    !/^[a-zA-Z0-9_-]+\/[a-zA-Z0-9_.-]+$/.test(value) ||
    value.split("/").some((p) => p === "." || p === "..")
  ) {
    throw new Error("Use owner/repository or a GitHub HTTPS repository URL.");
  }
  return value;
}

export function safePath(input: string, markdown = false): string {
  let value = input.trim();
  if (
    !value ||
    value
      .split("/")
      .some(
        (part) =>
          !part ||
          part.startsWith(".") ||
          /[\\<>:"|?*\u0000-\u001f\u007f]/.test(part),
      )
  ) {
    throw new Error(
      "Use a relative path without hidden folders, parent paths, or special characters.",
    );
  }
  if (markdown && !isMarkdown(value)) {
    if (fileName(value).includes("."))
      throw new Error("Notes must end in .md or .markdown.");
    value += ".md";
  }
  if (value.length > 512)
    throw new Error("The path must be 512 characters or fewer.");
  return value;
}

export function addPath(
  workspace: Workspace,
  input: string,
  directory: boolean,
): Workspace {
  const path = safePath(input, !directory);
  const files = new Set([
    ...workspace.entries.filter((e) => e.type !== "tree").map((e) => e.path),
    ...workspace.notes.map((n) => n.path),
  ]);
  if (files.has(path) || workspace.directories.includes(path))
    throw new Error("That path already exists.");
  const parents = path
    .split("/")
    .slice(0, -1)
    .map((_, i, parts) => parts.slice(0, i + 1).join("/"));
  if (parents.some((p) => files.has(p)))
    throw new Error("A parent path is already a file.");
  return {
    ...workspace,
    directories: [
      ...new Set([
        ...workspace.directories,
        ...parents,
        ...(directory ? [path] : []),
      ]),
    ].sort(),
    notes: directory
      ? workspace.notes
      : [...workspace.notes, { path, content: "", base: null }].sort((a, b) =>
          a.path.localeCompare(b.path),
        ),
  };
}

// These constructs are intentionally source-only so a rich-text round trip cannot silently discard them.
export function requiresSource(markdown: string): boolean {
  return (
    /^\ufeff?(---|\+\+\+)\s*\r?\n/.test(markdown) ||
    /<\/?[a-zA-Z!][^>]*>|!\[|^\s*\[[^\]]+\]:|^\s*(?:>\s*)*(?:[-*+]|\d+[.)])\s+\[[ xX]\]|^\s*\|?.*\|.*\r?\n\s*\|?\s*:?-+/m.test(
      markdown,
    )
  );
}

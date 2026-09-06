import { describe, expect, it } from "vitest";
import {
  addPath,
  changes,
  repositoryAddress,
  requiresSource,
  safePath,
  type Workspace,
} from "../src/model";
export const fixture: Workspace = {
  id: "1",
  fullName: "writer/notes",
  branch: "main",
  head: "head1",
  tree: "tree1",
  entries: [
    { path: "README.md", mode: "100644", type: "blob", sha: "blob1" },
    { path: "image.png", mode: "100644", type: "blob", sha: "blob2" },
  ],
  notes: [{ path: "README.md", content: "# Hello\n", base: "# Hello\n" }],
  directories: [],
  updatedAt: "2026-01-01T00:00:00Z",
};
describe("repository addresses and paths", () => {
  it("accepts GitHub HTTPS URLs and owner/name", () => {
    expect(repositoryAddress(" https://github.com/writer/notes.git/ ")).toBe(
      "writer/notes",
    );
    expect(repositoryAddress("writer/notes")).toBe("writer/notes");
  });
  it.each([
    "https://evil.test/writer/notes",
    "writer/notes/tree/main",
    "../notes",
    "writer/..",
    "writer/notes?token=secret",
    "git@github.com:writer/notes",
  ])("rejects unsafe address %s", (value) =>
    expect(() => repositoryAddress(value)).toThrow(),
  );
  it.each([
    "../note",
    "/note",
    ".git/config",
    "folder//note",
    "folder/..",
    "folder\\note",
    "bad\u0000name",
    "folder/",
    "folder/a.txt",
  ])("rejects unsafe note path %s", (value) =>
    expect(() => safePath(value, true)).toThrow(),
  );
  it("allows Unicode and appends Markdown extension", () =>
    expect(safePath("idéer/日本語", true)).toBe("idéer/日本語.md"));
  it("detects collisions with files and folders, including non-Markdown files", () => {
    expect(() => addPath(fixture, "README.md/note", false)).toThrow("parent");
    expect(() => addPath(fixture, "image.png", true)).toThrow("exists");
    expect(() =>
      addPath({ ...fixture, directories: ["draft.md"] }, "draft.md", false),
    ).toThrow("exists");
  });
  it("creates parent folders but only counts notes as changes", () => {
    const folder = addPath(fixture, "ideas/drafts", true);
    expect(changes(folder)).toHaveLength(0);
    const note = addPath(folder, "ideas/drafts/today", false);
    expect(note.directories).toEqual(["ideas", "ideas/drafts"]);
    expect(changes(note)).toEqual([
      { path: "ideas/drafts/today.md", content: "", base: null },
    ]);
  });
  it("clears dirty state when an edit is reverted", () => {
    expect(
      changes({
        ...fixture,
        notes: [{ ...fixture.notes[0], content: "Changed" }],
      }),
    ).toHaveLength(1);
    expect(changes(fixture)).toHaveLength(0);
  });
  it.each([
    "---\ntitle: Hello\n---\n",
    "![image](photo.png)",
    "<script>alert(1)</script>",
    "- [ ] Task",
    "1. [ ] Ordered task",
    "> - [x] Nested task",
    "| A | B |\n| - | - |\n| 1 | 2 |",
    "[ref]: https://example.com",
    "| A | B |\n| --- | --- |\n| 1 | 2 |",
  ])("uses source for unsupported constructs: %s", (value) =>
    expect(requiresSource(value)).toBe(true),
  );
  it("allows common rich Markdown", () =>
    expect(
      requiresSource(
        "# Hi\n\n**Bold** and [link](https://example.com)\n\n- Item",
      ),
    ).toBe(false));
});

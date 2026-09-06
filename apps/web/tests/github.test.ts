import { describe, expect, it, vi } from "vitest";
import { GitHubClient } from "../src/github";
import type { Workspace } from "../src/model";
const workspace: Workspace = {
  id: "1",
  fullName: "writer/notes",
  branch: "notes/main",
  head: "old",
  tree: "base",
  entries: [],
  directories: [],
  notes: [{ path: "hello.md", content: "# Changed 🌱", base: "# Hello" }],
  updatedAt: "",
};
function transport(responses: unknown[]) {
  return vi.fn<typeof fetch>(
    async () =>
      new Response(JSON.stringify(responses.shift()), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
  );
}
describe("GitHub integration", () => {
  it("commits all changes over the base tree, then updates the branch without force", async () => {
    const fetch = transport([
      { object: { sha: "old" } },
      { sha: "newtree" },
      { sha: "newcommit" },
      {},
    ]);
    const result = await new GitHubClient("token", fetch).sync(
      workspace,
      " Update notes ",
      "Writer",
      "writer@example.com",
    );
    expect(fetch.mock.calls[0][0]).toContain("heads/notes%2Fmain");
    expect(JSON.parse(fetch.mock.calls[1][1]!.body as string)).toEqual({
      base_tree: "base",
      tree: [
        {
          path: "hello.md",
          mode: "100644",
          type: "blob",
          content: "# Changed 🌱",
        },
      ],
    });
    expect(JSON.parse(fetch.mock.calls[2][1]!.body as string)).toMatchObject({
      parents: ["old"],
      message: "Update notes",
      tree: "newtree",
    });
    expect(JSON.parse(fetch.mock.calls[3][1]!.body as string)).toEqual({
      sha: "newcommit",
      force: false,
    });
    expect(result.notes[0].base).toBe("# Changed 🌱");
    expect(result.head).toBe("newcommit");
    expect(workspace.notes[0].base).toBe("# Hello");
  });
  it("refuses to write if the remote has advanced", async () => {
    const fetch = transport([{ object: { sha: "other" } }]);
    await expect(
      new GitHubClient("token", fetch).sync(
        workspace,
        "Update",
        "Writer",
        "writer@example.com",
      ),
    ).rejects.toThrow("remote branch has changed");
    expect(fetch).toHaveBeenCalledTimes(1);
  });
  it("does not mark edits clean when a racing update is rejected", async () => {
    const fetch = transport([
      { object: { sha: "old" } },
      { sha: "tree" },
      { sha: "commit" },
    ]);
    fetch
      .mockImplementationOnce(
        async () => new Response(JSON.stringify({ object: { sha: "old" } })),
      )
      .mockImplementationOnce(
        async () => new Response(JSON.stringify({ sha: "tree" })),
      )
      .mockImplementationOnce(
        async () => new Response(JSON.stringify({ sha: "commit" })),
      )
      .mockImplementationOnce(
        async () =>
          new Response(
            JSON.stringify({ message: "Update is not a fast forward" }),
            { status: 422 },
          ),
      );
    await expect(
      new GitHubClient("token", fetch).sync(
        workspace,
        "Update",
        "Writer",
        "writer@example.com",
      ),
    ).rejects.toThrow("422");
    expect(workspace.head).toBe("old");
    expect(workspace.notes[0].base).toBe("# Hello");
  });
  it("requires authentication and valid author data before writing", async () => {
    const fetch = transport([]);
    await expect(
      new GitHubClient("", fetch).sync(
        workspace,
        "Update",
        "Writer",
        "writer@example.com",
      ),
    ).rejects.toThrow("Connect");
    await expect(
      new GitHubClient("token", fetch).sync(workspace, "", "Writer", "bad"),
    ).rejects.toThrow("valid");
    expect(fetch).not.toHaveBeenCalled();
  });
  it("downloads Markdown as UTF-8, preserving originals and excluding hidden files and symlinks", async () => {
    const original = "# Héllo 🌱\r\n";
    const fetch = transport([
      { id: 1, full_name: "writer/notes", default_branch: "main" },
      { object: { sha: "head" } },
      { tree: { sha: "tree" } },
      {
        truncated: false,
        tree: [
          { path: "README.md", type: "blob", mode: "100644", sha: "b1" },
          { path: ".hidden/a.md", type: "blob", mode: "100644", sha: "b2" },
          { path: "link.md", type: "blob", mode: "120000", sha: "b3" },
          { path: "image.png", type: "blob", mode: "100644", sha: "b4" },
        ],
      },
      { encoding: "base64", content: Buffer.from(original).toString("base64") },
    ]);
    const result = await new GitHubClient("", fetch).download("writer/notes");
    expect(result.notes).toEqual([
      { path: "README.md", content: original, base: original },
    ]);
    expect(result.entries).toHaveLength(4);
    expect(fetch).toHaveBeenCalledTimes(5);
    expect(fetch.mock.calls[0][1]!.headers).not.toHaveProperty("Authorization");
  });
  it("rejects incomplete Git trees before storing any notes", async () => {
    const fetch = transport([
      { id: 1, full_name: "writer/notes", default_branch: "main" },
      { object: { sha: "head" } },
      { tree: { sha: "tree" } },
      { truncated: true, tree: [] },
    ]);
    await expect(
      new GitHubClient("", fetch).download("writer/notes"),
    ).rejects.toThrow("too large");
  });
  it("paginates account repository discovery", async () => {
    const fetch = transport([
      Array.from({ length: 100 }, (_, id) => ({ id })),
      [{ id: 101 }],
    ]);
    expect(await new GitHubClient("token", fetch).repositories()).toHaveLength(
      101,
    );
    expect(fetch.mock.calls[1][0]).toContain("page=2");
  });
});

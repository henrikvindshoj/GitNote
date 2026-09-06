import "fake-indexeddb/auto";
import { expect, it } from "vitest";
import { loadWorkspaces, removeWorkspace, saveWorkspace } from "../src/storage";
import type { Workspace } from "../src/model";
it("persists note bodies and their baselines, updates a copy, and removes only that copy", async () => {
  const workspace: Workspace = {
    id: "a",
    fullName: "writer/a",
    branch: "main",
    head: "head",
    tree: "tree",
    entries: [],
    notes: [{ path: "a.md", content: "edited", base: "original" }],
    directories: ["empty"],
    updatedAt: "",
  };
  await saveWorkspace(workspace);
  await saveWorkspace({ ...workspace, id: "b" });
  expect(await loadWorkspaces()).toHaveLength(2);
  await saveWorkspace({
    ...workspace,
    notes: [{ ...workspace.notes[0], content: "edited twice" }],
  });
  expect((await loadWorkspaces())[0].notes[0]).toEqual({
    path: "a.md",
    content: "edited twice",
    base: "original",
  });
  await removeWorkspace("a");
  expect((await loadWorkspaces()).map((w) => w.id)).toEqual(["b"]);
});

import { test, expect, type Page } from "@playwright/test";

async function mockGitHub(page: Page) {
  const writes: { method: string; path: string; body: unknown }[] = [];
  await page.route("https://api.github.com/**", async (route) => {
    const request = route.request();
    const path = new URL(request.url()).pathname;
    const method = request.method();
    if (method !== "GET")
      writes.push({ method, path, body: request.postDataJSON() });
    let body: unknown;
    if (path === "/user") body = { id: 7, login: "writer" };
    else if (path === "/user/repos")
      body = [
        {
          id: 1,
          full_name: "writer/notes",
          default_branch: "main",
          private: true,
        },
      ];
    else if (path === "/repos/writer/notes")
      body = { id: 1, full_name: "writer/notes", default_branch: "main" };
    else if (path.endsWith("/git/ref/heads/main"))
      body = { object: { sha: "head1" } };
    else if (path.endsWith("/git/commits/head1"))
      body = { tree: { sha: "tree1" } };
    else if (path.endsWith("/git/trees/tree1"))
      body = {
        truncated: false,
        tree: [
          { path: "README.md", type: "blob", mode: "100644", sha: "blob1" },
          { path: "ideas", type: "tree", mode: "040000", sha: "folder1" },
          {
            path: "ideas/advanced.md",
            type: "blob",
            mode: "100644",
            sha: "blob2",
          },
          { path: "image.png", type: "blob", mode: "100644", sha: "image1" },
        ],
      };
    else if (path.endsWith("/git/blobs/blob1"))
      body = {
        encoding: "base64",
        content: Buffer.from(
          "# A place for ideas\n\nStart writing here.\n",
        ).toString("base64"),
      };
    else if (path.endsWith("/git/blobs/blob2"))
      body = {
        encoding: "base64",
        content: Buffer.from(
          "---\ntitle: Metadata\n---\n\n# Advanced note\n",
        ).toString("base64"),
      };
    else if (path.endsWith("/git/trees") && method === "POST")
      body = { sha: "newtree" };
    else if (path.endsWith("/git/commits") && method === "POST")
      body = { sha: "newcommit123" };
    else if (method === "PATCH") body = { object: { sha: "newcommit123" } };
    else
      return route.fulfill({
        status: 404,
        json: { message: `Unexpected path ${path}` },
      });
    await route.fulfill({ json: body });
  });
  return writes;
}
async function addRepository(page: Page) {
  await page.goto("/");
  await page.getByRole("button", { name: "Add your first repository" }).click();
  await page.getByLabel("Repository address").fill("writer/notes");
  await page
    .getByRole("dialog")
    .getByRole("button", { name: "Add repository", exact: true })
    .click();
  await expect(
    page.getByRole("heading", { name: "notes", exact: true }),
  ).toBeVisible();
}

test("downloads, edits rich text, reviews changes, and keeps exact source across reloads", async ({
  page,
}, testInfo) => {
  await mockGitHub(page);
  await addRepository(page);
  await page.getByRole("button", { name: /README.md/ }).click();
  const editor = page.getByRole("textbox", { name: "Note content" });
  await expect(editor).toContainText("A place for ideas");
  await page.screenshot({
    path: testInfo.outputPath("desktop.png"),
    fullPage: true,
  });
  await expect(page.getByText("No uncommitted changes")).toBeVisible();
  await editor.click();
  await page.keyboard.press("ControlOrMeta+End");
  await page.keyboard.type(" An idea for tomorrow.");
  await expect(page.getByText("Saved on this device")).toBeVisible();
  await page.getByRole("button", { name: /^Changes/ }).click();
  await expect(page.getByText("1 changed file waiting")).toBeVisible();
  await page.locator("summary").click();
  await expect(page.locator(".diff")).toContainText("An idea for tomorrow.");
  await page.reload();
  await page.getByRole("button", { name: /README.md/ }).click();
  await expect(
    page.getByRole("textbox", { name: "Note content" }),
  ).toContainText("An idea for tomorrow.");
  await page.getByRole("button", { name: "Source", exact: true }).click();
  const source = "# Exact Markdown\r\n\r\n**Keep this**\n";
  await page.getByLabel("Markdown source").fill(source);
  await expect(page.getByText("Saved on this device")).toBeVisible();
  await page.reload();
  await page.getByRole("button", { name: /README.md/ }).click();
  await page.getByRole("button", { name: "Source", exact: true }).click();
  await expect(page.getByLabel("Markdown source")).toHaveValue(
    source.replace(/\r\n/g, "\n"),
  );
});

test("creates nested notes and folders, searches, and preserves advanced Markdown", async ({
  page,
}) => {
  await mockGitHub(page);
  await addRepository(page);
  await page.getByRole("button", { name: "New folder", exact: true }).click();
  await page.getByLabel("Folder path").fill("journal/2026");
  await page.getByRole("button", { name: "Create folder" }).click();
  await page.getByRole("button", { name: /journal/ }).click();
  await page.getByRole("button", { name: /2026/ }).click();
  await page
    .getByRole("button", { name: "New note", exact: true })
    .first()
    .click();
  await page.getByLabel("Note path").fill("September");
  await page.getByRole("button", { name: "Create note", exact: true }).click();
  await expect(page.locator(".editor-heading")).toContainText(
    "journal/2026/September.md",
  );
  await page.getByLabel("Search this folder").fill("absent");
  await expect(page.getByText("No matching notes")).toBeVisible();
  await page.getByLabel("Search this folder").fill("");
  await page.getByRole("button", { name: "Parent folder" }).click();
  await page.getByRole("button", { name: "Parent folder" }).click();
  await page
    .getByRole("button", { name: /ideas/ })
    .filter({ has: page.locator("svg") })
    .first()
    .click();
  await page.getByRole("button", { name: /advanced.md/ }).click();
  await expect(page.getByLabel("Markdown source")).toHaveValue(
    "---\ntitle: Metadata\n---\n\n# Advanced note\n",
  );
  await expect(
    page.getByRole("button", { name: "Write", exact: true }),
  ).toBeDisabled();
});

test("connects, discovers repositories, syncs one commit, and never persists the token", async ({
  page,
}) => {
  const writes = await mockGitHub(page);
  await addRepository(page);
  await page.getByRole("button", { name: /GitHub account/ }).click();
  await page.getByLabel("Personal access token").fill("test-token-not-real");
  await page
    .getByRole("button", { name: "Connect account", exact: true })
    .click();
  await expect(page.getByText("Connected as writer.")).toBeVisible();
  await page
    .getByRole("button", { name: "Add repository", exact: true })
    .first()
    .click();
  await page.getByRole("button", { name: "Load repositories" }).click();
  await expect(
    page.getByRole("button", { name: /writer\/notes Private/ }),
  ).toBeDisabled();
  await page.getByRole("button", { name: "Close dialog" }).click();
  await page.getByRole("button", { name: /README.md/ }).click();
  await page.getByRole("button", { name: "Source", exact: true }).click();
  await page.getByLabel("Markdown source").fill("# Synced note\n");
  await expect(page.getByText("Saved on this device")).toBeVisible();
  await page.getByRole("button", { name: /^Sync changes/ }).click();
  await page.getByRole("button", { name: "Commit and sync" }).click();
  await expect(page.getByText("Synced 1 note to GitHub.")).toBeVisible();
  expect(writes).toHaveLength(3);
  expect(writes[0].body).toEqual({
    base_tree: "tree1",
    tree: [
      {
        path: "README.md",
        mode: "100644",
        type: "blob",
        content: "# Synced note\n",
      },
    ],
  });
  expect(writes[2].body).toEqual({ sha: "newcommit123", force: false });
  expect(
    await page.evaluate(() =>
      JSON.stringify({ ...localStorage, ...sessionStorage }),
    ),
  ).not.toContain("test-token");
  await page.reload();
  await expect(
    page.getByRole("button", { name: /GitHub account/ }),
  ).toBeVisible();
  await page.getByRole("button", { name: /README.md/ }).click();
  await expect(page.getByText("No uncommitted changes")).toBeVisible();
});

test("works offline after the application shell is cached", async ({
  page,
  context,
}) => {
  await mockGitHub(page);
  await addRepository(page);
  await page.evaluate(async () => {
    await navigator.serviceWorker.ready;
  });
  await page.reload();
  await expect(page.getByRole("button", { name: /README.md/ })).toBeVisible();
  await context.setOffline(true);
  await page.reload();
  await expect(page.getByText("Offline · keep writing")).toBeVisible();
  await page.getByRole("button", { name: /README.md/ }).click();
  await page.getByRole("button", { name: "Source", exact: true }).click();
  await page.getByLabel("Markdown source").fill("# Written offline");
  await expect(page.getByText("Saved on this device")).toBeVisible();
  await page.reload();
  await page.getByRole("button", { name: /README.md/ }).click();
  await expect(
    page.getByRole("textbox", { name: "Note content" }),
  ).toContainText("Written offline");
  await expect(
    page.getByRole("button", { name: /^Sync changes/ }),
  ).toBeDisabled();
});

test("mobile navigation and removal confirmation work without horizontal overflow", async ({
  page,
}, testInfo) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await mockGitHub(page);
  await addRepository(page);
  await page.getByRole("button", { name: /README.md/ }).click();
  await expect(
    page.getByRole("textbox", { name: "Note content" }),
  ).toBeVisible();
  await page.screenshot({
    path: testInfo.outputPath("mobile.png"),
    fullPage: true,
  });
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
  ).toBe(true);
  await page.getByRole("button", { name: "Back to notes" }).click();
  await expect(page.getByLabel("Search this folder")).toBeVisible();
  await page
    .getByRole("button", { name: "Remove local copy", exact: true })
    .click();
  await page.getByRole("button", { name: "Keep local copy" }).click();
  await expect(
    page.getByRole("heading", { name: "notes", exact: true }),
  ).toBeVisible();
  await page
    .getByRole("button", { name: "Remove local copy", exact: true })
    .click();
  await page
    .getByRole("dialog")
    .getByRole("button", { name: "Remove local copy", exact: true })
    .click();
  await expect(
    page.getByRole("button", { name: "Add your first repository" }),
  ).toBeVisible();
});

test("refuses a changed remote branch and keeps edits available for export", async ({
  page,
}) => {
  await mockGitHub(page);
  await addRepository(page);
  await page.getByRole("button", { name: /GitHub account/ }).click();
  await page.getByLabel("Personal access token").fill("test-token-not-real");
  await page
    .getByRole("button", { name: "Connect account", exact: true })
    .click();
  await page.getByRole("button", { name: /README.md/ }).click();
  await page.getByRole("button", { name: "Source", exact: true }).click();
  await page.getByLabel("Markdown source").fill("# Keep my edits");
  await page.route("**/git/ref/heads/main", (route) =>
    route.fulfill({ json: { object: { sha: "someone-elses-commit" } } }),
  );
  await page.getByRole("button", { name: /^Sync changes/ }).click();
  await page.getByRole("button", { name: "Commit and sync" }).click();
  await expect(page.getByRole("alert")).toContainText(
    "remote branch has changed",
  );
  await page.getByRole("button", { name: "Close dialog" }).click();
  await expect(page.getByLabel("Markdown source")).toHaveValue(
    "# Keep my edits",
  );
  const download = page.waitForEvent("download");
  await page.getByRole("button", { name: "Download Markdown" }).click();
  expect((await download).suggestedFilename()).toBe("README.md");
  await page.reload();
  await page.getByRole("button", { name: /README.md/ }).click();
  await expect(
    page.getByRole("textbox", { name: "Note content" }),
  ).toContainText("Keep my edits");
});

test("reports failed persistence without claiming edits were saved", async ({
  page,
}) => {
  await mockGitHub(page);
  await addRepository(page);
  await page.evaluate(() => {
    IDBObjectStore.prototype.put = function () {
      throw new DOMException("Storage full", "QuotaExceededError");
    };
  });
  await page.getByRole("button", { name: /README.md/ }).click();
  await page.getByRole("button", { name: "Source", exact: true }).click();
  await page.getByLabel("Markdown source").fill("# Still in memory");
  await expect(page.getByRole("alert")).toContainText("Could not save");
  await expect(page.getByText("Not saved — export your notes")).toBeVisible();
  await expect(page.getByLabel("Markdown source")).toHaveValue(
    "# Still in memory",
  );
});

test("prevents a second tab from overwriting the working copy", async ({
  page,
  context,
}) => {
  await mockGitHub(page);
  await addRepository(page);
  const second = await context.newPage();
  await second.goto("/");
  await expect(second.getByRole("alert")).toContainText("open in another tab");
  await expect(
    second.getByRole("button", { name: "Add your first repository" }),
  ).toBeDisabled();
  await page.close();
  await second.reload();
  await expect(
    second.getByRole("heading", { name: "notes", exact: true }),
  ).toBeVisible();
});

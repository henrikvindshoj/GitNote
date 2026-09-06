import { test, expect } from "@playwright/test";

const payloads = [
  '<img src="https://attacker.invalid/pixel" onerror="window.__securityXSS=1">',
  '<svg onload="window.__securityXSS=1"></svg>',
  "[click](javascript:window.__securityXSS=1)",
  "[click](data:text/html,<script>window.__securityXSS=1</script>)",
  "![tracking](https://attacker.invalid/pixel)",
  "[click](java&#x73;cript:alert(1))",
  '<iframe srcdoc="<script>window.__securityXSS=1</script>"></iframe>',
];

for (const [index, content] of payloads.entries()) {
  test(`untrusted Markdown payload ${index + 1} stays inert`, async ({
    page,
  }) => {
    const external: string[] = [];
    await page.route("https://attacker.invalid/**", async (route) => {
      external.push(route.request().url());
      await route.abort();
    });
    await page.goto("/");
    await page.evaluate(async (content) => {
      const db = await new Promise<IDBDatabase>((resolve, reject) => {
        const request = indexedDB.open("gitnote-web", 1);
        request.onupgradeneeded = () =>
          request.result.createObjectStore("workspaces", { keyPath: "id" });
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error);
      });
      await new Promise<void>((resolve, reject) => {
        const tx = db.transaction("workspaces", "readwrite");
        tx.objectStore("workspaces").put({
          id: "security-fixture",
          fullName: "test/security",
          branch: "main",
          head: "fixture",
          tree: "fixture",
          entries: [],
          notes: [{ path: "payload.md", content, base: content }],
          directories: [],
          updatedAt: new Date().toISOString(),
        });
        tx.oncomplete = () => resolve();
        tx.onerror = () => reject(tx.error);
      });
      db.close();
    }, content);
    await page.reload();
    await page.getByRole("button", { name: /payload.md/ }).click();
    await expect(page.locator(".editor-pane")).toBeVisible();
    expect(
      await page.evaluate(
        () => (window as unknown as Record<string, unknown>).__securityXSS,
      ),
    ).toBeUndefined();
    await expect(
      page.locator(
        ".editor-pane img, .editor-pane iframe, .editor-pane script",
      ),
    ).toHaveCount(0);
    const hrefs = await page
      .locator(".tiptap a")
      .evaluateAll((nodes) =>
        nodes.map((node) => node.getAttribute("href") || ""),
      );
    expect(
      hrefs.some((href) => /^(javascript|data|vbscript):/i.test(href)),
    ).toBe(false);
    expect(external).toEqual([]);
  });
}

test("production preview enforces headers and blocks executable inline content", async ({
  page,
  request,
}) => {
  const response = await request.get("/");
  const headers = response.headers();
  expect(headers["content-security-policy"]).toContain(
    "frame-ancestors 'none'",
  );
  expect(headers["content-security-policy"]).toContain(
    "connect-src 'self' https://api.github.com",
  );
  expect(headers["x-content-type-options"]).toBe("nosniff");
  expect(headers["referrer-policy"]).toBe("no-referrer");
  await page.goto("/");
  await page.evaluate(() => {
    const script = document.createElement("script");
    script.textContent = "window.__securityInline = true";
    document.body.append(script);
  });
  expect(
    await page.evaluate(
      () => (window as unknown as Record<string, unknown>).__securityInline,
    ),
  ).toBeUndefined();
});

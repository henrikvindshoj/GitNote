const CACHE_NAME = "gitnote-shell-v1";
const CORE_ASSETS = ["/", "/index.html", "/icon.svg", "/manifest.webmanifest"];

async function cacheApplicationShell() {
  const cache = await caches.open(CACHE_NAME);
  const response = await fetch("/index.html", { cache: "no-store" });
  if (!response.ok)
    throw new Error("Could not load the GitNote application shell");

  const html = await response.clone().text();
  await cache.put("/index.html", response.clone());
  await cache.put("/", response);

  const generatedAssets = [...html.matchAll(/(?:src|href)="(\/[^"?#]+)"/g)]
    .map((match) => match[1])
    .filter((path) => path.startsWith("/assets/"));
  await cache.addAll([
    ...new Set([...CORE_ASSETS.slice(2), ...generatedAssets]),
  ]);
}

self.addEventListener("install", (event) => {
  event.waitUntil(cacheApplicationShell().then(() => self.skipWaiting()));
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    Promise.all([
      caches
        .keys()
        .then((names) =>
          Promise.all(
            names
              .filter((name) => name !== CACHE_NAME)
              .map((name) => caches.delete(name)),
          ),
        ),
      self.clients.claim(),
    ]),
  );
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  const url = new URL(request.url);
  if (request.method !== "GET" || url.origin !== self.location.origin) return;

  if (request.mode === "navigate") {
    event.respondWith(
      fetch(request).catch(async () => {
        const cache = await caches.open(CACHE_NAME);
        return (await cache.match("/index.html")) || Response.error();
      }),
    );
    return;
  }

  event.respondWith(
    caches.match(request).then(async (cached) => {
      if (cached) return cached;

      const response = await fetch(request);
      if (response.ok) {
        const cache = await caches.open(CACHE_NAME);
        await cache.put(request, response.clone());
      }
      return response;
    }),
  );
});

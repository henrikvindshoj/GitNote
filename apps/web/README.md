# GitNote Web

This boundary is reserved for the future web client.

A browser cannot expose a normal persistent local Git folder as freely as a native client, so its product scope should be decided independently. Likely options are GitHub API-based browsing/editing, the File System Access API where supported, or a companion experience backed by the optional API service.

Keep generated API clients and web-only packages inside this folder. Platform-neutral contracts belong in `packages/contracts`.

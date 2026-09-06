# GitNote security assessment — 6 September 2026

## Remediation status — 6 September 2026

The findings below record the original assessment. The working tree now contains fixes for GN-01 through GN-05, with the following scope:

- **GN-01 fixed:** directory-relative no-follow file access, safe workspace names, rejection of hidden paths/symlinks/hard links, bounded reads, and atomic writes. Native simulator tests cover outside-workspace links, broken links, `.git` aliases, stale scanned paths, normal saves, and oversized notes. The standalone harness now asserts rejection rather than exploitation.
- **GN-02 fixed:** validate expected repository identity before cloning or committing/syncing, validate libgit2’s resolved origin and push URLs (including config rewrites), bind credentials to that repository, reject invalid TLS certificates, and disable initial redirects. A loopback test confirms an untrusted remote receives no connection; additional tests reject push-URL and `insteadOf` changes. Test-only local file remotes require explicit opt-in and are compiled out of Release builds.
- **GN-03 reduced:** fine-grained tokens restricted to selected repositories are the recommended iOS login. New optional OAuth grants request `public_repo` rather than `repo`. Token storage and updates use `WhenUnlockedThisDeviceOnly`; validated legacy tokens are migrated on refresh. Existing broad grants cannot be downgraded locally: users must revoke them in GitHub settings. Account links and documentation explain this and distinguish disconnect from revocation/local-data deletion.
- **GN-04 bounded:** 2 MB notes, 10,000 visible entries, 100 MB transfer and checkout budgets, 20,000 Git objects, 10,000 checkout files, and 20 MB per checkout file. Object headers are checked before checkout; an actual oversized-clone regression confirms rejection and partial-clone cleanup. Cancellation/deadline checks run at libgit2 progress boundaries. Images are limited to 8 MB encoded, 40 million source pixels, and a 1,600-pixel thumbnail dimension. These are application safeguards, not a hard memory/disk sandbox for all native parser internals or an immediate timeout on stalled network I/O.
- **GN-05 configured:** production builds emit `_headers`; preview uses the same policy except HSTS. Browser tests verify CSP response headers and blocked inline scripts while existing editor/export/offline/sync tests continue to pass. Production enforcement still depends on the future host honoring the generated headers.
- **CI hardening:** least-privilege workflow permissions, immutable action commits, weekly npm/action update PRs, npm audit, and signed simulator XCTest. iOS CI selects Xcode 26.6 on macOS 26, matching the tested local compiler and the [official runner image](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md). CI itself has not been dispatched from this workspace.

Validation: 35 signed iOS simulator tests, 38 web unit tests, and 16 production-build Chromium tests passed. The standalone Swift symlink regression and signed Release simulator build also passed. Workflow YAML parsing, web formatting, and diff whitespace checks passed. The simulator tests include Keychain round-trip, remote rejection, clone limits, symlink safety, and bounded image loading.

Follow-up sync fix: iOS now fetches before syncing, safely fast-forwards clean copies, and preserves dirty/diverged histories. Five integration tests cover clean download/no-op, local edits, diverged commits, ignored-file collisions, and oversized remote checkouts. Fetch uses the existing credential/redirect restrictions and resource limits.

Retained product choices: local copies remain after disconnect, Files access remains available, and sync still stages all files (now explicitly called out in its confirmation text). No app-encrypted vault or backup migration was added. Files/backup/locked-device guarantees still require physical-device verification; no deployed web origin exists to verify. No token was revoked or GitHub account configuration changed automatically.

---

## Verdict and scope

The web client has a reasonable baseline for local use, with no script execution found in the tested Markdown payloads. The iOS client has a reproduced repository containment defect and a high-impact credential handling defect identified in source. Address these before treating the app as suitable for sensitive repositories.

This is a source-assisted local penetration assessment, not a certification or a complete device/production penetration test. Reviewed commit: `d301277a6520078adbdf32edb56545c42ded45b9`. The user confirmed that the web app is not deployed. No production host, real GitHub account, private repository, or user document was attacked. Existing unrelated `output/` and `tmp/` content was excluded. Application code was not changed; this assessment adds a report, a disposable native reproduction harness, and browser regression tests.

Architecture: a React/Tiptap static web client uses GitHub REST directly and keeps notes in IndexedDB; iOS uses GitHub OAuth device flow, Keychain, SwiftGitX/libgit2, and real Git clones exposed through Files. `services/api` is a placeholder. There is no implemented application server/database authorization layer to test. GitHub enforces remote repository authorization; local copies have a separate device/browser access boundary.

## Findings

| ID | Priority | Finding | Evidence |
| --- | --- | --- | --- |
| GN-01 | High | iOS filesystem operations can escape a repository through symlinks | Reproduced using current file service and synthetic files on macOS |
| GN-02 | High, conditional | iOS Git credential callback does not restrict destination | Confirmed in source; no end-to-end token interception test |
| GN-03 | Medium | iOS authorization is broader than selected notes repositories | Confirmed `repo` OAuth scope |
| GN-04 | Medium, availability | iOS clones and note reads have no application size limits | Confirmed in source; no destructive resource exhaustion test |
| GN-05 | Before deployment | No checked-in production browser security-header policy | Configuration review; no production host exists |

Severity describes plausible impact and prerequisites, not a claim that an unauthenticated internet attacker can currently exploit every finding.

### GN-01: symlink repository escape

Locations: `apps/ios/GitNote/Infrastructure/WorkspaceStorage.swift:105`, `:114`, `:119`, `:145`, `:170`.

The file service uses `standardizedFileURL` and a string path-prefix check. These do not resolve symbolic links. Enumeration skips symlink entries, but subsequent reads/writes and new-path creation independently accept paths with symlink ancestors. The new-note UI accepts a manually entered relative path, so hiding symlink folders does not protect creation.

Reproduction: create a synthetic workspace and a separate sibling directory; place `linked` in the workspace pointing to the sibling. Calling the actual service with `MarkdownRelativePath("linked/injected.md")` creates a file in the sibling. A direct service read through `linked/secret.md` also returns the sibling fixture. This read demonstrates a service-boundary bypass; a UI read needs a stale file reference or directory replacement after enumeration. The creation path does not require that race. A repository collaborator can supply relative symlinks in a cloned repository and induce a user to create a note through one. Access is limited by the app's OS sandbox; this is not escape from iOS sandboxing and does not expose Keychain directly.

Observed output:

```text
SYMLINK_CREATE_ESCAPED= true
SYMLINK_READ_ESCAPED= true
```

Run from repository root:

```sh
python3 docs/security/reproduce_ios_symlink.py
```

The harness compiles the current Models and WorkspaceStorage Swift files, substituting only storage-root expressions to keep all fixture data in a temporary directory. It does not execute the iOS app or alter real working copies. It requires the Swift compiler.

Fix: validate resolved roots and targets, including existing parent components for new files; reject symlink components and access to `.git`/hidden internals. Because external editors can mutate shared directories, account for check/use races with directory-relative file operations and no-follow semantics where supported. Add regression coverage for sibling-workspace symlinks, broken symlinks, `.git` aliases, and directory replacement between enumeration and access. The image resolver in `MarkdownRichDocument.swift` already resolves symlinks, but that does not protect the separate file service.

### GN-02: GitHub token is not bound to the Git destination

Locations: `apps/ios/GitNote/Infrastructure/GitEngine.swift:219`, `:250`, `:286` (also clone at `:58`).

The credential callback ignores its URL parameter and supplies the stored GitHub token to any remote requesting username/password authentication. Push loads `origin` from the mutable local Git configuration; neither the remote URL nor a separate push URL is validated against the expected GitHub repository before transport. Initial redirects are explicitly enabled.

Attack prerequisite: a changed local remote/push URL, for example through Files/external Git tooling or a tampered working copy, followed by user sync. A server controlled by that actor can request authentication and receive a token with broader authority than access to the local clone. A normal GitHub clone does not import an attacker's `.git/config`, so a malicious Markdown file alone is not sufficient. This assessment did not transmit even synthetic credentials to a server or prove interception against the shipping iOS binary.

Fix: require HTTPS, exact host `github.com`, expected port, no URL credentials, and the expected owner/repository for clone, fetch, push URL, and credential use. Reject unexpected remotes before any connection. Disable cross-origin redirects, preferably disable authenticated redirects and resolve legitimate repository moves explicitly. Verify transport behavior on the exact bundled libgit2 revision; callback validation alone may be insufficient for redirects.

The [libgit2 callback reference](https://libgit2.org/docs/reference/main/credential/git_credential_acquire_cb.html) documents the destination URL argument. An upstream [redirect disclosure advisory](https://github.com/libgit2/libgit2/security/advisories/GHSA-2889-x8f6-mc4x) describes callback/redirect confusion in a tested 1.9.0 revision. GitNote pins the `ibrahimcetin/libgit2` package at 1.9.2, revision `52287b0914f300f916b58fec80e13d8dd8f6824f`. Applicability of that advisory to this fork/revision was not established; it is a follow-up, not a confirmed vulnerable-version finding.

### GN-03: broad iOS OAuth scope and credential lifecycle

Location: `apps/ios/GitNote/Infrastructure/GitHubClient.swift:73`; `docs/GITHUB_OAUTH.md`; `AppModel.swift:126`.

The iOS device flow requests `repo`. This grants substantial access beyond the repositories the user chooses in GitNote, subject to the user's actual rights and organization policies. A token leak therefore affects more than the local notebook. The web instructions already recommend fine-grained tokens restricted to selected repositories.

Fix: prefer a GitHub App installation model with selected repositories and minimal Contents permissions, or support fine-grained PATs as a nearer-term alternative. Clearly disclose the current scope. Disconnect deletes the local token but does not revoke it at GitHub; offer revocation guidance/action and avoid implying local deletion invalidates a stolen token. No embedded OAuth client secret was found. The OAuth client ID is public configuration, not a secret. See [GitHub OAuth scope documentation](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps).

### GN-04: unbounded iOS repository and document processing

Locations: `GitEngine.swift:44`; `WorkspaceStorage.swift:105`; image decode in `Features/MarkdownRichDocument.swift:559`.

iOS clones a full Git repository and history without app-enforced transfer/storage quotas or a cancellation/progress callback. Notes are read into a String without a file-size check; local images are decoded without an explicit pixel budget. A user who opens a large or intentionally hostile repository can exhaust storage/memory or make the app unresponsive. This is an availability risk requiring user interaction; it was not stress-tested on a device.

Fix: introduce clone progress and cancellation, disk-space/transfer limits, document-size limits, and bounded image decoding. Enforce limits before allocating full buffers. The web downloader already limits visible Markdown to 1,000 notes and 20 MB based on GitHub tree metadata; those limits do not exist for iOS.

### GN-05: browser hardening needs a deployment configuration

Locations: `apps/web/index.html`, `apps/web/vite.config.ts`, `apps/web/README.md`.

No checked-in CSP or hosting configuration establishes CSP, frame restrictions, HSTS, MIME-sniffing protection, or a referrer policy. Since the app has no deployment, this is a readiness gap, not evidence of a vulnerable production server. Vite's local preview is not a production security boundary.

Before deployment, configure and verify response headers: a CSP limiting scripts to application assets, `connect-src` to the app origin and `https://api.github.com`, `object-src 'none'`, `base-uri 'none'`, `frame-ancestors 'none'`, and restricted form/image sources; `X-Content-Type-Options: nosniff`; a restrictive Referrer-Policy; appropriate Permissions-Policy; HTTPS and HSTS once the domain's HTTPS setup is stable. Test the final policy with Tiptap, generated PWA registration, inline style needs, exports, and offline loading. Frame restrictions require an HTTP response header, not a CSP meta tag. A shared hosting origin would also share the browser storage trust boundary, so give GitNote a dedicated origin.

## Privacy and operational risks

- Private notes intentionally survive disconnect on both clients. On web, anyone with access to the same unlocked browser profile can read the IndexedDB copies without a GitHub login. This is documented behavior, not remote authorization bypass. Offer “disconnect and remove local copies” with explicit handling of unsynced notes, and consider a local lock/encrypted vault if shared-device privacy is required.
- iOS stores full clones under Documents and explicitly enables Files sharing. Notes/history are not application-encrypted. OS device protection still applies; actual protection classes and backup behavior were not measured. Decide whether Files access, backup inclusion, and exposure while locked match the intended privacy model. Keychain uses `AfterFirstUnlockThisDeviceOnly`; consider `WhenUnlockedThisDeviceOnly` if background access is unnecessary.
- iOS sync stages all Git changes, including non-Markdown files, with `git_index_add_all`/`git_index_update_all`. This matches the documented “all changes” behavior but can publish files added by external editors. Make this scope unmistakable in review; selective staging and sensitive-file warnings would reduce accidental disclosure.
- The iOS CI workflow builds but does not run XCTest. Both workflows use action tags and omit explicit least-privilege workflow permissions. Add security regression tests to CI, explicit `contents: read` where sufficient, dependency review/update automation, and immutable action pins. GitHub organization/repository settings, branch protection, OAuth registration, artifact retention, and account MFA were not inspected.

## Checks and results

| Check | Result | Limit |
| --- | --- | --- |
| Existing web unit tests | 38 passed | Paths, state, storage, mocked API behavior |
| Production web build and Playwright suite | 15 passed | Chromium; 8 existing and 7 new tests |
| Malicious Markdown probes | 7 passed | HTML event handlers, SVG, JavaScript/data links, encoded scheme, remote image, iframe/srcdoc; no exhaustive sanitizer proof |
| Credential persistence regression | Existing browser test passed | Tested browser storage and mocked API; not heap/crash-dump forensics |
| npm advisory audit | 0 reported vulnerabilities across 485 dependencies | Snapshot on assessment date; not proof dependencies are flaw-free |
| iOS symlink probe | Read and creation escaped the workspace | Actual Foundation service on macOS with synthetic roots; no iOS UI/device execution |
| Tracked-file secret pattern scan | No matches | GitHub-token, AWS-access-key, and private-key markers only; excludes Git history and untracked user artifacts |
| Authentication, remote writes, storage, CI review | Completed source review | Real OAuth/device permissions and hosting settings not exercised |

The new browser tests are `apps/web/tests/e2e/security.spec.ts`. They seed synthetic IndexedDB notes, inspect the editor for executable elements/unsafe links, and intercept a reserved `.invalid` tracking domain. Existing GitHub tests mock API responses; no test syncs to a real repository.

Positive controls: tokens remain in memory on web and Keychain on iOS; no embedded secret was found; API URLs use HTTPS; no TLS verification bypass was found; Markdown HTML/images use source mode on web; web downloads exclude symlinks and hidden paths; web sync uses optimistic head validation and a non-force ref update; PWA configuration precaches app assets rather than GitHub API responses; iOS image path resolution already uses canonical containment checks.

## Remediation order and remaining verification

1. Fix GN-01 and GN-02, then demonstrate rejected malicious paths/remotes with dedicated native regression tests and a dummy-token loopback interception test.
2. Reduce iOS token authority; define local privacy/backup/logout guarantees and bound native resource consumption.
3. Add production hosting headers and security checks to CI before deploying the web client.
4. Run signed iOS tests on simulator and a physical device: Keychain lifecycle, locked-device access, Files mutations, backups, app-switcher previews, OAuth cancellation/revocation, and exact libgit2 transport behavior. Xcode exists on this machine, but its active CLI selection points to CommandLineTools; this assessment used the standalone Swift compiler and did not run the native app suite.
5. Once deployed, test the actual web origin, HTTPS/headers/service worker, browser variants, and end-to-end GitHub permissions using disposable repositories and least-privilege test accounts. No deployed URL is currently available.

The current assessment is sufficient to identify concrete release-blocking iOS fixes. It does not justify describing either client as fully penetration-tested or guaranteed secure.

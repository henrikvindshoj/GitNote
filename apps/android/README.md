# GitNote for Android

Native Android client built with Kotlin and Jetpack Compose. It mirrors the core iOS workflow: connect a GitHub account, clone multiple public or private repositories as real local Git working copies, browse folders, edit Markdown in a rich editor, inspect changes, and synchronize safely.

## Requirements

- Android Studio 2026.1 or newer
- Android SDK 37 and Build Tools 36.0.0
- JDK 17 or newer (Android Studio's bundled JDK works)
- Android 8.0 / API 26 or newer

## Build and test

```sh
cd apps/android
./gradlew test
./gradlew connectedDebugAndroidTest
./gradlew assembleDebug
```

Open `apps/android` as the project in Android Studio. The debug APK is generated at `app/build/outputs/apk/debug/app-debug.apk`.

## Current capabilities

- Multiple real JGit working copies in app-private storage.
- Public clone, selected-repository token authentication, and GitHub OAuth device login.
- Credentials encrypted with an AES-GCM key held by Android Keystore.
- Nested folder browsing, Markdown search, note/folder creation, and offline access.
- Word-like Markdown editing with headings, bold, italic, lists, links, and code.
- Dirty badges, changed-file review, fetch/fast-forward, stage-all, commit, and push.
- Safe refusal when remote and local history diverge or a dirty copy is behind GitHub.

The OAuth route uses the same public GitNote client ID as iOS and requests `public_repo`. A client secret is never embedded. Fine-grained tokens remain the recommended option for selected or private repositories.

## Android storage boundary

Working copies stay in credential-encrypted, app-private storage. Android's Storage Access Framework exposes document-tree content URIs rather than ordinary filesystem paths, while JGit requires a filesystem-backed working tree. The app therefore exports a copy through the system document picker instead of claiming that another editor can safely share the live `.git` working copy. A future DocumentProvider or separately coordinated external-workspace mode is required for true Obsidian round trips.

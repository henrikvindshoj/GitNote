# GitNote for Android

This boundary is reserved for the future native Android client.

Recommended starting stack:

- Kotlin and Jetpack Compose.
- A replaceable Git engine adapter, evaluated separately from the iOS choice.
- Android Keystore for credentials.
- Storage Access Framework integration for external Markdown editors.
- Models generated from `packages/contracts/openapi.yaml` when a backend becomes necessary.

Do not import iOS implementation details or assume the backend stores repository contents.

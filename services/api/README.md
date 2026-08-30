# Optional GitNote API

No backend is required for the local-first iOS MVP.

This boundary can later host narrowly scoped services such as a GitHub OAuth code exchange, webhook-to-push notification relay, or shared account settings. It should not proxy or persist repository contents unless a future product requirement explicitly requires that tradeoff.

Any implementation must publish its contract in `packages/contracts/openapi.yaml` and keep secrets outside the repository.

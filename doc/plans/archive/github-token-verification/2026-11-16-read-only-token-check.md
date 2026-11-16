# Read-Only GitHub Token Verification

For #1161, native settings recommend a classic personal access token with
`public_repo` and optional `gist`. Broader private-repository access is not needed
for public Decaid feedback. Fine-grained tokens can authenticate, but GitHub
restricts public-organization issue writes for outside contributors.

The explicitly triggered identity check tests a nonblank unsaved candidate first,
otherwise a stable saved user-token snapshot. A draft never enters persistence or
the active credential provider. Input, credential and lifecycle changes invalidate
pending results rather than applying an obsolete result to a new credential.

Verification uses only read-only GET to the fixed HTTPS GitHub `/user` endpoint.
Redirects are disabled, requests are time-bounded, and owned clients are closed.
Results expose only a validated login or short safe failure guidance, never raw
transport errors or response bodies. Success establishes authentication, not the
ability to create Decaid issues or upload Gists.

Credential storage, normal metadata and feedback requests, shared cooldowns and
all plugin/skin APIs remain unchanged. No write-permission probe or background
verification is introduced.

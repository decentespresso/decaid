# Custom Visualizer server

Issue #975 keeps hosted Visualizer as the default and derives uploads, imports and metadata sync from one normalized HTTP(S) base URL. Reverse-proxy path prefixes are retained. Credentials, query strings, fragments and dot path segments in a base URL are rejected.

Credentials are held in the host's existing secure store and bound to the selected URL. Changing servers clears them; the owner enters credentials for the new server. Existing unscoped IDs belong only to the hosted service. Mapping and sync state are saved per server, and new shot annotations record the server beside the remote ID. Storage reads settle before scoped state is used; an early unload does not overwrite it.

Authenticated requests reject redirects before contacting their target. This small fetch option is needed for the credential boundary; per-request cancellation remains separate work in #981. Platform TLS validation remains enabled. Plain HTTP is available for explicitly configured local servers and has no transport encryption.

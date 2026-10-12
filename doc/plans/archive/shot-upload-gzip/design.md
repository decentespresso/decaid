# Shot-Upload Auto-Gzip

Shot JSON is transfer-bound, and the shot-upload server now accepts gzip request
bodies. Support for other Decent endpoints has not been established. Server
confirmation and the alternatives are recorded in
[shot-upload issue 3](https://github.com/decentespresso/shot-upload/issues/3).

Compress in DecentProxyService after the existing authorization and consent
checks. Only JSON POSTs to the normalized support/api/shot_upload path qualify.
Bodies below 1,024 UTF-8 bytes remain plain, as do bodies for which gzip does not
reduce size. Preserve content type, credentials, query parameters, and responses.

Endpoint-specific automatic compression requires no plugin release, binary
bridge, dependency, or new configuration. The tradeoff is that Decaid owns this
endpoint-specific policy. General automatic compression is unsafe until other
endpoints are proven; plugin opt-in and plugin-generated gzip require broader
interfaces than this feature needs.

A rejected compressed POST must not trigger a new plain-body fallback: that
would add an upload attempt with potentially duplicate effects. Existing plugin
retry behavior and the proxy response contract remain unchanged.

A live upload requires an explicitly approved test account. Local HTTP
verification uses fake credentials and loopback only; it proves the wire format,
not acceptance by the production server.

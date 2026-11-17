# Plugin-Owned Shot Upload Compression

Shot JSON is transfer-bound, and the shot-upload server now accepts gzip request
bodies. Support for other Decent endpoints has not been established. Server
confirmation and the alternatives are recorded in
[shot-upload issue 3](https://github.com/decentespresso/shot-upload/issues/3).

The initial implementation inferred compression from the shot-upload endpoint.
Review of PR 982 identified that this also changed API and skin callers and put
plugin/backend policy into the generic proxy. The revised boundary uses a
boolean gzip option in host.decentProxy, with compression disabled by default.

Shot-upload decides to request compression in its own repository. Decaid uses
its standard-library codec after the existing authorization and consent checks.
Bodies below 1,024 UTF-8 bytes remain plain, as do bodies for which gzip does not
reduce size. The mechanism does not depend on an endpoint or content type.
Native account access, write permissions, authentication, framing, and query
handling are unchanged. Binary forwarding and a JavaScript compressor are not
needed for this feature.

Upload consent belongs to the shot-upload interface, not to the gzip option.
Its first-use invitation describes account history and Decent's shot analysis,
remembers the answer in plugin storage, and enables the existing AutoUpload
setting only after an affirmative action. The native account consent gate remains
independent and cannot be bypassed by that browser invitation.

The invitation appears only on the plugin page when automatic uploads are off
and no response has been recorded. Both choices persist one internal marker in
host storage; already-enabled installations keep their existing behavior.
The browser acknowledges first and then saves AutoUpload through the existing
settings route, because that route reloads the plugin. Reloading from inside
the acknowledgement handler would retire its own pending response.

Storage waits have a five-second deadline. Write confirmations are correlated
so a late acknowledgement cannot complete a newer retry. Failure leaves the
page off with a retryable error, and enabling requires a linked account.
The plugin packages separate HTML and upload-logic sources into its required
single script with a dependency-free Node step. No bundled plugin asset or
release pin changes are made in Decaid until a plugin release.

A rejected compressed POST must not trigger a new plain-body fallback: that
would add an upload attempt with potentially duplicate effects. Existing plugin
retry behavior and the proxy response contract remain unchanged.

A live upload requires an explicitly approved test account. Local HTTP
verification uses fake credentials and loopback only; it proves the wire format,
not acceptance by the production server.

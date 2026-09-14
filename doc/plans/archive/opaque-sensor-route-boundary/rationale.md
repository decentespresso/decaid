# Opaque external sensor route boundary

Issue #858 fixes external plugin sensor IDs containing reserved characters.
Clients encode one sensor ID as one URI path component, and the sensor route
boundary decodes it exactly once before REST lookup or WebSocket rebind.

Supported plugin registrations generate colon-composed IDs from a plugin ID,
driver ID, and instance ID. The plugin manifest and registration service limit
those components to safe alphanumeric, dot, underscore, and hyphen tokens, so
percent-bearing synthetic IDs cannot be produced through the public
registration contract. Canonical encoding therefore fixes lookups for the
supported external IDs without a migration or fallback for synthetic raw-token
spellings.

Raw-percent tests pin the new router-boundary semantics. They do not claim
that every synthetic percent-bearing identity had identical historical lookup
behavior; in particular, a synthetic `%2F` token changes from raw-token lookup
to decode-once lookup.

This deliberately excludes host-assigned UUID resource IDs and preserves
their existing route contracts. Query values, filenames, commands, plugin and
key-value stored identities, skin paths, and proxy normalization are also
unchanged. The related per-device scale work can adopt the helper when its
external IDs are defined.

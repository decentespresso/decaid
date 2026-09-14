/// Decodes an opaque external identifier carried as one URI path component.
///
/// Clients encode such an id exactly once; the API boundary decodes it exactly
/// once before lookup. Host-assigned UUID resource ids keep their existing
/// route contracts and do not go through here.
///
/// Duplicated from the convention being established in #858 so this branch
/// stands on its own; drop it on rebase once that lands.
String decodeOpaquePathComponent(String raw) => Uri.decodeComponent(raw);

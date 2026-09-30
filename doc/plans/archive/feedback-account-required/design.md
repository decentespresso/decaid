# Feedback Account Requirement

Feedback submission must verify the stored Decent credentials before collecting
attachments or sending anything to GitHub or Support. Missing, rejected, and
unverifiable credentials fail closed with a typed account-required result. The
HTTP handler maps that result to 400. Native and Settings plugin feedback controls
are only available when logged in; otherwise they explain where to sign in.

Stored-credential verification has a fixed 30-second deadline covering credential
reads and the complete upstream response. A timeout returns indeterminate,
aborts the request, and ignores late results so they cannot change authentication
or trigger a machine refresh. This bounds native submission and HTTP feedback
without granting access from cached authentication after a verification timeout.
Account failures return 400 even when the GitHub token is absent; only a verified
account can reach the configuration failure and receive 503.

Support linking remains best-effort after issue creation. The new response
contract is a JSON object containing only `messageId`, a positive JSON integer
or an ASCII decimal string of 1-256 digits without leading zeros. The value `1`
is reserved for the temporary acknowledgement and is never published as an ID.
Reject email addresses, opaque strings, signs, whitespace, fractions, and
combined identifiers before any GitHub update. Invalid IDs skip linking without
failing the created issue. The backend identifies the user through the
authenticated request, so
Decaid does not request, model, or retain a user ID. Unexpected response fields
are ignored. Decaid passes only the message ID to the GitHub updater.
It appends `**Support message:**`
with that ID after fetching the latest GitHub body. Parsing errors never include
the raw response or user ID. Existing 401 cache invalidation remains intact.

No response-mode query parameter is used. Plain `1` temporarily acknowledges
delivery without a message ID and skips the GitHub update. Invalid responses
also skip linking without turning successful issue creation into a failure.
The shared send operation separates delivery success from its optional receipt:
non-200 responses and empty/zero acknowledgements fail delivery, while a
successful legacy opaque response or an invalid receipt returns no message ID.
This preserves serial-mismatch email delivery and deduplication across reconnects
without weakening the numeric validation used for public GitHub linking.
The backend maintainer must confirm the numeric format and that `messageId`
alone is globally unique enough for Support lookup and safe to expose publicly.
Numeric validation prevents arbitrary text disclosure but cannot establish the
meaning or public safety of the ID. The draft PR documents
this contract for agreement before merge.

This intentionally replaces the previous HTTP feedback
boundary: the Settings plugin now uses the host's authenticated Decent account.
Trusted-LAN callers intentionally do not need separate caller authentication.

The regression tests cover account rejection before GitHub/Gist traffic, HTTP
statuses, native and plugin visibility, native submission, receipts, and
preservation of the issue body. They also cover stalled credential reads,
headers, and response bodies, ignore late success after timeout, and exercise
account failures both with and without GitHub configuration.

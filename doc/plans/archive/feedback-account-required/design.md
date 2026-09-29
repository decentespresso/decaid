# Feedback Account Requirement

Feedback submission must verify the stored Decent credentials before collecting
attachments or sending anything to GitHub or Support. Missing, rejected, and
unverifiable credentials fail closed with a typed account-required result. The
HTTP handler maps that result to 400. Native and Settings plugin feedback controls
are only available when logged in; otherwise they explain where to sign in.

Support linking remains best-effort after issue creation. The new response
contract is a JSON object with separate `userId` and `messageId` fields, each
an integer or a non-empty string. Decaid keeps the user ID internal and passes
only the message ID to the GitHub updater. It appends `**Support message:**`
with that ID after fetching the latest GitHub body. Parsing errors never include
the raw response or user ID. Existing 401 cache invalidation remains intact.

No response-mode query parameter is used. Plain `1` temporarily acknowledges
delivery without a message ID and skips the GitHub update. Invalid responses
also skip linking without turning successful issue creation into a failure.
The backend maintainer must confirm that `messageId` alone is globally unique
enough for Support lookup and safe to expose publicly. The draft PR documents
this contract for agreement before merge.

This intentionally replaces the previous HTTP feedback
boundary: the Settings plugin now uses the host's authenticated Decent account.

The regression tests cover account rejection before GitHub/Gist traffic, HTTP
statuses, native and plugin visibility, native submission, receipts, and
preservation of the issue body.

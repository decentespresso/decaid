# Feedback Account Requirement

Feedback submission must verify the stored Decent credentials before collecting
attachments or sending anything to GitHub or Support. Missing, rejected, and
unverifiable credentials fail closed with a typed account-required result. The
HTTP handler maps that result to 400. Native and Settings plugin feedback controls
are only available when logged in; otherwise they explain where to sign in.

Support linking remains best-effort after issue creation. A legacy `1` response
acknowledges delivery but is not a reference. A returned message reference is
appended only after fetching the latest GitHub body. Existing response validation
and 401 cache invalidation remain intact.

Decaid sends the proposed `return_message_id=1` query parameter; the draft PR
is the alignment artifact for the backend maintainer. Legacy `1` remains valid
during rollout. The proposed reference is `userId.msgId`.
This intentionally replaces the previous HTTP feedback
boundary: the Settings plugin now uses the host's authenticated Decent account.

The regression tests cover account rejection before GitHub/Gist traffic, HTTP
statuses, native and plugin visibility, native submission, receipts, and
preservation of the issue body.

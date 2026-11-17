# Issue 728 Feedback Contact Linking

## Goal

Link native in-app feedback to Decent Support without exposing account
credentials or allowing a support-side failure to make an already-created
GitHub issue look like a failed submission.

## Design

Native feedback creates the GitHub issue first. When stored Decent account
credentials are present, Decaid sends a support message whose body is exactly
the GitHub issue URL. After support returns the contact identifier, Decaid
reads the current GitHub issue body, appends the identifier, and patches that
body. This preserves edits made while the support request was in flight.

`DecentAccountService` owns the authenticated support request. Its existing
serial-mismatch email becomes a caller of the general support-message method.
The returned identifier must be non-empty, must not be `0`, and must be safe to
place inside a single-line Markdown code span.

The account lookup, support request, and GitHub update are best-effort and
time-bounded after issue creation. The HTTP requests are abortable, and a
timeout guard prevents a completed support request from starting a late GitHub
update. Their failure is logged but does not change the original successful
`FeedbackSubmissionResult`.

A support `401` invalidates cached account authentication. Later feedback
submissions skip the authenticated support request until the user logs in
again.

## Security Boundary

Only the native feedback dialog receives `DecentAccountService`. The
`POST /api/v1/feedback` construction remains unchanged so a LAN or API caller
cannot trigger authenticated Decent Support messages.

## Verification

Service tests cover the authenticated support request, response validation,
authentication rejection, the POST to support GET to issue GET to PATCH
sequence, preservation of the current issue body, the exact support body, no
late PATCH after timeout, and successful submission when support linking
fails.
